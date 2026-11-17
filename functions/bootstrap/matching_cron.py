"""Scheduled matching pipeline (ARCHITECTURE.md §5.3, §5.10 step 7).

Daily Cloud Scheduler. For each user (capped at ``CRON_CANDIDATE_POOL``) it
runs Pass 1, then Pass 2 on the top ``CRON_SCORE_TOP_K`` candidates, upserting
``matches/{matchId}`` — so users get some scored matches without triggering
anything themselves. It then runs a bounded re-score sweep over EXISTING pairs
whose inputs changed since they were last scored, so a stored match never
drifts weeks stale once both parties keep editing (NOTE 244).
"""

from __future__ import annotations

import logging

from firebase_admin import firestore

import matching
import matching_skill
from config import CONFIG
from matching_schema import MATCH_STATUS_SCORED, clear_stale_candidates
from notifications_triggers import notify_new_scored_matches
from pair_key import sorted_pair_key

logger = logging.getLogger("ayma.matching")

# How many ``matches`` docs the re-score sweep will read in one run. The
# inference spend is bounded by ``CONFIG.cron_rescore_budget``; this separately
# bounds the Firestore reads so a run never scans the whole collection even
# when nothing is stale.
_RESCORE_SCAN_CAP = 1000


def _score_fields(lo: str, hi: str, result: dict) -> dict:
    """The stored match-score fields common to a first score and a re-score
    (everything except ``status`` and the ``scored_at``/``updated_at`` stamps,
    which the caller adds so each path controls them)."""
    return {
        "uids": [lo, hi],
        "score": result["score"],
        "structured_score": result.get("structured_score"),
        "dimensions": result.get("dimensions") or [],
        "omitted_dimensions": result.get("omitted_dimensions") or [],
        "user_explanation": result["user_explanation"],
        "ai_explanation": result["ai_explanation"],
        "shared": result.get("shared") or [],
        "tensions": result.get("tensions") or [],
        "missing": result.get("missing") or [],
        "gate_failures": result.get("gate_failures") or [],
        "score_confidence": result.get("score_confidence"),
        "confidence_note": result.get("confidence_note") or "",
        "method": result.get("method") or "",
        "trust_flags": result["trust_flags"],
    }


async def _rescore_stale_pairs(db, budget: int) -> int:
    """Bounded daily re-score of EXISTING pairs whose inputs changed since they
    were last scored. Pass 1 excludes already-matched pairs from sourcing, so
    without this sweep a stored match is never re-scored and its ``scored_at``
    freezes at the first-ever score (NOTE 244 — the founder's top pair sat 18
    days stale across a move + story edits + the graph switch).

    Re-scores at most ``budget`` pairs per run (``score_pair`` charges
    inference) and reads at most ``_RESCORE_SCAN_CAP`` docs, so the sweep is
    always bounded — never an unbounded re-score across all users. ``budget``
    of ``0`` disables it. Staleness is keyed on ``scored_at`` via
    ``matching.score_is_stale`` (NOT ``updated_at``, which bumps on
    likes/passes/accepts and would mask a stale score). The re-score write
    merges, so a pair's ``status``/``accepted_by`` survive untouched.
    """
    if budget <= 0:
        return 0
    rescored = 0
    for snap in db.collection("matches").limit(_RESCORE_SCAN_CAP).stream():
        if rescored >= budget:
            break
        data = snap.to_dict() or {}
        uids = data.get("uids") or []
        if len(uids) != 2:
            continue
        a, b = uids[0], uids[1]
        if not matching.score_is_stale(db, data, a, b):
            continue
        try:
            result = await matching_skill.score_pair(db, a, b, charge_uid=a)
        except Exception:  # noqa: BLE001 - missing wiki etc.; never break the sweep
            logger.exception("cron re-score failed for %s x %s", a, b)
            continue
        lo, hi = sorted((a, b))
        db.collection("matches").document(snap.id).set(
            {
                **_score_fields(lo, hi, result),
                "scored_at": firestore.SERVER_TIMESTAMP,
                "updated_at": firestore.SERVER_TIMESTAMP,
            },
            merge=True,  # keep status / accepted_by on the existing pair
        )
        rescored += 1
    return rescored


async def run(
    db, user_limit: int | None = None, rescore_budget: int | None = None
) -> dict:
    user_limit = user_limit or CONFIG.cron_candidate_pool
    if rescore_budget is None:
        rescore_budget = CONFIG.cron_rescore_budget
    checked = matches_written = 0

    users = [s.id for s in db.collection("users").limit(user_limit).stream()]
    for uid in users:
        checked += 1
        try:
            candidates = matching.source_and_score(
                db, uid, CONFIG.cron_candidate_pool
            )
        except Exception:  # noqa: BLE001
            logger.exception("cron Pass 1 failed for %s", uid)
            continue

        new_for_user = 0
        last_match_id = ""
        last_other_uid = ""
        for cand in candidates[: CONFIG.cron_score_top_k]:
            other = cand["candidate_uid"]
            match_id = sorted_pair_key(uid, other)
            ref = db.collection("matches").document(match_id)
            if ref.get().exists:
                # Pass 1 already excludes already-matched pairs, so this is a
                # belt-and-suspenders guard; refreshing an existing pair is the
                # re-score sweep's job (``_rescore_stale_pairs``), not this
                # first-score loop.
                continue
            try:
                result = await matching_skill.score_pair(
                    db, uid, other, charge_uid=uid
                )
            except Exception:  # noqa: BLE001 - missing wiki etc.
                continue
            lo, hi = sorted((uid, other))
            ref.set(
                {
                    **_score_fields(lo, hi, result),
                    "status": MATCH_STATUS_SCORED,
                    "scored_at": firestore.SERVER_TIMESTAMP,
                    "updated_at": firestore.SERVER_TIMESTAMP,
                }
            )
            matches_written += 1
            new_for_user += 1
            last_match_id = match_id
            last_other_uid = other
            # Same cleanup as the on-demand path (main._match_job): a real
            # score now exists for this pair, so any stale Pass-1 candidate
            # entry either side has for the other is dead data — never used
            # to get cleared here, so Explore could still be reading it.
            try:
                clear_stale_candidates(db, uid, other)
            except Exception:  # noqa: BLE001 - never break the cron run
                logger.exception(
                    "cron: stale candidate cleanup failed for %s x %s",
                    uid, other,
                )

        # One digest push per cron run for this user (§7.1, §7.9 step 6).
        await notify_new_scored_matches(
            db, uid, new_for_user,
            match_id=last_match_id, other_uid=last_other_uid,
        )

    # Bounded re-score of existing pairs whose inputs drifted (NOTE 244).
    rescored = await _rescore_stale_pairs(db, rescore_budget)

    return {
        "users_checked": checked,
        "matches_written": matches_written,
        "pairs_rescored": rescored,
    }
