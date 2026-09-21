"""Matching-engine shape constants (ARCHITECTURE.md §5.9, §5.10 step 1).

Firestore enforces nothing; these are the names the matching code shares.
Behaviour is added in Steps 40–44.
"""

from __future__ import annotations

# matches/{matchId}.status lifecycle (§5.7)
MATCH_STATUS_SCORED = "scored"
MATCH_STATUS_MUTUAL = "mutual_interest"
MATCH_STATUS_UNMATCHED = "unmatched"
MATCH_STATUS_BLOCKED = "blocked"
MATCH_STATUSES = (
    MATCH_STATUS_SCORED,
    MATCH_STATUS_MUTUAL,
    MATCH_STATUS_UNMATCHED,
    MATCH_STATUS_BLOCKED,
)

# users/{uid}.trust_flags[].type (§5.5)
TRUST_FLAG_SELF_CONTRADICTION = "self_contradiction"
TRUST_FLAG_FACE_MISMATCH = "face_mismatch"
TRUST_FLAG_TYPES = (TRUST_FLAG_SELF_CONTRADICTION, TRUST_FLAG_FACE_MISMATCH)

MATCH_CANDIDATES_COLLECTION = "match_candidates"  # under users/{uid}
MATCHES_COLLECTION = "matches"  # top-level
BLOCKS_COLLECTION = "blocks"  # top-level, id = "{uid}_{blockedUid}"


def block_id(blocker_uid: str, blocked_uid: str) -> str:
    return f"{blocker_uid}_{blocked_uid}"


def clear_stale_candidates(db, uid_a: str, uid_b: str) -> None:
    """Delete any Pass-1 ``match_candidates`` entry either side has for the
    other, now that a real Pass-2 ``matches`` doc exists for the pair.

    ``matches/{pairKey}`` is the sole source of truth for a scored pair from
    here on — Explore's card-score lookup (``explore._score_for``) already
    prefers it over ``match_candidates`` — but a stale candidate doc left
    behind from an earlier Pass-1 run is dead, confusing data: a duplicate,
    lower-fidelity record of the exact same pair that any other/future reader
    could still pick up instead of the real score. Called once a pair is
    scored (``main._match_job``, ``matching_cron.run``) and defensively from
    Pass 1 itself when it notices the pair is already scored
    (``matching.source_and_score``). Best-effort: deleting a doc that was
    never there is a silent no-op, never an error.
    """
    cands = db.collection("users")
    cands.document(uid_a).collection(MATCH_CANDIDATES_COLLECTION).document(
        uid_b
    ).delete()
    cands.document(uid_b).collection(MATCH_CANDIDATES_COLLECTION).document(
        uid_a
    ).delete()
