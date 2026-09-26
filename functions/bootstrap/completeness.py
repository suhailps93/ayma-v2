"""Per-user profile-completeness engine for the tree-based questionnaire.

Scores how much of the user's intent-routed question tree
(:mod:`question_tree`) is answered — from the ``users/{uid}/questionnaire``
store, from derivable ``profile/main`` fields, and, for the open-ended narrative
nodes, from a single cached LLM pass over the user's wiki text.

The result is persisted to ``users/{uid}/profile/main.completeness`` (a map) and
surfaced by ``GET /completeness`` and ``GET /questionnaire``. :func:`recompute`
is the debounced entry point wired into the wiki-ingest tail, the questionnaire
skill, and ``set_profile_field``.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
from datetime import datetime, timezone
from pathlib import Path

import gemini
import question_tree
import token_ledger
import wiki_query

logger = logging.getLogger("ayma.completeness")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "completeness_narrative.md"

# Debounce window for :func:`recompute` — a fresh result within this many
# seconds is returned as-is unless ``force=True``.
_DEBOUNCE_SECONDS = 60

# Node id → the ``profile/main`` field that already answers it (preboarding). A
# non-blank value there marks the node covered without a questionnaire entry.
_PROFILE_DERIVABLE = {
    "legal_first_name": "name",
    "date_of_birth": "birthdate",
    "gender_identity": "gender",
    "target_match_genders": "interested_in",
    "primary_location": "location",
}

# Mirrors matching.py's _INTEREST_TO_GENDER / orientation_match same-gender
# check — reuses the existing gender ("Woman"/"Man"/"Non-binary"/"Other") and
# interested_in ("Women"/"Men"/"Everyone") vocabulary already captured at
# preboarding, rather than inventing a new orientation field.
_SAME_GENDER_INTEREST = {"woman": "women", "man": "men"}


def _is_lgbtq(gender, interested_in) -> bool:
    """True when the user's own stated gender + interest profile marks them
    LGBTQ+: a gender-diverse identity (non-binary/other), or an interest that
    includes their own gender or "everyone". A straight/cisgender user (per
    their own answers) is never flagged."""
    g = str(gender or "").strip().lower()
    if not g:
        return False
    if g in ("non-binary", "other"):
        return True
    same = _SAME_GENDER_INTEREST.get(g)
    if not same:
        return False
    interests = {str(i or "").strip().lower() for i in (interested_in or [])}
    return same in interests or "everyone" in interests


# Founder directive, 2026-09-20: don't ask a gender-identity follow-up of
# straight/cisgender users. For them, the basic preboarding `gender` field
# fully answers the `gender_identity` node (as it always has). For an
# LGBTQ+ user (per `_is_lgbtq`), the basic field doesn't capture the richer
# identity this node actually asks about (Trans-Male, Trans-Female,
# Non-Binary, Custom, ...), so it stays open and can surface through
# `next_questions` instead of being silently marked "covered".
_CONDITIONAL_DERIVABLE = {"gender_identity"}


def _profile_derived_field(node_id: str, profile: dict) -> str | None:
    """The `_PROFILE_DERIVABLE` field for `node_id`, or ``None`` when this
    node isn't (or, for a gated node, currently isn't) answerable purely from
    a preboarding field."""
    field = _PROFILE_DERIVABLE.get(node_id)
    if (
        field
        and node_id in _CONDITIONAL_DERIVABLE
        and _is_lgbtq(profile.get("gender"), profile.get("interested_in"))
    ):
        return None
    return field

_NARRATIVE_COVERAGE = {"covered": 1.0, "partial": 0.5, "missing": 0.0}

# Questionnaire section labels come from :mod:`question_tree` (the config layer);
# the extra keys here cover other profile surfaces that reuse this map.
_PAGE_TYPE_LABELS = {
    **question_tree.PAGE_TYPE_LABELS,
    "sensitive": "Private context",
    "steering": "How to talk to me",
    "web_findings": "From the web",
    "face_analysis": "Face analysis",
    "body_analysis": "Body analysis",
    "misc": "Other",
}

# How many highest-weight open nodes to surface as "do these next".
_NEXT_LIMIT = 6

# Page types the narrative LLM pass never needs and must not key its cache
# on. `interactions`/`steering` are Ayma's own meta-notes about the *session*
# (engagement log, standing instructions) — not stated/inferred facts about
# the user, and no narrative topic (question_tree's page types: identity,
# career, family, relationships, personality, ...) is ever scored from them.
# But `wiki_ingest`'s prompt asks the model to fold in an `interactions`
# observation on nearly every turn ("note communication style ... engagement
# level"), so that page rewrites almost every session regardless of whether
# anything profile-relevant was said. Root-caused against a real account (uid
# iWhWjiWhEpU7iyu9B9vy7GlT0PD2, 2026-09-26): a session of pure small talk
# ("hi", a couple of garbled voice-to-text lines) triggered a wiki_ingest
# rewrite of only `interactions`+`steering` (every narrative page's
# `updated_at` predated the session) — yet the next `completeness.recompute`
# still paid for a full narrative Gemini call, because the wiki-hash cache
# key in `_narrative_status` was computed over the *whole* wiki text and that
# text had changed. Excluding these two page types from the text hashed and
# sent to the narrative pass keeps the cache valid (and the Gemini call
# skipped) whenever only Ayma's own session notes moved, while any real
# change to a narrative-relevant page still invalidates it exactly as before.
_NARRATIVE_EXCLUDED_PAGE_TYPES = frozenset({"interactions", "steering"})

# How long a node stays deprioritised in `_next` after `next_questions` last
# offered it. Root cause (ARCHITECTURE.md questionnaire bug, Sept 2026): when
# the user declines/deflects a question instead of answering it, nothing ever
# gets written for that node, so on the very next `next_questions` call it is
# still the single highest-weight open item and comes right back — verified
# against a real conversation (uid iWhWjiWhEpU7iyu9B9vy7GlT0PD2) where
# `past_relationship_narrative` (core, weight 4) got re-offered three times in
# a few minutes after the user twice said they didn't want to go there, until
# Ayma itself noticed it was "looping". This is not a caching or record/read
# race — `next_questions` already forces a fresh recompute — it's that
# priority-only ranking has no memory of "just tried this." A cooldown here
# lets other open items surface first, and lets this one come back once the
# cooldown lapses (or once nothing else is open) — "drop it and pick it back
# up later" (questionnaire.md) rather than immediately.
_OFFER_COOLDOWN_SECONDS = 900

# The ceiling a fully-answered current tree can reach. There is always more
# Ayma could learn about someone than today's fixed question set covers, so
# a perfect score would be a false promise — full current coverage tops out
# here, not at 100.
_MAX_SCORE = 95


def _prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _blank(v) -> bool:
    return v in (None, "", [], {})


def _stringify(v) -> str:
    if isinstance(v, (list, tuple)):
        return ", ".join(str(x) for x in v)
    return str(v)


def _status(coverage: float) -> str:
    if coverage >= 1.0:
        return "covered"
    if coverage > 0.0:
        return "partial"
    return "missing"


def _age_seconds(iso: str | None) -> float | None:
    if not iso:
        return None
    try:
        ts = datetime.fromisoformat(iso)
    except (TypeError, ValueError):
        return None
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - ts).total_seconds()


# --- Firestore helpers ---------------------------------------------------------


def _profile_ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("profile")
        .document("main")
    )


def _profile(db, uid: str) -> dict:
    try:
        snap = _profile_ref(db, uid).get()
        return (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
    except Exception:  # noqa: BLE001 - a read failure just yields no derivations
        logger.exception("completeness: profile read failed for %s", uid)
        return {}


def _questionnaire_store(db, uid: str) -> dict[str, dict]:
    try:
        out: dict[str, dict] = {}
        for snap in (
            db.collection("users")
            .document(uid)
            .collection("questionnaire")
            .stream()
        ):
            out[snap.id] = snap.to_dict() or {}
        return out
    except Exception:  # noqa: BLE001
        logger.exception("completeness: questionnaire read failed for %s", uid)
        return {}


def _read_completeness(db, uid: str) -> dict | None:
    prof = _profile(db, uid)
    val = prof.get("completeness")
    return val if isinstance(val, dict) else None


def _persist(db, uid: str, result: dict) -> None:
    try:
        _profile_ref(db, uid).set({"completeness": result}, merge=True)
    except Exception:  # noqa: BLE001
        logger.exception("completeness: persist failed for %s", uid)


# --- recently-offered tracking (anti-repeat for `next_questions`) -----------


def _offers_ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("completeness_cache")
        .document("offers")
    )


def _read_offers(db, uid: str) -> dict[str, str]:
    """``{node_id: iso_timestamp}`` for nodes `next_questions` has recently
    handed back. Best-effort: a read failure just means no cooldown applies."""
    try:
        snap = _offers_ref(db, uid).get()
        return (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
    except Exception:  # noqa: BLE001
        logger.exception("completeness: offers read failed for %s", uid)
        return {}


def mark_offered(db, uid: str, node_ids: list[str]) -> None:
    """Record that `next_questions` just handed back these node ids, so a
    still-unanswered one among them is deprioritised (not excluded) in
    `_next` for `_OFFER_COOLDOWN_SECONDS` — see that constant. Best-effort:
    never raises, never blocks the tool call on a Firestore round-trip that
    fails."""
    if not db or not uid or not node_ids:
        return
    try:
        now = _now_iso()
        _offers_ref(db, uid).set({nid: now for nid in node_ids}, merge=True)
    except Exception:  # noqa: BLE001
        logger.exception("completeness: marking offered failed for %s", uid)


# --- intent -----------------------------------------------------------------


def _resolve_intent(store: dict, profile: dict) -> tuple[str, bool]:
    """``(branch, explicitly_set)``. Branch is the routed
    :mod:`question_tree` branch; ``explicitly_set`` is False when the user has
    given no usable ``relationship_intent`` (unset or "Not sure yet")."""
    raw = (store.get("relationship_intent") or {}).get("value") or profile.get(
        "relationship_intent"
    )
    branch = question_tree.branch_for_intent(raw)
    explicitly_set = bool(
        raw and str(raw).strip().lower() not in ("", "not sure yet", "undecided")
    )
    return branch, explicitly_set


# --- narrative LLM pass (cached on the wiki hash) -----------------------------


def _cache_ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("completeness_cache")
        .document("narrative")
    )


async def _run_narrative_llm(uid: str, wiki_text: str, topics: list[dict]) -> dict:
    schema = {
        "type": "object",
        "properties": {
            "assessments": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"},
                        "status": {
                            "type": "string",
                            "enum": ["covered", "partial", "missing"],
                        },
                    },
                    "required": ["id", "status"],
                },
            }
        },
        "required": ["assessments"],
    }
    contents = (
        "USER WIKI:\n"
        + wiki_text
        + "\n\nNARRATIVE TOPICS:\n"
        + json.dumps({"narrative_topics": topics}, ensure_ascii=False)
    )
    raw = await gemini.generate_json(
        contents,
        _prompt(),
        schema,
        uid=uid,
        feature=token_ledger.FEATURE_COMPLETENESS,
        enforce_cap=False,
        temperature=0.0,
    )
    wanted = {t["id"] for t in topics}
    out: dict[str, str] = {}
    for a in (raw or {}).get("assessments", []):
        if a.get("id") in wanted and a.get("status") in _NARRATIVE_COVERAGE:
            out[a["id"]] = a["status"]
    for t in topics:
        out.setdefault(t["id"], "missing")
    return out


async def _narrative_status(db, uid: str, targets: list[dict]) -> dict[str, str]:
    """``{node_id: "covered"|"partial"|"missing"}`` for the narrative nodes in
    ``targets``. Cached on ``users/{uid}/completeness_cache/narrative`` keyed by
    a hash of the wiki text + the target id set, so an unchanged wiki never
    re-hits Gemini."""
    if not targets:
        return {}
    topics = [
        {"id": n["id"], "label": n["label"], "ayma_prompt": n["ayma_prompt"]}
        for n in targets
    ]
    missing_all = {t["id"]: "missing" for t in topics}
    try:
        wiki_text = (
            wiki_query.read_wiki_context(
                db, uid, exclude_page_types=_NARRATIVE_EXCLUDED_PAGE_TYPES
            )
            or ""
        )
    except Exception:  # noqa: BLE001
        logger.exception("completeness: wiki read failed for %s", uid)
        return missing_all
    key = hashlib.sha256(
        ("|".join(sorted(t["id"] for t in topics)) + "||" + wiki_text).encode(
            "utf-8"
        )
    ).hexdigest()

    ref = None
    try:
        ref = _cache_ref(db, uid)
        snap = ref.get()
        if getattr(snap, "exists", False):
            cached = snap.to_dict() or {}
            if cached.get("wiki_hash") == key and isinstance(
                cached.get("result"), dict
            ):
                return {t["id"]: cached["result"].get(t["id"], "missing") for t in topics}
    except Exception:  # noqa: BLE001
        logger.exception("completeness: narrative cache read failed for %s", uid)

    if not wiki_text.strip():
        result = dict(missing_all)
    else:
        try:
            result = await _run_narrative_llm(uid, wiki_text, topics)
        except Exception:  # noqa: BLE001 - best-effort; leave uncached so it retries
            logger.exception("completeness: narrative LLM pass failed for %s", uid)
            return dict(missing_all)

    if ref is not None:
        try:
            ref.set(
                {"wiki_hash": key, "result": result, "updated_at": _now_iso()},
                merge=True,
            )
        except Exception:  # noqa: BLE001
            logger.exception("completeness: narrative cache write failed for %s", uid)
    return result


# --- evaluation + scoring ---------------------------------------------------


async def _evaluate(db, uid: str) -> tuple[str, bool, list[dict]]:
    """``(branch, intent_set, evaluated)`` where each ``evaluated`` entry is
    ``{node, coverage, status, value, source}``."""
    profile = _profile(db, uid)
    store = _questionnaire_store(db, uid)
    branch, intent_set = _resolve_intent(store, profile)
    nodes = question_tree.nodes_for_intent(
        "nikah" if branch == "nikah" else branch
    )

    narrative_targets = [
        n
        for n in nodes
        if n["kind"] == "narrative"
        and n["id"] not in _PROFILE_DERIVABLE
        and n["id"] not in store
    ]
    narr = await _narrative_status(db, uid, narrative_targets)

    evaluated: list[dict] = []
    for n in nodes:
        nid = n["id"]
        deriv = _profile_derived_field(nid, profile)
        if deriv and not _blank(profile.get(deriv)):
            cov, src, val = 1.0, "profile", _stringify(profile.get(deriv))
        elif nid in store:
            entry = store[nid]
            raw_src = str(entry.get("source") or "stated").lower()
            cov = 0.7 if raw_src == "inferred" else 1.0
            src = raw_src if raw_src in ("stated", "inferred") else "stated"
            val = entry.get("value")
        elif n["kind"] == "narrative":
            st = narr.get(nid, "missing")
            cov = _NARRATIVE_COVERAGE.get(st, 0.0)
            src = "wiki" if cov > 0 else None
            val = None
        else:
            cov, src, val = 0.0, None, None
        evaluated.append(
            {
                "node": n,
                "coverage": cov,
                "status": _status(cov),
                "value": val,
                "source": src,
                # Whether this node is (still) answerable purely from a
                # preboarding profile field — see _profile_derived_field.
                # `_next` uses this instead of a static `_PROFILE_DERIVABLE`
                # membership check so a gated node (gender_identity) can stay
                # open for the users it should still be asked of.
                "profile_derivable": deriv is not None,
            }
        )
    return branch, intent_set, evaluated


def _score(evaluated: list[dict]) -> int:
    """0-``_MAX_SCORE``. Coverage is scaled into that range rather than 0-100
    so a fully-answered tree lands at ``_MAX_SCORE`` (currently 95), never a
    literal 100 — there's always more Ayma could learn than today's fixed
    question set asks. Scaling (not a post-hoc cap) keeps the score strictly
    monotonic in coverage: answering one more question never lowers it."""
    total_w = sum(e["node"]["weight"] for e in evaluated)
    if not total_w:
        return 0
    got = sum(e["node"]["weight"] * e["coverage"] for e in evaluated)
    return round(_MAX_SCORE * got / total_w)


def _fully_covered(evaluated: list[dict]) -> bool:
    """True once every node in ``evaluated`` is at full coverage — the
    "there's nothing left in today's question set" signal, independent of
    score rounding."""
    return bool(evaluated) and all(e["coverage"] >= 1.0 for e in evaluated)


# --- progressive disclosure: intent gate + section/node unlock ---------------

_ROUTING_ID = "relationship_intent"

# A core node counts as "answered" for unlock purposes at this coverage or
# above — i.e. covered (1.0) or a confident inference / partial (0.7).
_UNLOCK_COVERAGE = 0.7


def _visible(evaluated: list[dict], intent_set: bool) -> list[dict]:
    """The evaluated nodes the client sees. Until the user has picked a
    relationship intent, that is the global core (``branch == "all"``) only —
    the branch-specific sections stay hidden."""
    if intent_set:
        return list(evaluated)
    return [e for e in evaluated if e["node"]["branch"] == "all"]


def _section_gating(
    visible: list[dict], branch: str, intent_set: bool
) -> tuple[list[str], dict[str, dict]]:
    """``(ordered_page_types, meta)`` where ``meta[page_type]`` is
    ``{unlocked, core_total, core_answered, core_ok}``. Sections are walked in
    :func:`question_tree.sections_for_intent` order; a section is unlocked when
    it is the first, or every core node of every earlier section is answered.
    While the intent is unset the routing section is represented by its own
    always-on prompt and is dropped from the section list."""
    present = {e["node"]["page_type"] for e in visible}
    ordered = [
        s["page_type"]
        for s in question_tree.sections_for_intent(branch)
        if s["page_type"] in present
    ]
    # defensive: keep any straggler page_type sections_for_intent didn't rank
    for e in visible:
        pt = e["node"]["page_type"]
        if pt not in ordered:
            ordered.append(pt)
    if not intent_set:
        ordered = [pt for pt in ordered if pt != "relationships"]

    core_by_pt: dict[str, list[dict]] = {}
    for e in visible:
        if question_tree.tier(e["node"]["id"]) == "core":
            core_by_pt.setdefault(e["node"]["page_type"], []).append(e)

    meta: dict[str, dict] = {}
    earlier_core_ok = True
    for i, pt in enumerate(ordered):
        core = core_by_pt.get(pt, [])
        core_total = len(core)
        core_answered = sum(1 for e in core if e["coverage"] >= _UNLOCK_COVERAGE)
        core_ok = core_answered >= core_total  # vacuously true with no core
        meta[pt] = {
            "unlocked": i == 0 or earlier_core_ok,
            "core_total": core_total,
            "core_answered": core_answered,
            "core_ok": core_ok,
        }
        earlier_core_ok = earlier_core_ok and core_ok
    return ordered, meta


def _node_unlocked(node: dict, meta: dict[str, dict]) -> bool:
    """A node is reachable when its section is unlocked and either the node is
    ``core`` or its section's core is complete. The routing node is always
    reachable."""
    if node["id"] == _ROUTING_ID:
        return True
    m = meta.get(node["page_type"])
    if not m:
        return True
    return m["unlocked"] and (
        question_tree.tier(node["id"]) == "core" or m["core_ok"]
    )


def _sections(
    visible: list[dict], ordered: list[str], meta: dict[str, dict]
) -> list[dict]:
    groups: dict[str, list[dict]] = {}
    for e in visible:
        groups.setdefault(e["node"]["page_type"], []).append(e)
    out: list[dict] = []
    for pt in ordered:
        grp = groups.get(pt, [])
        w = sum(e["node"]["weight"] for e in grp)
        wc = sum(e["node"]["weight"] * e["coverage"] for e in grp)
        m = meta.get(pt, {})
        out.append(
            {
                "page_type": pt,
                "label": _PAGE_TYPE_LABELS.get(pt, pt.replace("_", " ").title()),
                "pct": round(100 * wc / w) if w else 0,
                "answered": sum(1 for e in grp if e["coverage"] >= 0.7),
                "total": len(grp),
                "unlocked": bool(m.get("unlocked", True)),
                "core_total": int(m.get("core_total", 0)),
                "core_answered": int(m.get("core_answered", 0)),
                "priority": max((e["node"]["weight"] for e in grp), default=0),
            }
        )
    return out


def _next(
    visible: list[dict],
    meta: dict[str, dict],
    intent_set: bool,
    offered: dict[str, str] | None = None,
) -> list[dict]:
    open_nodes = [
        (i, e)
        for i, e in enumerate(visible)
        if e["coverage"] < 1.0
        and not e.get("profile_derivable")
        and _node_unlocked(e["node"], meta)
    ]
    open_nodes.sort(key=lambda t: (-t[1]["node"]["weight"], t[0]))
    # until the intent is set, the routing node leads no matter its weight
    lead = not intent_set
    routing = [
        e for _, e in open_nodes if lead and e["node"]["id"] == _ROUTING_ID
    ]
    rest = [
        e
        for _, e in open_nodes
        if not (lead and e["node"]["id"] == _ROUTING_ID)
    ]
    ranked = routing + rest

    # Deprioritise (never exclude) a node offered within the cooldown window
    # — so a just-declined/deflected item stops monopolising the top slot
    # while there's something else open, but still resurfaces once nothing
    # fresher is left or the cooldown lapses. See _OFFER_COOLDOWN_SECONDS.
    def _fresh(e: dict) -> bool:
        ts = (offered or {}).get(e["node"]["id"])
        if not ts:
            return True
        age = _age_seconds(ts)
        return age is None or age >= _OFFER_COOLDOWN_SECONDS

    ranked = [e for e in ranked if _fresh(e)] + [e for e in ranked if not _fresh(e)]

    picked = []
    for e in ranked[:_NEXT_LIMIT]:
        n = e["node"]
        picked.append(
            {
                "id": n["id"],
                "label": n["label"],
                "page_type": n["page_type"],
                "kind": n["kind"],
                "options": n["options"],
                "scale": n["scale"],
                "ayma_prompt": n["ayma_prompt"],
                "weight": n["weight"],
            }
        )
    return picked


def _summarise(
    branch: str,
    intent_set: bool,
    evaluated: list[dict],
    offered: dict[str, str] | None = None,
) -> dict:
    visible = _visible(evaluated, intent_set)
    ordered, meta = _section_gating(visible, branch, intent_set)
    unlocked = [e for e in visible if _node_unlocked(e["node"], meta)]
    return {
        # scored over the *full* intent tree — a locked section still counts
        # against the max; gating is presentation only.
        "score": _score(evaluated),
        # progress over just the sections/nodes currently open to the user.
        "visible_score": _score(unlocked),
        # every node in the full tree is at full coverage — nothing left in
        # today's question set. Independent of `score`'s rounding.
        "complete": _fully_covered(evaluated),
        "intent": branch,
        "intent_set": intent_set,
        "sections": _sections(visible, ordered, meta),
        "next": _next(visible, meta, intent_set, offered),
        "updated_at": _now_iso(),
    }


# --- public API -----------------------------------------------------------


async def compute(db, uid: str) -> dict:
    """Full recompute: evaluate every node in the user's intent tree, persist
    the summary to ``profile/main.completeness`` and return it."""
    branch, intent_set, evaluated = await _evaluate(db, uid)
    offered = _read_offers(db, uid)
    result = _summarise(branch, intent_set, evaluated, offered)
    _persist(db, uid, result)
    return result


async def recompute(db, uid: str, *, force: bool = False) -> dict:
    """Debounced :func:`compute`. Returns the stored summary unchanged when it
    is younger than :data:`_DEBOUNCE_SECONDS`, unless ``force``."""
    if not db or not uid:
        return {}
    try:
        if not force:
            existing = _read_completeness(db, uid)
            if existing is not None:
                age = _age_seconds(existing.get("updated_at"))
                if age is not None and age < _DEBOUNCE_SECONDS:
                    return existing
        return await compute(db, uid)
    except Exception:  # noqa: BLE001 - runs as a background task; never propagate
        logger.exception("completeness: recompute failed for %s", uid)
        return {}


async def _safe_recompute(db, uid: str) -> None:
    try:
        await recompute(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("completeness: scheduled recompute failed for %s", uid)


def schedule(db, uid: str) -> bool:
    """Fire-and-forget a debounced recompute on the running loop. Returns False
    (a no-op) when there is no loop — e.g. a synchronous unit test."""
    if not db or not uid:
        return False
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return False
    loop.create_task(_safe_recompute(db, uid))
    return True


async def get_or_recompute(db, uid: str) -> dict:
    """The cached summary — stale-while-revalidate, not blocking-on-stale.

    A stale cached doc is still returned immediately, with a fire-and-forget
    background refresh kicked off via :func:`schedule` for next time, rather
    than making the request itself wait on a live recompute. ``compute()``
    can include a real synchronous Gemini call (:func:`_narrative_status`'s
    narrative-coverage pass) whenever the narrative-topic cache misses — and
    every account's narrative cache misses together the moment the question
    tree's topic set changes (a new node added/removed), since the cache key
    includes the topic id set. Founder report, right after the tree grew
    (13 new nodes, commit a604202): "Takes a long time to load the profile
    completeness" — that one-time mass cache invalidation made the existing
    blocking behavior visible everywhere at once, but the underlying
    "block the response on a live LLM call whenever the cache is 60s+ old"
    shape was already there and would resurface on every future tree change.

    Only a genuinely first-ever load (no cached doc at all — nothing to show
    regardless) still blocks on a synchronous :func:`compute`.
    """
    existing = _read_completeness(db, uid)
    if existing is not None:
        age = _age_seconds(existing.get("updated_at"))
        if age is None or age >= _DEBOUNCE_SECONDS:
            schedule(db, uid)
        return existing
    return await compute(db, uid)


async def questionnaire_view(db, uid: str) -> dict:
    """``{intent, intent_set, score, visible_score, nodes: [{...node..., tier,
    status, value, source, unlocked}]}`` for the user's intent tree — backs
    ``GET /questionnaire``. Until the intent is set, ``nodes`` covers only the
    global core; each node carries an ``unlocked`` flag for progressive
    disclosure (see :func:`_node_unlocked`)."""
    branch, intent_set, evaluated = await _evaluate(db, uid)
    visible = _visible(evaluated, intent_set)
    _, meta = _section_gating(visible, branch, intent_set)
    nodes = [
        {
            **e["node"],
            "status": e["status"],
            "value": e["value"],
            "source": e["source"],
            "unlocked": _node_unlocked(e["node"], meta),
        }
        for e in visible
    ]
    return {
        "intent": branch,
        "intent_set": intent_set,
        "score": _score(evaluated),
        "visible_score": _score(
            [e for e in visible if _node_unlocked(e["node"], meta)]
        ),
        "nodes": nodes,
    }


async def backfill(db, user_limit: int = 200) -> dict:
    """Force-recompute completeness for up to ``user_limit`` users that have a
    ``profile/main`` doc. Never raises."""
    out = {"users": 0, "recomputed": 0, "errors": 0}
    try:
        users = list(db.collection("users").stream())
    except Exception:  # noqa: BLE001
        logger.exception("completeness backfill: user scan failed")
        return out
    for snap in users:
        if out["users"] >= user_limit:
            break
        uid = snap.id
        try:
            prof = _profile_ref(db, uid).get()
            if not getattr(prof, "exists", False):
                continue
            out["users"] += 1
            await recompute(db, uid, force=True)
            out["recomputed"] += 1
        except Exception:  # noqa: BLE001
            logger.exception("completeness backfill failed for %s", uid)
            out["errors"] += 1
    return out
