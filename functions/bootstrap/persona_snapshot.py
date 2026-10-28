"""Persistent AI-avatar snapshot (founder directive 2026-10-27).

A user's AI avatar — the agent that represents them in an AI Date Simulation
(and, as a documented follow-up, in human-to-AI voice) — used to be assembled
*ad hoc* at sim-spawn time by :func:`practice_core.build_self_persona_context`
(profile + every wiki page + their own texting-style exemplars). That read a
lot of Firestore on the hot path. This module makes it a **standing, server-only
snapshot** that sims spawn from instantly:

    users/{uid}/persona/avatar

The snapshot holds everything needed to spin up the avatar with no live
assembly: the distilled persona/system brief, story highlights, the user's
style exemplars, their FULL private-context grounding (profile + all wiki incl.
``{{private}}`` spans + own sent DMs), gender (which drives the voice), plus
``updated_at`` / ``version`` / ``source_hash`` / ``stale`` / ``distilled``.

COST DISCIPLINE (strict, founder cap):

* Source writes (profile edit, wiki/chat ingest, DM send) only flip
  ``stale=True`` — :func:`mark_persona_stale`, cheap, NO LLM.
* The LLM distillation (:func:`build_persona_snapshot` with ``distill=True``)
  runs ONLY in the background sweep (:func:`run_sweep` →
  :func:`refresh_persona_if_due`), at most once per hour per user
  (``CONFIG.persona_snapshot_min_interval_seconds``), and is skipped entirely
  when ``source_hash`` is unchanged (an untouched user is never rebuilt).
* At sim-spawn a MISSING self snapshot is seeded once, LLM-free
  (``distill=False``) — instant, no metered call — and marked ``stale`` so the
  next sweep upgrades it with the distilled brief. The avatar is never rebuilt
  with an LLM on the spawn hot path.

PRIVACY: the snapshot content is the user's OWN full private grounding, the
same asymmetry Practice Date documents — a user's own agent may know everything
about *themselves*, but the ``prompts/date_sim.md`` disclosure filter forbids it
from ever *emitting* private specifics in the chat. Defence-in-depth here:
:func:`redact_private_leaks` scrubs obvious contact/address/ID patterns out of
the LLM-distilled brief before it is persisted. The snapshot is SERVER-ONLY —
``firestore.rules`` denies all client access to ``users/{uid}/persona/**``.

Gated on the AI-Avatar opt-in: a snapshot is never built, refreshed, or spawned
for a user with ``ai_avatar_enabled == False`` (:func:`practice_core.
ai_avatar_enabled`), and an existing one is deleted when they opt out.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import time

import practice_core
import practice_llm
import schema
import token_ledger
from config import CONFIG
from pathlib import Path

logger = logging.getLogger("ayma.persona_snapshot")

PERSONA_COLLECTION = schema.PERSONA  # single source of truth: "persona"
AVATAR_DOC = "avatar"
SNAPSHOT_VERSION = 1

_PROMPT_DIR = Path(__file__).parent / "prompts"
_DISTILL_PROMPT_PATH = _PROMPT_DIR / "persona_snapshot.md"

_DISTILL_SCHEMA = {
    "type": "object",
    "properties": {
        "brief": {"type": "string"},
        "story_highlights": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["brief", "story_highlights"],
}

# Defence-in-depth: obvious private-detail patterns scrubbed out of the
# LLM-distilled brief before it is stored, even though the distillation prompt
# already forbids them (the disclosure filter is the primary guard). Each entry
# is (category, compiled-regex); a match is replaced with ``_REDACTED``.
_REDACTED = "[redacted]"
_LEAK_PATTERNS: tuple[tuple[str, "re.Pattern[str]"], ...] = (
    ("email", re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b")),
    (
        "phone",
        re.compile(
            r"(?<!\d)(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}(?!\d)"
        ),
    ),
    ("ssn", re.compile(r"\b\d{3}-\d{2}-\d{4}\b")),
    (
        "street_address",
        re.compile(
            r"\b\d{1,5}\s+(?:[A-Za-z0-9.'-]+\s){0,4}"
            r"(?:street|st|avenue|ave|road|rd|lane|ln|drive|dr|boulevard|blvd|"
            r"court|ct|way|place|pl|terrace|ter|circle|cir|highway|hwy)\b\.?",
            re.IGNORECASE,
        ),
    ),
)


def redact_private_leaks(text: str) -> tuple[str, list[str]]:
    """Scrub obvious private-detail patterns (email, phone, SSN, street
    address) out of ``text`` and report which categories fired.

    Defence-in-depth over the distillation prompt's disclosure filter, applied
    to the LLM-produced brief/highlights before they are persisted. Never
    raises; a non-string input yields ``("", [])``."""
    if not text or not isinstance(text, str):
        return "", []
    flagged: list[str] = []
    out = text
    for category, pattern in _LEAK_PATTERNS:
        if pattern.search(out):
            flagged.append(category)
            out = pattern.sub(_REDACTED, out)
    return out, flagged


# --------------------------------------------------------------------------- #
# Firestore doc <-> PersonaContext
# --------------------------------------------------------------------------- #
def _ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection(PERSONA_COLLECTION)
        .document(AVATAR_DOC)
    )


def _grounding(ctx: practice_core.PersonaContext) -> dict:
    """The serialised grounding a snapshot stores — exactly the fields needed to
    reconstruct the self :class:`PersonaContext` at spawn, with no live read."""
    return {
        "name": ctx.name,
        "age": ctx.age,
        "gender": ctx.gender,
        "location": ctx.location,
        "pages": [
            {"title": str(p.get("title") or ""), "body": str(p.get("body") or "")}
            for p in (ctx.pages or [])
        ],
        "style_exemplars": list(ctx.style_exemplars or []),
        "photo_count": int(ctx.photo_count or 0),
    }


def _ctx_from_doc(uid: str, data: dict) -> practice_core.PersonaContext | None:
    """Reconstruct the self :class:`PersonaContext` from a stored snapshot doc.
    Returns ``None`` when the doc has no usable grounding (treated as missing)."""
    g = (data or {}).get("grounding") or {}
    name = str(g.get("name") or "").strip()
    if not name:
        return None
    return practice_core.PersonaContext(
        target_uid=uid,
        name=name,
        age=g.get("age"),
        gender=str(g.get("gender") or ""),
        location=str(g.get("location") or ""),
        pages=[
            {"title": str(p.get("title") or ""), "body": str(p.get("body") or "")}
            for p in (g.get("pages") or [])
        ],
        style_exemplars=[str(x) for x in (g.get("style_exemplars") or [])],
        photo_count=int(g.get("photo_count") or 0),
    )


def compute_source_hash(ctx: practice_core.PersonaContext) -> str:
    """A stable hash over the snapshot's inputs (profile fields + wiki pages +
    style exemplars). An unchanged user hashes identically, so the background
    refresh can skip the LLM rebuild entirely when nothing has changed."""
    payload = {
        "v": SNAPSHOT_VERSION,
        "name": ctx.name,
        "age": ctx.age,
        "gender": ctx.gender,
        "location": ctx.location,
        "photo_count": int(ctx.photo_count or 0),
        "pages": sorted(
            (str(p.get("title") or ""), str(p.get("body") or ""))
            for p in (ctx.pages or [])
        ),
        "style_exemplars": list(ctx.style_exemplars or []),
    }
    blob = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


# --------------------------------------------------------------------------- #
# Avatar readiness score (0-100) + low-context flag
# --------------------------------------------------------------------------- #
# readiness_score = round(100 * (profile_weight * profile_completeness
#                                + conversation_weight * conversation_volume)),
# both sub-metrics normalized to 0..1. Weights LOCKED 80/20 (config). The score
# rides along with every snapshot (re)build — same <=1/hour, only-on-change
# cadence — and is surfaced to the sim preflight so the UI can warn when a
# match "doesn't have much context yet". Copy the UI shows (Flutter follow-up):
# "{name} doesn't have much context yet — a simulated chat with their AI won't
#  be an accurate reflection of them."
LOW_CONTEXT_COPY = (
    "{name} doesn't have much context yet — a simulated chat with their AI "
    "won't be an accurate reflection of them."
)


def _profile_completeness(ctx: practice_core.PersonaContext) -> float:
    """Fraction (0..1) of the key profile/wiki signals this person has filled:
    name, age, gender, location, at least one photo, and wiki presence (page
    count vs ``persona_readiness_wiki_page_target``). Six equally weighted
    signals; the wiki one is fractional, the rest are present/absent."""
    target = max(1, CONFIG.persona_readiness_wiki_page_target)
    page_bodies = [p for p in (ctx.pages or []) if str(p.get("body") or "").strip()]
    signals = [
        1.0 if ctx.name.strip() else 0.0,
        1.0 if ctx.age else 0.0,
        1.0 if ctx.gender.strip() else 0.0,
        1.0 if ctx.location.strip() else 0.0,
        1.0 if (ctx.photo_count or 0) > 0 else 0.0,
        min(len(page_bodies) / target, 1.0),
    ]
    return sum(signals) / len(signals)


def _conversation_volume(ctx: practice_core.PersonaContext) -> float:
    """Normalized measure (0..1) of how much this person has chatted with other
    users, from the capped sample of their OWN recent sent DM exemplars
    (``PersonaContext.style_exemplars``) vs
    ``persona_readiness_conversation_target``. Uses the already-gathered sample
    (no extra Firestore read); it is capped/short-only, so it under-counts very
    chatty users — a true uncapped own-message count is a documented follow-up."""
    target = max(1, CONFIG.persona_readiness_conversation_target)
    return min(len(ctx.style_exemplars or []) / target, 1.0)


def compute_readiness_score(
    profile_completeness: float, conversation_volume: float
) -> int:
    """The 0-100 avatar readiness score from the two normalized sub-metrics,
    using the LOCKED config weights (profile 80%, conversation 20%)."""
    pc = max(0.0, min(1.0, profile_completeness))
    cv = max(0.0, min(1.0, conversation_volume))
    raw = 100.0 * (
        CONFIG.persona_readiness_profile_weight * pc
        + CONFIG.persona_readiness_conversation_weight * cv
    )
    return int(round(max(0.0, min(100.0, raw))))


def is_low_context(readiness_score: int) -> bool:
    """Whether a readiness score is below the config warning threshold."""
    return readiness_score < CONFIG.persona_readiness_low_context_threshold


def readiness_for_context(ctx: practice_core.PersonaContext) -> dict:
    """The full readiness block for a :class:`PersonaContext`:
    ``{readiness_score, low_context, profile_completeness, conversation_volume}``."""
    pc = _profile_completeness(ctx)
    cv = _conversation_volume(ctx)
    score = compute_readiness_score(pc, cv)
    return {
        "readiness_score": score,
        "low_context": is_low_context(score),
        "profile_completeness": round(pc, 4),
        "conversation_volume": round(cv, 4),
    }


# --------------------------------------------------------------------------- #
# Read / mark-stale (both cheap, no LLM)
# --------------------------------------------------------------------------- #
def get_persona_snapshot(db, uid: str) -> practice_core.PersonaContext | None:
    """Read the standing avatar snapshot for ``uid`` and return it as a ready
    :class:`PersonaContext` — instant, no live assembly. Returns ``None`` when
    there is no usable snapshot (missing or empty); callers then seed one."""
    uid = (uid or "").strip()
    if not uid:
        return None
    try:
        snap = _ref(db, uid).get()
    except Exception:  # noqa: BLE001 - a read blip is treated as "no snapshot"
        logger.warning("persona snapshot read failed for %s", uid, exc_info=True)
        return None
    if not getattr(snap, "exists", False):
        return None
    return _ctx_from_doc(uid, snap.to_dict() or {})


def preflight_readiness(db, viewer_uid: str, other_uid: str) -> dict | None:
    """The match's avatar-readiness block for a sim preflight, so the UI can
    warn before the run. Returns ``{name, readiness_score, low_context,
    message}`` (``message`` only when low-context), or ``None`` when the match
    has no simulatable profile / has opted out.

    Prefers the match's stored snapshot score (computed from their FULL own
    context — the most accurate). When they have no snapshot, it falls back to a
    PUBLIC-profile-only estimate (``build_persona_context`` — never reads the
    other user's private DMs), so conversation volume reads as 0 and the match
    correctly shows as low-context."""
    other_uid = (other_uid or "").strip()
    if not other_uid:
        return None
    if not practice_core.ai_avatar_enabled(db, other_uid):
        return None
    name = ""
    score: int | None = None
    low: bool | None = None
    try:
        snap = _ref(db, other_uid).get()
    except Exception:  # noqa: BLE001 - fall back to the public estimate below
        snap = None
    data = snap.to_dict() if snap is not None and getattr(snap, "exists", False) else None
    if data and isinstance(data.get("readiness_score"), (int, float)):
        g = data.get("grounding") or {}
        name = str(g.get("name") or "").strip()
        score = int(data["readiness_score"])
        low = bool(data.get("low_context"))
    if score is None:
        # No snapshot: public-profile-only estimate (privacy-safe).
        ctx = practice_core.build_persona_context(db, viewer_uid, other_uid)
        if ctx is None:
            return None
        name = ctx.name
        r = readiness_for_context(ctx)
        score, low = r["readiness_score"], r["low_context"]
    out = {"name": name, "readiness_score": score, "low_context": low}
    if low:
        out["message"] = LOW_CONTEXT_COPY.format(name=name or "This person")
    return out


def mark_persona_stale(db, uid: str) -> None:
    """Flag the user's avatar snapshot as needing a rebuild — cheap, NO LLM.

    Called from backend source-write sites (profile edit, wiki/chat ingest, DM
    send). Only flips ``stale=True``; it deliberately does NOT touch
    ``updated_at`` so it can never slide the once-per-hour rebuild window. Fully
    best-effort: a write blip must never break the source write that triggered
    it, so this never raises."""
    uid = (uid or "").strip()
    if not uid:
        return
    try:
        _ref(db, uid).set({"stale": True, "stale_at": time.time()}, merge=True)
    except Exception:  # noqa: BLE001 - marking stale must never break a write
        logger.warning("persona mark-stale failed for %s", uid, exc_info=True)


# --------------------------------------------------------------------------- #
# Build (the distillation) + background refresh (the only LLM path)
# --------------------------------------------------------------------------- #
def _read_prompt() -> str:
    return _DISTILL_PROMPT_PATH.read_text(encoding="utf-8").strip()


async def build_persona_snapshot(
    db, uid: str, *, distill: bool = True
) -> practice_core.PersonaContext | None:
    """Produce and persist ``users/{uid}/persona/avatar`` from the user's full
    own context, and return it as a :class:`PersonaContext`.

    ``distill=True`` (the background path) runs ONE metered LLM call to produce
    the distilled persona/system brief + story highlights, scrubs them with
    :func:`redact_private_leaks`, and writes ``stale=False`` / ``distilled=True``.

    ``distill=False`` (the sim-spawn seed path) is LLM-free and instant: it
    writes the grounding with no brief and ``stale=True`` / ``distilled=False``
    so the next background sweep upgrades it. Either way the stored grounding is
    complete, so the avatar spawns fully from the snapshot.

    Returns ``None`` (writing nothing) when the user has opted out of an AI
    Avatar — deleting any existing snapshot — or has no set-up profile."""
    uid = (uid or "").strip()
    if not uid:
        return None
    if not practice_core.ai_avatar_enabled(db, uid):
        # Opted out: never maintain a snapshot; remove any that exists.
        try:
            _ref(db, uid).delete()
        except Exception:  # noqa: BLE001 - best effort
            logger.warning("persona snapshot delete failed for %s", uid, exc_info=True)
        return None

    ctx = practice_core.build_self_persona_context(db, uid)
    if ctx is None:
        return None

    source_hash = compute_source_hash(ctx)
    brief = ""
    highlights: list[str] = []
    leak_flags: list[str] = []
    distilled = False

    if distill:
        try:
            result = await practice_llm.generate_structured(
                _read_prompt(),
                ctx.to_prompt_block(),
                _DISTILL_SCHEMA,
                uid=uid,
                feature=token_ledger.FEATURE_AVATAR,
            )
            if isinstance(result, dict):
                brief, brief_flags = redact_private_leaks(str(result.get("brief") or ""))
                leak_flags.extend(brief_flags)
                for h in result.get("story_highlights") or []:
                    clean, hf = redact_private_leaks(str(h))
                    leak_flags.extend(hf)
                    clean = clean.strip()
                    if clean:
                        highlights.append(clean)
                distilled = True
        except Exception:  # noqa: BLE001 - a distill failure still persists the
            # grounding (usable for sims); the sweep retries the brief later.
            logger.warning("persona distillation failed for %s", uid, exc_info=True)

    readiness = readiness_for_context(ctx)
    doc = {
        "version": SNAPSHOT_VERSION,
        "grounding": _grounding(ctx),
        "style_exemplars": list(ctx.style_exemplars or []),
        "gender": ctx.gender,
        "brief": brief,
        "story_highlights": highlights,
        "leak_flags": sorted(set(leak_flags)),
        "source_hash": source_hash,
        "distilled": distilled,
        # Avatar readiness (0-100) + low-context flag, recomputed every rebuild.
        "readiness_score": readiness["readiness_score"],
        "low_context": readiness["low_context"],
        "profile_completeness": readiness["profile_completeness"],
        "conversation_volume": readiness["conversation_volume"],
        # Not distilled yet => still stale so the next sweep produces the brief.
        "stale": not distilled,
        "updated_at": time.time(),
    }
    try:
        _ref(db, uid).set(doc)
    except Exception:  # noqa: BLE001 - a write blip leaves the snapshot absent;
        # the next trigger/sweep rebuilds it.
        logger.warning("persona snapshot write failed for %s", uid, exc_info=True)
        return None
    return _ctx_from_doc(uid, doc)


async def refresh_persona_if_due(
    db, uid: str, *, now: float | None = None, min_interval: float | None = None
) -> dict:
    """Rebuild the avatar snapshot IFF it is genuinely due — the single guarded
    entry point for the background (LLM) refresh. Returns ``{"status": ...}``.

    The gates, in order (each a cheap check before the expensive one):

    1. opted out  -> delete any snapshot, ``"opted_out"``.
    2. not stale and not missing -> ``"fresh"`` (nothing to do; no context read).
    3. exists and younger than the min interval -> ``"rate_limited"`` (enforces
       at most one rebuild per hour per user, even while stale).
    4. no set-up profile -> ``"no_profile"``.
    5. ``source_hash`` unchanged vs the stored one -> clear ``stale`` only, NO
       LLM, ``"unchanged"`` (an untouched user is never rebuilt).
    6. otherwise -> run the distillation, ``"rebuilt"``."""
    uid = (uid or "").strip()
    if not uid:
        return {"status": "skipped"}
    now = time.time() if now is None else now
    if min_interval is None:
        min_interval = CONFIG.persona_snapshot_min_interval_seconds

    if not practice_core.ai_avatar_enabled(db, uid):
        try:
            if _ref(db, uid).get().exists:
                _ref(db, uid).delete()
        except Exception:  # noqa: BLE001 - best effort
            logger.warning("opted-out snapshot cleanup failed for %s", uid, exc_info=True)
        return {"status": "opted_out"}

    snap = _ref(db, uid).get()
    existing = snap.to_dict() if getattr(snap, "exists", False) else None

    if existing is not None:
        if not existing.get("stale"):
            return {"status": "fresh"}
        updated_at = existing.get("updated_at")
        if isinstance(updated_at, (int, float)) and (now - updated_at) < min_interval:
            return {"status": "rate_limited"}

    ctx = practice_core.build_self_persona_context(db, uid)
    if ctx is None:
        return {"status": "no_profile"}

    new_hash = compute_source_hash(ctx)
    if (
        existing is not None
        and existing.get("distilled")
        and existing.get("source_hash") == new_hash
    ):
        # Content is identical to the last distilled build — clear the stale
        # flag without spending a single token.
        try:
            _ref(db, uid).update({"stale": False})
        except Exception:  # noqa: BLE001 - best effort
            logger.warning("persona stale-clear failed for %s", uid, exc_info=True)
        return {"status": "unchanged"}

    await build_persona_snapshot(db, uid, distill=True)
    return {"status": "rebuilt"}


async def run_sweep(db, user_limit: int | None = None) -> dict:
    """The periodic background sweep (``POST /cron/persona-snapshot``). Walks up
    to ``user_limit`` users and calls :func:`refresh_persona_if_due` for each, so
    stale/missing avatars are rebuilt — rate-limited to at most one LLM rebuild
    per hour per user, and skipped entirely when their source content is
    unchanged. Never raises for a single user; one bad user never stops the
    sweep."""
    limit = user_limit or CONFIG.persona_snapshot_sweep_limit
    counts: dict[str, int] = {}
    checked = 0
    try:
        users = [s.id for s in db.collection("users").limit(limit).stream()]
    except Exception:  # noqa: BLE001
        logger.exception("persona sweep: user listing failed")
        return {"checked": 0, "statuses": counts}
    for uid in users:
        checked += 1
        try:
            result = await refresh_persona_if_due(db, uid)
            status = result.get("status", "skipped")
        except Exception:  # noqa: BLE001 - one bad user never stops the sweep
            logger.exception("persona sweep failed for %s", uid)
            status = "error"
        counts[status] = counts.get(status, 0) + 1
    return {"checked": checked, "statuses": counts}
