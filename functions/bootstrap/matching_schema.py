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
