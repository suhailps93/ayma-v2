"""Concrete notification triggers (ARCHITECTURE.md §7.1, §7.9 steps 4–6).

Thin wrappers over :func:`notifications_dispatch.dispatch` that know each
event's preview text and deep link. All best-effort — a failure here never
affects the request that fired it.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from config import CONFIG
from notifications_dispatch import dispatch
from notifications_schema import NOTIF_DM, NOTIF_MUTUAL, NOTIF_NEW_SCORED

logger = logging.getLogger("ayma.notifications")

_DM_BODY = {
    "photo": "📷 Photo",
    "voice": "🎙 Voice message",
    "shared_profile": "👤 Shared a profile",
}


def _viewing_thread(db, thread_id: str, uid: str) -> bool:
    """True if ``uid``'s read cursor on the thread is within the §7.1 viewing
    window — they're looking at it, so no push."""
    try:
        snap = db.collection("dm_threads").document(thread_id).get()
    except Exception:  # noqa: BLE001
        return False
    last = (snap.to_dict() or {}).get("last_read_at", {}) if snap.exists else {}
    ts = last.get(uid) if isinstance(last, dict) else None
    if not isinstance(ts, datetime):
        return False
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    age = (datetime.now(timezone.utc) - ts).total_seconds()
    return 0 <= age < CONFIG.dm_viewing_window_seconds


async def notify_new_dm(
    db, thread_id: str, sender_uid: str, recipient_uid: str,
    msg_type: str, body: str,
) -> None:
    if _viewing_thread(db, thread_id, recipient_uid):
        return
    try:
        await dispatch(
            db,
            recipient_uid,
            NOTIF_DM,
            body=_DM_BODY.get(msg_type, body),
            deep_link=f"dm_thread/{thread_id}",
        )
    except Exception:  # noqa: BLE001
        logger.exception("DM notification failed for %s", recipient_uid)


async def notify_mutual_match(db, uid_a: str, uid_b: str) -> None:
    for me, other in ((uid_a, uid_b), (uid_b, uid_a)):
        try:
            await dispatch(
                db,
                me,
                NOTIF_MUTUAL,
                fixed_preview="You have a new match on Ayma.",
                deep_link=f"profile/{other}",
            )
        except Exception:  # noqa: BLE001
            logger.exception("mutual-match notification failed for %s", me)


async def notify_new_scored_matches(db, uid: str, count: int) -> None:
    """One digest push per cron run for a user, only if it produced matches."""
    if count <= 0:
        return
    plural = "es" if count > 1 else ""
    try:
        await dispatch(
            db,
            uid,
            NOTIF_NEW_SCORED,
            fixed_preview=f"Ayma found {count} new match{plural} for you.",
            deep_link="matches",
        )
    except Exception:  # noqa: BLE001
        logger.exception("cron-digest notification failed for %s", uid)
