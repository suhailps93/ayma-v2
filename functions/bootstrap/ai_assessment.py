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

The assessment lives as ONE wiki page, ``wiki_pages/ayma-assessment`` with
``page_type: "assessment"``, always ``visibility: ai_only``:

* it shows up automatically on the existing "Ayma's Notes" screen
  (``story.get_ai_notes`` includes ``ai_only`` pages) with no client change,
  and never in the Story editor or the public profile;
* ``page_type: "assessment"`` is deliberately NOT in ``wiki_schema.json``, so
  ``wiki_ingest._valid_op`` rejects any model attempt to write it through the
  normal ingest path — this module is the page's only writer;
* account wipe / purge already delete ``wiki_pages`` wholesale, so the
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
from functools import lru_cache
from pathlib import Path

from firebase_admin import firestore

import gemini
import token_ledger
import wiki_query

logger = logging.getLogger("ayma.assessment")

PAGE_ID = "ayma-assessment"
PAGE_TYPE = "assessment"

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


@lru_cache(maxsize=1)
def _prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


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


def _page_ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("wiki_pages")
        .document(PAGE_ID)
    )


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


# --- reads (matching + tools) --------------------------------------------------


def read_notes(db, uid: str) -> list[dict]:
    try:
        snap = _page_ref(db, uid).get()
        fm = (snap.to_dict() or {}).get("frontmatter") or {}
        notes = fm.get("notes")
        return notes if isinstance(notes, list) else []
    except Exception:  # noqa: BLE001
        return []


def digest(db, uid: str) -> str:
    """The stored judgment digest for ``uid``, or ``""`` — best-effort, never
    raises (matching must score fine for users with no assessment yet)."""
    try:
        snap = _page_ref(db, uid).get()
        fm = (snap.to_dict() or {}).get("frontmatter") or {}
        return str(fm.get("digest") or "").strip()
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
    ref = _page_ref(db, uid)
    data = ref.get().to_dict() or {}
    since_ms = int(data.get("dm_watermark_ms") or 0)

    wiki_text = wiki_query.read_wiki_context(
        db, uid, exclude_page_types=frozenset({PAGE_TYPE})
    )
    sig = _dm_signals(db, uid, since_ms)
    flagged_block = _flagged_block(sig["flagged"])
    sample_block = _sample_block(sig["sample"])

    if not force:
        gate = _hash(wiki_text, flagged_block, sample_block)
        if gate == str(data.get("input_hash") or ""):
            return False  # nothing new anywhere
        flag_fp = hashlib.sha256(flagged_block.encode("utf-8")).hexdigest()
        new_flags = flag_fp != str(data.get("flagged_hash") or "")
        if not new_flags:
            age_s = (_now_ms() - int(data.get("generated_at_ms") or 0)) / 1000
            if age_s < _MIN_REFRESH_INTERVAL_S:
                return False  # debounced; the next post-turn pass catches it
    if not wiki_text.strip() and not flagged_block and not sample_block:
        return False  # nothing to judge yet

    prior_notes = _clean_notes({"notes": data.get("frontmatter", {}).get("notes")})
    result = await gemini.generate_json(
        _contents(wiki_text, prior_notes, flagged_block, sample_block),
        system_prompt=_prompt(),
        response_schema=_RESPONSE_SCHEMA,
        uid=uid,
        feature=token_ledger.FEATURE_AI_NOTES,
        enforce_cap=False,
        temperature=0.0,
    )
    notes = _clean_notes(result)
    body = compile_body(notes)
    payload: dict = {
        "page_type": PAGE_TYPE,
        # Always ai_only: judgments are Ayma's own, never profile material.
        "visibility": "ai_only",
        "ai_body": body,
        "frontmatter": {"notes": notes, "digest": compile_digest(notes)},
        "updated_at": firestore.SERVER_TIMESTAMP,
        # What an immediate re-check would see: same wiki + flags, an empty
        # "new since watermark" sample — so the very next gate check skips.
        "input_hash": _hash(wiki_text, flagged_block, ""),
        "flagged_hash": hashlib.sha256(
            flagged_block.encode("utf-8")
        ).hexdigest(),
        "dm_watermark_ms": max(since_ms, int(sig["watermark_ms"] or 0)),
        "generated_at_ms": _now_ms(),
    }
    if not data:
        payload["created_at"] = firestore.SERVER_TIMESTAMP
    if body != str(data.get("ai_body") or "").strip():
        payload["ai_body_updated_at"] = firestore.SERVER_TIMESTAMP
    ref.set(payload, merge=True)
    return True


async def maybe_refresh(db, uid: str) -> None:
    """Fire-and-forget wrapper for background tasks — never raises."""
    try:
        await refresh(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("assessment refresh failed for %s", uid)
