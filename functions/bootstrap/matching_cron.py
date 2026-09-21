"""Scheduled matching pipeline (ARCHITECTURE.md §5.3, §5.10 step 7).

Daily Cloud Scheduler. For each user (capped at ``CRON_CANDIDATE_POOL``) it
runs Pass 1, then Pass 2 on the top ``CRON_SCORE_TOP_K`` candidates, upserting
``matches/{matchId}`` — so users get some scored matches without triggering
anything themselves.
"""

from __future__ import annotations

import logging

from firebase_admin import firestore

import matching
import matching_skill
from config import CONFIG
from matching_schema import MATCH_STATUS_SCORED
from notifications_triggers import notify_new_scored_matches
from pair_key import sorted_pair_key

logger = logging.getLogger("ayma.matching")


async def run(db, user_limit: int | None = None) -> dict:
    user_limit = user_limit or CONFIG.cron_candidate_pool
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
                continue  # don't re-score on the cron
            try:
                result = await matching_skill.score_pair(
                    db, uid, other, charge_uid=uid
                )
            except Exception:  # noqa: BLE001 - missing wiki etc.
                continue
            lo, hi = sorted((uid, other))
            ref.set(
                {
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
                    "status": MATCH_STATUS_SCORED,
                    "scored_at": firestore.SERVER_TIMESTAMP,
                    "updated_at": firestore.SERVER_TIMESTAMP,
                }
            )
            matches_written += 1
            new_for_user += 1
            last_match_id = match_id
            last_other_uid = other

        # One digest push per cron run for this user (§7.1, §7.9 step 6).
        await notify_new_scored_matches(
            db, uid, new_for_user,
            match_id=last_match_id, other_uid=last_other_uid,
        )

    return {"users_checked": checked, "matches_written": matches_written}
