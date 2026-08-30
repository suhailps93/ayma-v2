"""Sorted-pair document keys (ARCHITECTURE.md §9.4, §5.9, §6.10).

``matches/{matchId}`` is one doc shared by both users, keyed by the two uids in
sorted order; ``dm_threads`` (Piece 6) is keyed the same way. Firebase Auth uids
are alphanumeric with no separator, so a plain delimiter join is unambiguous.
"""

from __future__ import annotations

_SEP = "__"


def sorted_pair_key(uid_a: str, uid_b: str) -> str:
    """A stable id for the unordered pair ``{uid_a, uid_b}`` — the same for
    ``(a, b)`` and ``(b, a)``."""
    a, b = uid_a.strip(), uid_b.strip()
    if not a or not b:
        raise ValueError("both uids are required")
    if a == b:
        raise ValueError("a pair needs two different uids")
    lo, hi = sorted((a, b))
    return f"{lo}{_SEP}{hi}"


def uids_from_pair_key(key: str) -> tuple[str, str]:
    lo, _, hi = key.partition(_SEP)
    if not lo or not hi:
        raise ValueError(f"not a pair key: {key!r}")
    return lo, hi
