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

from config import CONFIG
from matching_schema import MATCH_CANDIDATES_COLLECTION, block_id
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
        if _blocked(db, uid, other) or _already_matched(db, uid, other):
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
