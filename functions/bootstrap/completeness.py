"""Per-user profile-completeness engine for the tree-based questionnaire.

Scores how much of the user's intent-routed question tree
(:mod:`question_tree`) is answered — from the ``users/{uid}/questionnaire``
store, from derivable ``profile/main`` fields, and, for every node not covered
by those, from a single cached LLM pass over the user's wiki text (the
free-text "story"). That story pass marks a narrative node covered/partial and,
for a structured node (enum/scale/...), marks it covered when the story states
a concrete answer — so an answer the user gave in chat that ``wiki_ingest``
folded into the story, but that was never written to the questionnaire store,
still counts as answered and the question stops being re-asked.

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

from prompt import load_prompt_file
from config import CONFIG
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


def _profile_answered(node_id: str, profile: dict) -> bool:
    """True when a preboarding or recorded ``profile/main`` field currently answers
    ``node_id`` — i.e. the node is profile-derivable (see
    :func:`_profile_derived_field`), or holds a non-blank recorded ``qz_*`` value."""
    field = _profile_derived_field(node_id, profile)
    if bool(field) and not _blank(profile.get(field)):
        return True
    return not _blank(profile.get(f"qz_{node_id}"))

_NARRATIVE_COVERAGE = {"covered": 1.0, "partial": 0.5, "missing": 0.0}

# Section labels come from :mod:`question_tree` — the canonical founder titles
# (``section_meta``, tree v6: "About Me", "Life Goals", "Little Extras", …) so
# Profile Completeness shows the new section names (founder order, point 7),
# falling back to the older ``PAGE_TYPE_LABELS`` for any page_type without
# canonical metadata. The extra keys cover non-section profile surfaces.
_PAGE_TYPE_LABELS = {
    **question_tree.PAGE_TYPE_LABELS,
    **{pt: question_tree.section_title(pt) for pt in question_tree.section_meta()},
    "steering": "How to talk to me",
    "web_findings": "From the web",
    "face_analysis": "Face analysis",
    "body_analysis": "Body analysis",
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
# `assessment` (ai_assessment.py) is excluded for the same reason: it is
# Ayma's own judgment page, not profile material, and it rewrites on its own
# cadence — hashing it here would re-trigger paid narrative passes for no
# narrative change.
#
# `web_findings`, `face_analysis` and `body_analysis` are excluded because they
# are things Ayma found out *about* the user (a scraped LinkedIn line, a photo
# read), not answers the user gave. Counting them let a stray web note mark a
# narrative node "covered" (e.g. career, family) without the user ever having
# said it, which is how a profile could read complete while Ayma still knew
# nothing concrete.
_NARRATIVE_EXCLUDED_PAGE_TYPES = frozenset(
    {
        "interactions",
        "steering",
        "assessment",
        "web_findings",
        "face_analysis",
        "body_analysis",
    }
)

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
    from config import CONFIG

    try:
        snap = _profile_ref(db, uid).get()
        prof = (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
        if CONFIG.person_graph_reads:
            import person_graph_source

            prof = person_graph_source.hydrate_profile(db, uid, prof)
        return prof
    except Exception:  # noqa: BLE001 - a read failure just yields no derivations
        logger.exception("completeness: profile read failed for %s", uid)
        return {}


def _questionnaire_store(db, uid: str) -> dict[str, dict]:
    # Graph-authoritative: the recorded answers now live on their seed nodes, so
    # `recompute` / `next_questions` read the graph (not the questionnaire
    # subcollection the writer swap stops populating). Same ``{node_id: {value,
    # source}}`` shape the stream produced. Flag off → today's store read.
    from config import CONFIG

    if CONFIG.person_graph_reads:
        try:
            import person_graph_source
            import person_graph_store as store

            # completeness_qstore (not structured_qstore): also counts the
            # dealt-with (PREFER_NOT_TO_SAY) seed nodes as covered, so a skipped /
            # declined / "none" question keeps its old covered status and the
            # score doesn't drop or re-open it (NOTE 233 defect 2).
            return person_graph_source.completeness_qstore(store.effective(db, uid))
        except Exception:  # noqa: BLE001
            logger.exception("completeness: graph questionnaire read failed for %s", uid)
            return {}
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


def is_current(result: dict | None) -> bool:
    """True when ``result`` was computed against the running question tree.
    A result from an older tree version (or from before versions existed) can
    claim ``complete`` for nodes that have since been added, so it must never
    be trusted as-is."""
    return isinstance(result, dict) and result.get("tree_version") == (
        question_tree.version()
    )


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
    raw = (
        (store.get("relationship_intent") or {}).get("value")
        or profile.get("relationship_intent")
        or profile.get("qz_relationship_intent")
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


# A node's narrative verdict: its coverage status plus, for a covered/partial
# node, a short phrase of what the story already says (so a partial node is
# followed up on, not re-asked cold — founder requirement 2, 2026-11-14).
_MISSING_VERDICT = {"status": "missing", "known": ""}


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
                        "known": {"type": "string"},
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
        load_prompt_file(_PROMPT_PATH),
        schema,
        uid=uid,
        feature=token_ledger.FEATURE_COMPLETENESS,
        enforce_cap=False,
        temperature=0.0,
    )
    wanted = {t["id"] for t in topics}
    out: dict[str, dict] = {}
    for a in (raw or {}).get("assessments", []):
        if a.get("id") in wanted and a.get("status") in _NARRATIVE_COVERAGE:
            known = str(a.get("known") or "").strip()
            out[a["id"]] = {
                "status": a["status"],
                # Only a covered/partial node carries a "known" gist; a missing
                # one has nothing to follow up on.
                "known": known if a["status"] != "missing" else "",
            }
    for t in topics:
        out.setdefault(t["id"], dict(_MISSING_VERDICT))
    return out


async def _narrative_status(db, uid: str, targets: list[dict]) -> dict[str, dict]:
    """``{node_id: {"status": "covered"|"partial"|"missing", "known": str}}`` for
    the nodes in ``targets`` (narrative *and* structured) judged against the
    user's free-text story. Cached on ``users/{uid}/completeness_cache/narrative``
    keyed by a hash of the wiki text + the target id set, so an unchanged wiki
    never re-hits Gemini."""
    if not targets:
        return {}
    topics = [
        {"id": n["id"], "label": n["label"], "ayma_prompt": n["ayma_prompt"]}
        for n in targets
    ]
    missing_all = {t["id"]: dict(_MISSING_VERDICT) for t in topics}
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
    # The judging prompt is part of the key so tightening it re-judges every
    # cached wiki instead of serving verdicts made under the old, laxer rules.
    key = hashlib.sha256(
        (
            "|".join(sorted(t["id"] for t in topics))
            + "||"
            + load_prompt_file(_PROMPT_PATH)
            + "||"
            + wiki_text
        ).encode("utf-8")
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
                res = cached["result"]
                return {
                    t["id"]: (
                        res[t["id"]]
                        if isinstance(res.get(t["id"]), dict)
                        else dict(_MISSING_VERDICT)
                    )
                    for t in topics
                }
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

    # Nodes whose answer may already live in the user's free-text story (the
    # wiki) rather than in the structured questionnaire store: every open node
    # not already answered by a preboarding profile field or a recorded
    # questionnaire entry. Narrative nodes have always been judged this way;
    # structured nodes (enum/scale/multi/bool) are included too — see the
    # per-node branch below. The routing node is excluded: its branch is
    # resolved separately (`_resolve_intent`) and set through its own skill, so
    # a passing story mention must never silently "cover" it out of the intent
    # gate.
    story_targets = [
        n
        for n in nodes
        if n["id"] != _ROUTING_ID
        and n["id"] not in store
        and not _profile_answered(n["id"], profile)
    ]
    story = await _narrative_status(db, uid, story_targets)

    evaluated: list[dict] = []
    for n in nodes:
        nid = n["id"]
        # What's already known for this node, surfaced so a partially-answered
        # node is followed up on (not re-asked cold) — founder requirement 2.
        known = ""
        deriv = _profile_derived_field(nid, profile)
        qz_val = profile.get(f"qz_{nid}")
        if deriv and not _blank(profile.get(deriv)):
            cov, src, val = 1.0, "profile", _stringify(profile.get(deriv))
            known = val
        elif not _blank(qz_val):
            cov, src, val = 1.0, "profile", _stringify(qz_val)
            known = val
        elif nid in store:
            entry = store[nid]
            raw_src = str(entry.get("source") or "stated").lower()
            cov = 0.7 if raw_src == "inferred" else 1.0
            src = raw_src if raw_src in ("stated", "inferred") else "stated"
            val = entry.get("value")
            known = _stringify(val) if val is not None else ""
        else:
            # Answer not in the structured store — check the free-text story.
            # Founder bug (2026-10): `wiki_ingest` reliably folds every chat
            # answer into the story each turn, but `record_answer` (the only
            # writer of the questionnaire store) fires only when the model
            # remembers to call it. Scoring structured nodes against the store
            # alone left a story-captured answer invisible here, so
            # `next_questions` re-selected the same question forever ("it keeps
            # updating the story but asks the same thing again and again"). A
            # narrative node keeps its graded coverage (covered 1.0 /
            # partial 0.5); a structured node needs a concrete answer, so only
            # a `covered` story verdict satisfies it — a vague/partial mention
            # leaves the exact value unknown and the question still worth
            # asking.
            verdict = story.get(nid) or _MISSING_VERDICT
            st = verdict.get("status", "missing")
            if n["kind"] == "narrative":
                cov = _NARRATIVE_COVERAGE.get(st, 0.0)
            else:
                cov = 1.0 if st == "covered" else 0.0
            src = "wiki" if cov > 0 else None
            val = None
            if cov > 0:
                known = str(verdict.get("known") or "")
        evaluated.append(
            {
                "node": n,
                "coverage": cov,
                "status": _status(cov),
                "value": val,
                "source": src,
                "known": known,
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


# --- disclosure: intent gate (user+Ayma) + Ayma's own section/node order -----
#
# Two separate things live here, deliberately split (founder order,
# 2026-11-15):
#   * the INTENT gate (`_visible`) — branch-specific sections stay hidden for
#     everyone until the user picks a relationship intent. Unchanged.
#   * the SEQUENTIAL section/core gate (`_section_gating` -> `meta`) — this now
#     orders only AYMA's guided flow (`_next` via `_node_unlocked`). The user is
#     NOT gated by it: every section is open to answer in any order
#     (`_node_open_to_user`, `_sections` emits `unlocked: True`).

_ROUTING_ID = "relationship_intent"

# A core node counts as "answered" for unlock purposes at this coverage or
# above — i.e. covered (1.0) or a confident inference / partial (0.7).
_UNLOCK_COVERAGE = 0.7

# Promoted sections: always reachable regardless of how far the user has got in
# the sequential core-first flow, and never gating the sections that follow
# them in priority order. `taste` (music/film/food — the public Qloo Taste page
# that `taste_match.parse_taste` reads) is promoted here so its questions
# surface near the top of `next` for a user who hasn't answered them yet and
# show as a fillable topic on the complete-profile screen, rather than staying
# buried behind every earlier section's core. Its high node weights
# (`taste_music` is weight 5) then rank it among the first items offered. The
# normal identity -> personality -> ... progression is untouched. See
# docs/QLOO_TASTE.md and ARCHITECTURE.md (questionnaire / taste priority).
_EARLY_PAGE_TYPES = frozenset({"taste"})


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
    it is the first, a promoted :data:`_EARLY_PAGE_TYPES` section, or every core
    node of every earlier non-promoted section is answered. A promoted section
    is also transparent to the gate — it never locks the sections after it.
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
        early = pt in _EARLY_PAGE_TYPES
        meta[pt] = {
            "unlocked": early or i == 0 or earlier_core_ok,
            "core_total": core_total,
            "core_answered": core_answered,
            "core_ok": core_ok,
        }
        # A promoted ("early") section is always open and is transparent to the
        # sequential gate: leaving it unanswered must not lock the sections
        # that follow it in priority order. See _EARLY_PAGE_TYPES.
        if not early:
            earlier_core_ok = earlier_core_ok and core_ok
    return ordered, meta


def _guided_level_ceiling(visible: list[dict]) -> int | None:
    """Breadth-first-by-level guidance (person-graph §5.2): the shallowest node
    ``level`` that still has an open node — Ayma fills that level across ALL
    sections before opening any deeper one. ``None`` when the level-first flow is
    off (``person_graph_reads``), so the caller keeps today's section gate. Also
    ``None`` when nothing is open. The routing node is handled separately (always
    reachable), so it never holds the ceiling at level 1."""
    if not CONFIG.person_graph_reads:
        return None
    open_levels = [
        int(e["node"].get("level") or 2)
        for e in visible
        if e["coverage"] < 1.0
        and not e.get("profile_derivable")
        and e["node"]["id"] != _ROUTING_ID
    ]
    return min(open_levels) if open_levels else None


def _node_unlocked(
    node: dict, meta: dict[str, dict], level_ceiling: int | None = None
) -> bool:
    """Reachable in **Ayma's own guided flow**. The routing node is always
    reachable; otherwise:

    - ``level_ceiling`` given (person-graph §5.2, breadth-first by level): the
      node's ``level`` is at or below the shallowest still-open level — Ayma
      works one level across every section before going deeper.
    - ``level_ceiling`` ``None`` (today): her sequential section gate is on and
      the node is ``core`` or its section's core is complete.

    This is *Ayma's* ordering only — it drives :func:`_next`
    (``next_questions``), NOT what the user may open (:func:`_node_open_to_user`,
    which is never level-gated — §5.3, the user has no locks)."""
    if node["id"] == _ROUTING_ID:
        return True
    if level_ceiling is not None:
        return int(node.get("level") or 2) <= level_ceiling
    m = meta.get(node["page_type"])
    if not m:
        return True
    return m["unlocked"] and (
        question_tree.tier(node["id"]) == "core" or m["core_ok"]
    )


def _node_open_to_user(node: dict, meta: dict[str, dict]) -> bool:
    """Reachable in the **user-facing** "Complete your profile" view. The
    sequential section gate is removed — the user may open and answer ANY
    section in any order (founder order, 2026-11-15) — so a node is open
    regardless of whether earlier sections' cores are done. A section's deeper
    detail still reveals only once that section's own core is covered (the
    within-section progressive reveal is unchanged). The routing node is always
    reachable. Ayma's guided ordering stays separate in :func:`_node_unlocked`."""
    if node["id"] == _ROUTING_ID:
        return True
    m = meta.get(node["page_type"])
    if not m:
        return True
    return question_tree.tier(node["id"]) == "core" or m["core_ok"]


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
                # The user-facing view never locks a section: every section is
                # open to answer in any order (founder order, 2026-11-15).
                # Ayma's own flow still orders itself via `_next`/`_node_unlocked`.
                "unlocked": True,
                "core_total": int(m.get("core_total", 0)),
                "core_answered": int(m.get("core_answered", 0)),
                "priority": max((e["node"]["weight"] for e in grp), default=0),
            }
        )
    return out


