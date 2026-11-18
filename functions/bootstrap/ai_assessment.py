"""Ayma's assessment — the judgment layer behind "AI notes" (founder feature,
2026-09-26).

Before this module, the "AI notes" screen was purely a *view mode* of the same
wiki pages the private Story shows (``story.get_ai_notes`` = every page incl.
``ai_only`` content) — identical to the private story except for what the user
deleted. The founder's intent is that AI notes be Ayma's own JUDGMENT of the
member: behavioural red/green flags with evidence, graded from everything Ayma
can actually see — her chats with the user (the wiki), the user's DM threads
with other members (including moderation-flagged messages), the profile /
questionnaire, and web-derived findings already in the wiki — so matching can
weigh who the person actually is, not just what they say.

Storage (two homes, one per read mode — ``CONFIG.person_graph_reads``):

* **Graph-authoritative** (``person_graph_reads`` ON, the live path): the
  judgment lives as Ayma-only emergent person-graph nodes (founder decision
  Nov 17, assessment follow-on part (a)) — one content node per polarity group
  (``emergent.assessment.{red,green,neutral}``, provenance ``inferred``, source
  stamped ``assessment``) that renders on the "Ayma's Notes" screen exactly like
  any other Ayma-only node, plus one non-rendering report node
  (``emergent.assessment.meta``) that carries the compiled digest, the raw notes
  (for carry-forward), and the incremental-refresh bookkeeping (input/flagged
  hashes, DM watermark, generated-at). There is NO separate ``assessment/main``
  document any more — every reader (the AI-notes screen via ``get_ai_notes`` →
  graph sections, and matching via :func:`digest`) reads the graph.
* **Legacy wiki** (``person_graph_reads`` OFF, reversible fallback): the old
  single wiki page ``wiki_pages/ayma-assessment`` with ``page_type:
  "assessment"``, always ``visibility: ai_only`` — unchanged, so a flag
  roll-back behaves exactly as before. ``page_type: "assessment"`` is
  deliberately NOT in ``wiki_schema.json`` (``wiki_ingest._valid_op`` rejects it
  through the normal ingest path — this module is the page's only writer).

Either home shows up automatically on the existing "Ayma's Notes" screen with no
client change, and never in the Story editor or the public profile. Account wipe
/ purge already delete ``wiki_pages`` and ``graph/main`` wholesale, so the
judgments are wiped with everything else.

Context inclusion (deliberate): the assessment is EXCLUDED from Ayma's
standing chat/voice context (``EXCLUDED_FROM_CHAT_CONTEXT`` at the two
unfiltered ``read_wiki_context`` call sites in ``main.py``) — the context-diet
program is actively shrinking the per-message prompt, and a candid "potentially
repulsive behaviour" judgment resident in every turn both costs tokens and
risks Ayma paraphrasing her private grading back at the user. The ``recall``
tool still reaches it (``wiki_query.recall_snippets`` reads all pages), and
the matching path gets it explicitly (``matching_skill`` consumes
:func:`digest` as a labeled block). ``completeness`` excludes it from the
narrative-coverage pass (it is Ayma's meta-judgment, not profile material, and
its churn must not invalidate that cache).

Cost bounds: regeneration is gated — a content fingerprint (wiki text +
DM signals) must change, only DM messages *newer than the last run's
watermark* are re-sent (moderation-flagged messages are always in scope so a
flag applied late to an old message is never missed), and non-flag changes are
further debounced by :data:`_MIN_REFRESH_INTERVAL_S`. A newly flagged message
bypasses the debounce — the founder's canonical case (a crude DM that
moderation flags) must land in the notes promptly. Every call is metered under
``token_ledger.FEATURE_AI_NOTES``; ``enforce_cap=False`` like the other
Ayma-initiated background passes (completeness, persona evolution) — still
recorded, never blocked on an empty balance.
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
from pathlib import Path

from prompt import load_prompt_file
from firebase_admin import firestore

import gemini
import token_ledger
import wiki_query

logger = logging.getLogger("ayma.assessment")

PAGE_ID = "ayma-assessment"
PAGE_TYPE = "assessment"

# Graph-authoritative home (person_graph_reads ON): one content node per
# polarity group + one non-rendering meta/bookkeeping report node. The
# ``emergent.assessment.`` id prefix is registered in person_graph_render
# (→ page_type "assessment", so the context-diet filters still exclude it from
# chat grounding) and reserved in person_graph_store (a live-writer prefix the
# Your Story editor never touches). Source is stamped ``assessment`` per the
# founder's every-node-carries-a-source rule.
_GRAPH_SOURCE_KIND = "assessment"
_GRAPH_NODE_PREFIX = "emergent.assessment."
_META_NODE_ID = _GRAPH_NODE_PREFIX + "meta"


def _content_node_id(polarity: str) -> str:
    return _GRAPH_NODE_PREFIX + polarity

# Page types kept OUT of Ayma's standing chat/voice context (main.py's
# unfiltered read_wiki_context call sites) — see the module docstring.
EXCLUDED_FROM_CHAT_CONTEXT = frozenset({PAGE_TYPE})

_PROMPT_PATH = Path(__file__).with_name("prompts") / "ai_assessment.md"

POLARITY_RED = "red"
POLARITY_GREEN = "green"
POLARITY_NEUTRAL = "neutral"
_POLARITIES = (POLARITY_RED, POLARITY_GREEN, POLARITY_NEUTRAL)
_SEVERITIES = ("low", "medium", "high")
_SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2}

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "notes": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "observation": {"type": "string"},
                    "evidence": {"type": "string"},
                    "polarity": {"type": "string", "enum": list(_POLARITIES)},
                    "severity": {"type": "string", "enum": list(_SEVERITIES)},
                },
                "required": ["observation", "evidence", "polarity", "severity"],
            },
        }
    },
    "required": ["notes"],
}

# --- input bounds (token cost) ----------------------------------------------
_MAX_THREADS = 20  # most-recently-active DM threads considered
_MAX_SAMPLE_PER_THREAD = 8  # newest outbound texts per thread since watermark
_MAX_MSG_CHARS = 280  # each message truncated
_MAX_FLAGGED = 12  # moderation-flagged outbound messages, newest first
_MAX_SAMPLE_CHARS = 6000  # whole unflagged-sample block
_MAX_NOTES = 24  # notes kept per user
_DIGEST_MAX_CHARS = 1200  # compact digest handed to matching

# Non-flag refreshes at most this often; a new moderation flag bypasses it.
_MIN_REFRESH_INTERVAL_S = 3600


def _now_ms() -> int:
    return int(time.time() * 1000)


def _ts_ms(v) -> int:
    if v is None:
        return 0
    if isinstance(v, (int, float)):
        return int(v)
    if hasattr(v, "timestamp"):
        try:
            return int(v.timestamp() * 1000)
        except Exception:  # noqa: BLE001
            return 0
    return 0


def _date_of(ts_ms: int) -> str:
    if ts_ms <= 0:
        return "date unknown"
    from datetime import datetime, timezone

    return datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).date().isoformat()


def _wiki_page_ref(db, uid: str):
    """The legacy wiki page ref (``person_graph_reads`` OFF only)."""
    return (
        db.collection("users")
        .document(uid)
        .collection("wiki_pages")
        .document(PAGE_ID)
    )


def _graph_reads_on() -> bool:
    from config import CONFIG

    return bool(CONFIG.person_graph_reads)


def _read_state(db, uid: str) -> dict:
    """The stored assessment state both reads and the refresh gate need, from
    whichever home is authoritative: ``exists`` (was anything stored before),
    the incremental-refresh bookkeeping (``input_hash`` / ``flagged_hash`` /
    ``dm_watermark_ms`` / ``generated_at_ms``), the raw ``notes`` (carried
    forward), the compiled ``digest``, and the prior ``ai_body`` (only the wiki
    path needs it, to decide ``ai_body_updated_at``)."""
    if _graph_reads_on():
        import person_graph_store as store

        payload = store.report_node_payload(db, uid, _META_NODE_ID)
        notes = payload.get("notes")
        return {
            "exists": bool(payload),
            "input_hash": str(payload.get("input_hash") or ""),
            "flagged_hash": str(payload.get("flagged_hash") or ""),
            "dm_watermark_ms": int(payload.get("dm_watermark_ms") or 0),
            "generated_at_ms": int(payload.get("generated_at_ms") or 0),
            "notes": notes if isinstance(notes, list) else [],
            "digest": str(payload.get("digest") or "").strip(),
            "ai_body": "",
        }
    data = _wiki_page_ref(db, uid).get().to_dict() or {}
    fm = data.get("frontmatter") or {}
    notes = fm.get("notes")
    return {
        "exists": bool(data),
        "input_hash": str(data.get("input_hash") or ""),
        "flagged_hash": str(data.get("flagged_hash") or ""),
        "dm_watermark_ms": int(data.get("dm_watermark_ms") or 0),
        "generated_at_ms": int(data.get("generated_at_ms") or 0),
        "notes": notes if isinstance(notes, list) else [],
        "digest": str(fm.get("digest") or "").strip(),
        "ai_body": str(data.get("ai_body") or "").strip(),
    }


# --- DM signals --------------------------------------------------------------


def _first_name(db, uid: str, cache: dict[str, str]) -> str:
    if uid in cache:
        return cache[uid]
    name = ""
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
        )
        full = str((snap.to_dict() or {}).get("name") or "").strip()
        name = full.split()[0] if full else ""
    except Exception:  # noqa: BLE001
        name = ""
    cache[uid] = name or uid
    return cache[uid]


def _dm_signals(db, uid: str, since_ms: int) -> dict:
    """The user's outbound DM behaviour, bounded.

    Returns ``{"flagged": [...], "sample": [...], "watermark_ms": int}`` where
    ``flagged`` is every moderation-flagged message the user SENT (newest
    :data:`_MAX_FLAGGED`, regardless of ``since_ms`` — a flag can be applied
    late, and prior notes only cover flags that were visible last run) and
    ``sample`` is the user's newest unflagged outbound texts *newer than*
    ``since_ms``, capped per thread and overall. Best-effort: any read failure
    yields empty signals rather than breaking the refresh."""
    flagged: list[dict] = []
    sample: list[dict] = []
    watermark = since_ms
    names: dict[str, str] = {}
    try:
        threads = list(
            db.collection("dm_threads")
            .where("participants", "array_contains", uid)
            .stream()
        )
    except Exception:  # noqa: BLE001
        logger.exception("assessment: dm thread read failed for %s", uid)
        return {"flagged": [], "sample": [], "watermark_ms": watermark}

    threads.sort(
        key=lambda t: _ts_ms((t.to_dict() or {}).get("last_message_at")),
        reverse=True,
    )
    for t in threads[:_MAX_THREADS]:
        tdata = t.to_dict() or {}
        parts = tdata.get("participants") or []
        other = next((p for p in parts if p != uid), "")
        try:
            msgs = list(
                db.collection("dm_threads")
                .document(t.id)
                .collection("messages")
                .stream()
            )
        except Exception:  # noqa: BLE001
            continue
        outbound = []
        for m in msgs:
            d = m.to_dict() or {}
            if str(d.get("sender_uid") or "") != uid:
                continue
            body = str(d.get("body") or "").strip()
            if not body:
                continue
            outbound.append((_ts_ms(d.get("created_at")), m.id, d, body))
        outbound.sort(key=lambda x: x[0], reverse=True)
        per_thread = 0
        for ts, mid, d, body in outbound:
            watermark = max(watermark, ts)
            entry = {
                "to": _first_name(db, other, names) if other else "unknown",
                "thread_id": t.id,
                "message_id": mid,
                "date": _date_of(ts),
                "text": body[:_MAX_MSG_CHARS],
            }
            if d.get("moderated") is True:
                entry["reason"] = str(d.get("moderation_reason") or "")
                entry["categories"] = [
                    str(c) for c in (d.get("moderation_categories") or [])
                ]
                entry["_ts"] = ts
                flagged.append(entry)
            elif ts > since_ms and per_thread < _MAX_SAMPLE_PER_THREAD:
                entry["_ts"] = ts
                sample.append(entry)
                per_thread += 1

    flagged.sort(key=lambda e: e["_ts"], reverse=True)
    flagged = flagged[:_MAX_FLAGGED]
    sample.sort(key=lambda e: e["_ts"], reverse=True)
    for e in flagged + sample:
        e.pop("_ts", None)
    return {"flagged": flagged, "sample": sample, "watermark_ms": watermark}


def _flagged_block(flagged: list[dict]) -> str:
    if not flagged:
        return ""
    lines = [
        "Moderation-flagged messages this member SENT (strong evidence — "
        "each was flagged by the safety check):"
    ]
    for f in flagged:
        cats = ", ".join(f.get("categories") or []) or "unspecified"
        reason = f.get("reason") or "flagged"
        lines.append(
            f'- [FLAGGED: {reason}; categories: {cats}] to {f["to"]}, '
            f'{f["date"]}: "{f["text"]}"'
        )
    return "\n".join(lines)


def _sample_block(sample: list[dict]) -> str:
    if not sample:
        return ""
    lines = [
        "Messages this member sent to other members recently "
        "(new since the last assessment):"
    ]
    used = len(lines[0])
    for s in sample:
        line = f'- to {s["to"]}, {s["date"]}: "{s["text"]}"'
        if used + len(line) > _MAX_SAMPLE_CHARS:
            break
        lines.append(line)
        used += len(line)
    return "\n".join(lines)


# --- note shaping -------------------------------------------------------------


def _clean_notes(result) -> list[dict]:
    raw = (result or {}).get("notes") if isinstance(result, dict) else None
    out: list[dict] = []
    for n in raw or []:
        if not isinstance(n, dict):
            continue
        obs = str(n.get("observation") or "").strip()
        if not obs:
            continue
        polarity = str(n.get("polarity") or "").strip().lower()
        if polarity not in _POLARITIES:
            polarity = POLARITY_NEUTRAL
        severity = str(n.get("severity") or "").strip().lower()
        if severity not in _SEVERITIES:
            severity = "low"
        out.append(
            {
                "observation": obs,
                "evidence": str(n.get("evidence") or "").strip(),
                "polarity": polarity,
                "severity": severity,
            }
        )
    return out[:_MAX_NOTES]


_BODY_HEADER = (
    "Ayma's candid assessment of this member — behavioural judgments with "
    "evidence, formed from their conversations with Ayma, their messages to "
    "other members (including anything moderation flagged), their profile and "
    "questionnaire, and web findings. Feeds matching; never shown on any "
    "profile."
)
_GROUP_TITLES = {
    POLARITY_RED: "Red flags",
    POLARITY_GREEN: "Green flags",
    POLARITY_NEUTRAL: "Observations",
}


def _sorted_notes(notes: list[dict]) -> list[dict]:
    polarity_rank = {POLARITY_RED: 0, POLARITY_GREEN: 1, POLARITY_NEUTRAL: 2}
    return sorted(
        notes,
        key=lambda n: (
            polarity_rank[n["polarity"]],
            _SEVERITY_RANK[n["severity"]],
        ),
    )


def compile_body(notes: list[dict]) -> str:
    if not notes:
        return _BODY_HEADER + "\n\nNothing noteworthy yet."
    out = [_BODY_HEADER]
    for polarity in _POLARITIES:
        group = [n for n in _sorted_notes(notes) if n["polarity"] == polarity]
        if not group:
            continue
        out.append(f"\n**{_GROUP_TITLES[polarity]}**")
        for n in group:
            line = f"- ({n['severity']}) {n['observation']}"
            if n["evidence"]:
                line += f" — evidence: {n['evidence']}"
            out.append(line)
    return "\n".join(out)


def compile_digest(notes: list[dict]) -> str:
    """The compact judgment digest matching consumes — red first (by
    severity), then green, then neutral, capped to
    :data:`_DIGEST_MAX_CHARS`."""
    lines: list[str] = []
    used = 0
    for n in _sorted_notes(notes):
        line = f"{n['polarity'].upper()}({n['severity']}): {n['observation']}"
        if n["evidence"]:
            line += f" [{n['evidence']}]"
        if used + len(line) > _DIGEST_MAX_CHARS:
            break
        lines.append(line)
        used += len(line)
    return "\n".join(lines)


def _group_block(polarity: str, group: list[dict]) -> str:
    """One polarity group's heading + bullets — the content a single
    ``emergent.assessment.<polarity>`` node carries (graph path). Mirrors the
    per-group section :func:`compile_body` builds for the wiki ``ai_body``."""
    lines = [f"**{_GROUP_TITLES[polarity]}**"]
    for n in group:
        line = f"- ({n['severity']}) {n['observation']}"
        if n["evidence"]:
            line += f" — evidence: {n['evidence']}"
        lines.append(line)
    return "\n".join(lines)


# --- reads (matching + tools) --------------------------------------------------


def read_notes(db, uid: str) -> list[dict]:
    try:
        return _read_state(db, uid)["notes"]
    except Exception:  # noqa: BLE001
        return []


def digest(db, uid: str) -> str:
    """The stored judgment digest for ``uid``, or ``""`` — best-effort, never
    raises (matching must score fine for users with no assessment yet)."""
    try:
        return _read_state(db, uid)["digest"]
    except Exception:  # noqa: BLE001
        return ""


# --- generation -----------------------------------------------------------------


def _hash(wiki_text: str, flagged_block: str, sample_block: str) -> str:
    return hashlib.sha256(
        "||".join((wiki_text, flagged_block, sample_block)).encode("utf-8")
    ).hexdigest()


def _contents(
    wiki_text: str, prior_notes: list[dict], flagged_block: str, sample_block: str
) -> str:
    dm = "\n\n".join(b for b in (flagged_block, sample_block) if b)
    return (
        "PROFILE & CONVERSATION NOTES (the member's compiled wiki — what they "
        "told Ayma, questionnaire-derived facts, skill and web findings):\n"
        f"{wiki_text.strip() or '(nothing yet)'}\n\n"
        "PREVIOUS ASSESSMENT NOTES (carry forward what still holds, revise or "
        "drop what the new material contradicts):\n"
        f"{json.dumps(prior_notes, ensure_ascii=False) if prior_notes else '(none yet)'}\n\n"
        "DM ACTIVITY (messages this member actually SENT to other members):\n"
        f"{dm or '(no direct-message activity)'}"
    )


async def refresh(db, uid: str, *, force: bool = False) -> bool:
    """Regenerate the assessment page when there is new material.

    Returns True when a generation actually ran. Gating (see module
    docstring): content fingerprint + watermark + debounce, with a
    new-moderation-flag fast path. ``force`` skips all gating.
    """
    if not db or not uid:
        return False
    state = _read_state(db, uid)
    since_ms = state["dm_watermark_ms"]

    wiki_text = wiki_query.read_wiki_context(
        db, uid, exclude_page_types=frozenset({PAGE_TYPE})
    )
    sig = _dm_signals(db, uid, since_ms)
    flagged_block = _flagged_block(sig["flagged"])
    sample_block = _sample_block(sig["sample"])

    if not force:
        gate = _hash(wiki_text, flagged_block, sample_block)
        if gate == state["input_hash"]:
            return False  # nothing new anywhere
        flag_fp = hashlib.sha256(flagged_block.encode("utf-8")).hexdigest()
        new_flags = flag_fp != state["flagged_hash"]
        if not new_flags:
            age_s = (_now_ms() - state["generated_at_ms"]) / 1000
            if age_s < _MIN_REFRESH_INTERVAL_S:
                return False  # debounced; the next post-turn pass catches it
    if not wiki_text.strip() and not flagged_block and not sample_block:
        return False  # nothing to judge yet

    prior_notes = _clean_notes({"notes": state["notes"]})
    result = await gemini.generate_json(
        _contents(wiki_text, prior_notes, flagged_block, sample_block),
        system_prompt=load_prompt_file(_PROMPT_PATH),
        response_schema=_RESPONSE_SCHEMA,
        uid=uid,
        feature=token_ledger.FEATURE_AI_NOTES,
        enforce_cap=False,
        temperature=0.0,
    )
    notes = _clean_notes(result)
    book = {
        # What an immediate re-check would see: same wiki + flags, an empty
        # "new since watermark" sample — so the very next gate check skips.
        "input_hash": _hash(wiki_text, flagged_block, ""),
        "flagged_hash": hashlib.sha256(flagged_block.encode("utf-8")).hexdigest(),
        "dm_watermark_ms": max(since_ms, int(sig["watermark_ms"] or 0)),
        "generated_at_ms": _now_ms(),
    }
    _write_result(db, uid, notes, book, prior_state=state)
    return True


def _write_result(
    db, uid: str, notes: list[dict], book: dict, *, prior_state: dict
) -> None:
    """Persist a fresh assessment to the authoritative home. Graph: content
    nodes per polarity + the meta/bookkeeping report node. Wiki (flag off): the
    single ``ayma-assessment`` page, unchanged."""
    digest_str = compile_digest(notes)
    if _graph_reads_on():
        _write_graph(db, uid, notes, digest_str, book)
        return
    body = compile_body(notes)
    payload: dict = {
        "page_type": PAGE_TYPE,
        # Always ai_only: judgments are Ayma's own, never profile material.
        "visibility": "ai_only",
        "ai_body": body,
        "frontmatter": {"notes": notes, "digest": digest_str},
        "updated_at": firestore.SERVER_TIMESTAMP,
        **book,
    }
    if not prior_state["exists"]:
        payload["created_at"] = firestore.SERVER_TIMESTAMP
    if body != prior_state["ai_body"]:
        payload["ai_body_updated_at"] = firestore.SERVER_TIMESTAMP
    _wiki_page_ref(db, uid).set(payload, merge=True)


def _write_graph(
    db, uid: str, notes: list[dict], digest_str: str, book: dict
) -> None:
    """Write the assessment as Ayma-only person-graph nodes (founder Nov 17).

    One rendering content node per non-empty polarity group — these are what the
    "Ayma's Notes" screen shows — and one non-rendering ``report_doc`` meta node
    carrying the digest matching reads, the raw notes (carried forward on the
    next run), and the incremental-refresh bookkeeping. A polarity group that is
    now empty has its stale node deleted, so a dropped red flag never lingers."""
    import person_graph_store as store

    present: set[str] = set()
    for polarity in _POLARITIES:
        group = [n for n in _sorted_notes(notes) if n["polarity"] == polarity]
        if not group:
            continue
        present.add(polarity)
        # Gist-first (less-text-heavy program): a one-line headline for the
        # group — its title plus the top (highest-severity) observation. The
        # full grouped prose stays in the node body.
        top = str(group[0].get("observation") or "").strip()
        gist = f"{_GROUP_TITLES[polarity]}: {top}" if top else _GROUP_TITLES[polarity]
        gist = " ".join(gist.split())
        if len(gist) > 100:
            gist = gist[:99].rstrip() + "…"
        store.upsert_fact_node(
            db,
            uid,
            _content_node_id(polarity),
            _group_block(polarity, group),
            section="misc",
            visibility="ayma_only",
            provenance="inferred",
            level=2,
            label=f"Ayma's assessment — {_GROUP_TITLES[polarity]}",
            answer_type="narrative",
            gist=gist,
            source_kind=_GRAPH_SOURCE_KIND,
            source_ref=polarity,
        )
    stale = [_content_node_id(p) for p in _POLARITIES if p not in present]
    if stale:
        store.delete_nodes(db, uid, stale)
    store.upsert_report_node(
        db,
        uid,
        _META_NODE_ID,
        {"notes": notes, "digest": digest_str, **book},
        label="assessment-meta",
        section="misc",
    )


def backfill_to_graph(db, uid: str, *, delete_old: bool = True) -> bool:
    """One-time, idempotent migration of a user's legacy ``assessment/main``
    document into the person-graph nodes (founder Nov 17, part (a) cutover).

    Reads the old off-wiki doc, writes the same content as graph nodes
    (:func:`_write_graph`), and — unless ``delete_old=False`` — deletes the old
    doc so nothing unused stays. Returns True when an old doc was found and
    migrated, False when there was nothing to migrate (already done, or never
    had one). Safe to re-run: the node ids are stable, so a repeat overwrites in
    place; a second run finds no old doc and is a no-op. Runs ONLY where
    ``person_graph_reads`` is on (the nodes are the authoritative home there).

    This writes to Firestore; run it as an ops task per uid, never against prod
    data without the founder's go-ahead."""
    ref = (
        db.collection("users").document(uid)
        .collection("assessment").document("main")
    )
    data = ref.get().to_dict() or {}
    if not data:
        return False
    fm = data.get("frontmatter") or {}
    notes = _clean_notes({"notes": fm.get("notes")})
    book = {
        "input_hash": str(data.get("input_hash") or ""),
        "flagged_hash": str(data.get("flagged_hash") or ""),
        "dm_watermark_ms": int(data.get("dm_watermark_ms") or 0),
        "generated_at_ms": int(data.get("generated_at_ms") or 0),
    }
    _write_graph(db, uid, notes, compile_digest(notes), book)
    if delete_old:
        ref.delete()
    return True


async def maybe_refresh(db, uid: str) -> None:
    """Fire-and-forget wrapper for background tasks — never raises."""
    try:
        await refresh(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("assessment refresh failed for %s", uid)
