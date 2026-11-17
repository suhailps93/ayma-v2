"""Candidate sourcing + Pass-1 heuristic scoring (ARCHITECTURE.md §5.1, §5.2,
§5.10 steps 2–3). No LLM here — Pass 2 (wiki-to-wiki) is ``matching_skill.py``.

Sourcing is a bounded scan of ``users`` (small scale; §5.3 caps the pool),
filtering on ``community``, a mutual orientation cross-match, and the block /
already-matched exclusions from §5.1. Pass 1 ranks the survivors on structured
fields only — age gap, same-city, shared wiki ``frontmatter`` — producing an
ordering hint, not a compatibility score.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from firebase_admin import firestore

import practice_seed
from config import CONFIG
from matching_schema import (
    MATCH_CANDIDATES_COLLECTION,
    block_id,
    clear_stale_candidates,
)
from pair_key import sorted_pair_key

logger = logging.getLogger("ayma.matching")

_INTEREST_TO_GENDER = {
    "women": {"woman"},
    "men": {"man"},
    "everyone": {"woman", "man", "non-binary", "other"},
}


def orientation_match(
    a_gender: str,
    a_interested: list[str],
    b_gender: str,
    b_interested: list[str],
) -> bool:
    """True when each side's ``interested_in`` covers the other's ``gender``."""

    def covers(interested: list[str], gender: str) -> bool:
        g = (gender or "").strip().lower()
        if not g:
            return False
        for i in interested or []:
            if g in _INTEREST_TO_GENDER.get(i.strip().lower(), set()):
                return True
        return False

    return covers(a_interested, b_gender) and covers(b_interested, a_gender)


def _age(birthdate) -> int | None:
    if isinstance(birthdate, str):
        try:
            birthdate = datetime.fromisoformat(birthdate)
        except ValueError:
            return None
    if not isinstance(birthdate, datetime):
        return None
    now = datetime.now(timezone.utc)
    if birthdate.tzinfo is None:
        birthdate = birthdate.replace(tzinfo=timezone.utc)
    return now.year - birthdate.year - (
        (now.month, now.day) < (birthdate.month, birthdate.day)
    )


def _frontmatter(db, uid: str) -> dict:
    # Person-graph authoritative: wiki-page frontmatter has no graph equivalent
    # (structured facts are seed-node answers the migrated scorer reads); the
    # frozen wiki is not read here. Empty == today's behaviour for a user whose
    # pages carry no frontmatter.
    from config import CONFIG

    if CONFIG.person_graph_reads:
        return {}
    merged: dict = {}
    for snap in (
        db.collection("users").document(uid).collection("wiki_pages").stream()
    ):
        fm = (snap.to_dict() or {}).get("frontmatter") or {}
        if isinstance(fm, dict):
            merged.update(fm)
    return merged


def heuristic_score(a: dict, b: dict, a_fm: dict, b_fm: dict) -> tuple[float, list[str]]:
    score = 1.0
    reasons: list[str] = []

    age_a, age_b = _age(a.get("birthdate")), _age(b.get("birthdate"))
    if age_a is not None and age_b is not None:
        gap = abs(age_a - age_b)
        score -= min(gap, 20) / 40.0  # up to -0.5 for a 20y gap
        reasons.append(f"age gap {gap}")

    loc_a = (a.get("location") or "").strip().lower()
    loc_b = (b.get("location") or "").strip().lower()
    if loc_a and loc_b:
        if loc_a == loc_b:
            score += 0.15
            reasons.append("same location")
        else:
            score -= 0.1
            reasons.append("different location")

    shared = [k for k, v in a_fm.items() if k in b_fm and b_fm[k] == v]
    if shared:
        score += min(len(shared), 5) * 0.05
        reasons.append("shared: " + ", ".join(sorted(shared)[:5]))

    return max(0.0, min(1.0, score)), reasons


def _blocked(db, uid: str, other: str) -> bool:
    blocks = db.collection("blocks")
    return (
        blocks.document(block_id(uid, other)).get().exists
        or blocks.document(block_id(other, uid)).get().exists
    )


def _already_matched(db, uid: str, other: str) -> bool:
    return (
        db.collection("matches")
        .document(sorted_pair_key(uid, other))
        .get()
        .exists
    )


def source_and_score(db, uid: str, limit: int | None = None) -> list[dict]:
    """Run Pass 1 for ``uid``: source candidates, score, write
    ``match_candidates``. Returns the written candidate summaries, best first."""
    limit = limit or CONFIG.match_candidate_pool

    me_profile = (
        db.collection("users")
        .document(uid)
        .collection("profile")
        .document("main")
        .get()
        .to_dict()
    )
    if not me_profile:
        return []
    my_fm = _frontmatter(db, uid)
    my_community = (me_profile.get("community") or "").strip()

    out: list[dict] = []
    for user_snap in db.collection("users").stream():
        other = user_snap.id
        if other == uid or len(out) >= limit:
            continue
        # Practice-date simulator personas are never real candidates (BUG E).
        if practice_seed.is_practice_persona(other):
            continue
        prof = (
            db.collection("users")
            .document(other)
            .collection("profile")
            .document("main")
            .get()
            .to_dict()
        )
        if not prof:
            continue
        if prof.get("paused") is True:  # "Pause matching" (§14.2)
            continue
        if (prof.get("community") or "").strip() != my_community:
            continue
        if not orientation_match(
            me_profile.get("gender", ""),
            me_profile.get("interested_in", []) or [],
            prof.get("gender", ""),
            prof.get("interested_in", []) or [],
        ):
            continue
        if _blocked(db, uid, other):
            continue
        if _already_matched(db, uid, other):
            # A real Pass-2 score already exists for this pair — don't
            # re-source a heuristic-only candidate entry for it, and clear
            # out any stale one left over from before that score existed (it
            # would otherwise sit there forever: Pass 1 skips writing a fresh
            # one for an already-matched pair, but never used to clean up the
            # old one either).
            clear_stale_candidates(db, uid, other)
            continue

        score, reasons = heuristic_score(
            me_profile, prof, my_fm, _frontmatter(db, other)
        )
        out.append(
            {"candidate_uid": other, "heuristic_score": score, "reasons": reasons}
        )

    out.sort(key=lambda c: c["heuristic_score"], reverse=True)

    col = (
        db.collection("users")
        .document(uid)
        .collection(MATCH_CANDIDATES_COLLECTION)
    )
    for c in out:
        col.document(c["candidate_uid"]).set(
            {
                "heuristic_score": c["heuristic_score"],
                "reasons": c["reasons"],
                "sourced_at": firestore.SERVER_TIMESTAMP,
            }
        )
    return out


# --- Match input freshness -------------------------------------------------
# Shared by the on-demand report path (``main._match_doc_is_stale`` — keyed on
# ``updated_at`` to recompute the *displayed report* on any change) and the
# cron re-score sweep (``score_is_stale`` — keyed on ``scored_at`` to decide
# whether the *score itself* has fallen behind the inputs). Both need the same
# "newest match-relevant input change" signal, so it lives here, importable by
# both ``main`` and ``matching_cron`` without a cycle.


def latest_ts(*values):
    """Return the newest timezone-aware datetime among args, ignoring invalid types."""
    valid = [
        v for v in values
        if v is not None and not isinstance(v, str) and hasattr(v, "isoformat")
    ]
    return max(valid) if valid else None


def match_inputs_mtime(db, uid: str):
    """Newest match-relevant input change for ``uid`` (partner age range,
    location, interested_in, relocation radius, questionnaire answers), so a
    cached or previously-scored match can detect stale inputs."""
    stamps = []
    try:
        doc = db.collection("users").document(uid).collection("profile").document("main").get()
        data = doc.to_dict() if doc else None
        if data and "updated_at" in data:
            stamps.append(data.get("updated_at"))
    except Exception:  # noqa: BLE001
        logger.warning("Failed to fetch profile updated_at for %s", uid, exc_info=True)

    # Late import so a test (or a live config swap) that patches ``config.CONFIG``
    # is honoured — the module-level ``CONFIG`` here is import-time-bound.
    from config import CONFIG as _CONFIG

    if _CONFIG.person_graph_reads:
        # Graph-authoritative: profile-field and questionnaire-answer edits now
        # land on the graph overlay, which stamps `updated_at` on every write.
        # That single stamp captures what the questionnaire-doc scan used to, so
        # a graph-only edit (after the writer swap) still invalidates a cached
        # match. profile/main `updated_at` is still read above for non-tool
        # writes (photos, preboarding).
        try:
            import person_graph_store as _pg_store

            stamps.append(_pg_store.overlay_mtime(db, uid))
        except Exception:  # noqa: BLE001
            logger.warning("Failed to fetch graph overlay mtime for %s", uid, exc_info=True)
    else:
        try:
            for doc in db.collection("users").document(uid).collection("questionnaire").stream():
                data = doc.to_dict()
                if data and "updated_at" in data:
                    stamps.append(data.get("updated_at"))
        except Exception:  # noqa: BLE001
            logger.warning("Failed to fetch questionnaire updated_at for %s", uid, exc_info=True)

    return latest_ts(*stamps)


def score_is_stale(db, d: dict | None, a: str, b: str) -> bool:
    """True when a pair's inputs changed since its score was LAST computed.

    Keyed strictly on ``scored_at`` — the score's own provenance — never on
    ``updated_at``. ``updated_at`` bumps on every write to the pair doc (a
    like, a pass, an accept, a status flip), so a doc whose score is weeks old
    can still carry a recent ``updated_at`` and wrongly look fresh. That is
    exactly why the match cron re-score must not reuse the report-staleness
    check (``main._match_doc_is_stale``, which keys on ``updated_at`` on
    purpose, to recompute the displayed report on any change).

    Conservative: returns False whenever it cannot positively tell (no
    ``scored_at``, or an unreadable stamp), so a fresh pair is never needlessly
    re-scored."""
    try:
        scored_at = d.get("scored_at") if d else None
        if not (hasattr(scored_at, "isoformat") and not isinstance(scored_at, str)):
            return False
        newest_input = latest_ts(match_inputs_mtime(db, a), match_inputs_mtime(db, b))
        return newest_input is not None and newest_input > scored_at
    except Exception:  # noqa: BLE001
        logger.warning("score staleness check failed", exc_info=True)
        return False