def _graph_already_answered(db, uid: str, node_id: str) -> bool:
    """Check-before-asking (founder Nov 17, part c): True when the person graph
    already holds a concrete answer for this question on a node OTHER than its
    own seed node — an emergent child or a same-topic related node captured from
    conversation (e.g. the user told Ayma in chat and ``wiki_ingest`` grew an
    emergent node, but ``record_answer`` never wrote the seed node back). Such a
    question must never be re-asked.

    Routed through the single graph lookup (``person_graph_store.graph_lookup``),
    exactly as its design intends ("what to ask next: what the graph holds vs
    what's missing"). The anchor IS this question's seed node; its descendants
    and related-linked nodes are the same topic, so a concrete answer on any of
    them covers the question. The seed node itself is excluded (an answered seed
    is already scored ``covered`` and never reaches here; a still-blank one must
    stay open), and so are its ancestors (a broader topic being answered does not
    answer this specific question). Only applies when the graph is the
    authoritative store; best-effort — a graph read failure never blocks a
    question from being offered."""
    if not CONFIG.person_graph_reads or not db or not uid or not node_id:
        return False
    try:
        import person_graph_store as store

        # Ayma-only nodes (assessment/judgment) are Ayma's own notes, never the
        # user's answer to this question, so they must not satisfy it.
        res = store.graph_lookup(db, uid, node_id=node_id, include_ayma_only=False)
        nodes = res.get("nodes") or []
        by_id = {n.id: n for n in nodes}
        # the seed node's ancestor chain — an answer on a broader node up the
        # tree does not answer this question, so it is not a skip signal.
        ancestors: set[str] = set()
        cur = by_id.get(node_id)
        guard = 0
        while cur is not None and getattr(cur, "parent", None) and guard < 64:
            ancestors.add(cur.parent)
            cur = by_id.get(cur.parent)
            guard += 1
        for n in nodes:
            if n.id == node_id or n.id in ancestors:
                continue
            if getattr(n, "answer", None) not in (None, "", [], {}):
                return True
    except Exception:  # noqa: BLE001 - never block question selection on a read
        logger.exception(
            "completeness: graph answer-check failed for %s/%s", uid, node_id
        )
    return False


def _next(
    visible: list[dict],
    meta: dict[str, dict],
    intent_set: bool,
    offered: dict[str, str] | None = None,
    level_ceiling: int | None = None,
    db=None,
    uid: str | None = None,
) -> list[dict]:
    open_nodes = [
        (i, e)
        for i, e in enumerate(visible)
        if e["coverage"] < 1.0
        and not e.get("profile_derivable")
        and _node_unlocked(e["node"], meta, level_ceiling)
    ]
    if level_ceiling is not None:
        # Breadth-first by level (§5.2): shallower levels first, then by weight
        # within a level, then stable by original index.
        open_nodes.sort(
            key=lambda t: (int(t[1]["node"].get("level") or 2), -t[1]["node"]["weight"], t[0])
        )
    else:
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
    for e in ranked:
        if len(picked) >= _NEXT_LIMIT:
            break
        n = e["node"]
        # Check the graph before offering: a question whose answer the graph
        # already holds (on an emergent/related node, not its own seed node) is
        # skipped and the next open one takes its slot — never re-asked (part c).
        if _graph_already_answered(db, uid, n["id"]):
            continue
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
                "sensitive": bool(n.get("sensitive")),
                # Coverage state + what's already known, so the check-before-
                # asking gate can confirm the node's state and, for a partial
                # one, follow up on `known` instead of re-asking (reqs 1 & 2).
                "status": e.get("status"),
                "known": e.get("known") or "",
            }
        )
    return picked


def _summarise(
    branch: str,
    intent_set: bool,
    evaluated: list[dict],
    offered: dict[str, str] | None = None,
    db=None,
    uid: str | None = None,
) -> dict:
    visible = _visible(evaluated, intent_set)
    ordered, meta = _section_gating(visible, branch, intent_set)
    level_ceiling = _guided_level_ceiling(visible)
    unlocked = [e for e in visible if _node_unlocked(e["node"], meta, level_ceiling)]
    return {
        # scored over the *full* intent tree — a locked section still counts
        # against the max; gating is presentation only.
        "score": _score(evaluated),
        # progress over just the sections/nodes currently open to the user.
        "visible_score": _score(unlocked),
        # every node in the full tree is at full coverage — nothing left in
        # today's question set. Independent of `score`'s rounding.
        "complete": _fully_covered(evaluated),
        # which question tree produced this result; a stored result with a
        # different version is stale (see `_is_current`).
        "tree_version": question_tree.version(),
        "intent": branch,
        "intent_set": intent_set,
        "sections": _sections(visible, ordered, meta),
        "next": _next(
            visible, meta, intent_set, offered, level_ceiling, db=db, uid=uid
        ),
        "updated_at": _now_iso(),
    }


# --- public API -----------------------------------------------------------


async def compute(db, uid: str) -> dict:
    """Full recompute: evaluate every node in the user's intent tree, persist
    the summary to ``profile/main.completeness`` and return it."""
    branch, intent_set, evaluated = await _evaluate(db, uid)
    offered = _read_offers(db, uid)
    result = _summarise(branch, intent_set, evaluated, offered, db=db, uid=uid)
    # Recorded tree answers (so check-before-asking gate knows what is already recorded):
    recorded = [
        {
            "id": e["node"]["id"],
            "section": e["node"]["page_type"],
            "topic": e["node"]["label"],
            "value": str(e["known"] or e.get("value") or ""),
            "status": e["status"],
        }
        for e in evaluated
        if (e["coverage"] >= 0.7 or e["known"])
        and str(e["known"] or e.get("value") or "").strip()
    ]
    result["recorded"] = recorded
    # Volunteered / off-tree topics already captured (founder requirement 4):
    # carried on the summary so the check-before-asking gate (next_questions and
    # the per-turn note) treats them as known and never raises them again.
    try:
        import supplemental

        result["supplemental"] = supplemental.read_supplemental(db, uid)
    except Exception:  # noqa: BLE001 - supplemental is additive; never break compute
        logger.exception("completeness: supplemental read failed for %s", uid)
        result["supplemental"] = []
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
            if existing is not None and is_current(existing):
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
        if not is_current(existing):
            # Computed against an older question tree: never report it as
            # complete, and refresh it in the background right away.
            schedule(db, uid)
            return {**existing, "complete": False}
        age = _age_seconds(existing.get("updated_at"))
        if age is None or age >= _DEBOUNCE_SECONDS:
            schedule(db, uid)
        return existing
    return await compute(db, uid)


async def questionnaire_view(db, uid: str) -> dict:
    """``{intent, intent_set, score, visible_score, nodes: [{...node..., tier,
    status, value, source, unlocked}]}`` for the user's intent tree — backs
    ``GET /questionnaire``. Until the intent is set, ``nodes`` covers only the
    global core; each node carries an ``unlocked`` flag — open to the user to
    answer now (no section gate; a section's deep detail still reveals once its
    core is covered), see :func:`_node_open_to_user`."""
    branch, intent_set, evaluated = await _evaluate(db, uid)
    visible = _visible(evaluated, intent_set)
    _, meta = _section_gating(visible, branch, intent_set)
    nodes = [
        {
            **e["node"],
            "status": e["status"],
            "value": e["value"],
            "source": e["source"],
            "unlocked": _node_open_to_user(e["node"], meta),
        }
        for e in visible
    ]
    return {
        "intent": branch,
        "intent_set": intent_set,
        "score": _score(evaluated),
        "visible_score": _score(
            [
                e for e in visible
                if _node_unlocked(e["node"], meta, _guided_level_ceiling(visible))
            ]
        ),
        "nodes": nodes,
    }


async def section_pending(db, uid: str, page_type: str) -> list[dict]:
    """The still-open nodes of one "Complete your profile" section — those the
    user's checklist shows unfilled right now (open to the user, not
    ``covered``), core before deep as the checklist lists them. Backs the
    section's "Talk to Ayma about this" kickoff so Ayma opens on exactly these.
    Each entry is a :func:`questionnaire_view` node."""
    view = await questionnaire_view(db, uid)
    pending = [
        n for n in view["nodes"]
        if n.get("page_type") == page_type
        and n.get("unlocked")
        and n.get("status") != "covered"
    ]
    return sorted(pending, key=lambda n: question_tree.tier(n["id"]) != "core")


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
