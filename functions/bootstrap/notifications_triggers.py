"""Concrete notification triggers (ARCHITECTURE.md §7.1, §7.9 steps 4–6).

Thin wrappers over :func:`notifications_dispatch.dispatch` that know each
event's preview text and deep link. All best-effort — a failure here never
affects the request that fired it.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from datetime import datetime, timezone

from config import CONFIG
from notifications_dispatch import dispatch, push_only
from notifications_schema import (
    NOTIF_AYMA_REPLY,
    NOTIF_CHECKIN,
    NOTIF_DM,
    NOTIF_MUTUAL,
    NOTIF_NEW_SCORED,
    NOTIF_SKILL_DONE,
)

logger = logging.getLogger("ayma.notifications")

# Inline report markers the chat renders as cards ("[face_report:<id>]").
_MARKER = re.compile(r"\[[a-z_]+:[\w-]*\]")

_DM_BODY = {
    "photo": "📷 Photo",
    "image": "📷 Photo",
    "voice": "🎙 Voice message",
    "file": "📎 File",
    "shared_profile": "👤 Shared a profile",
    "shared_report": "📄 Shared a report",
}


# Plain push text (no emoji) — the Android notification is a chat bubble.
_DM_PUSH_BODY = {
    "photo": "Photo",
    "image": "Photo",
    "voice": "Voice message",
    "file": "File",
    "shared_profile": "Shared a profile",
    "shared_report": "Shared a report",
}


def _sender_identity(db, uid: str) -> tuple[str, str]:
    """(display name, avatar URL) of ``uid`` for a DM push. Best-effort: any
    failure yields blanks and the client falls back to initials."""
    try:
        from explore import _primary_photo_path
        from public_profile import _photo_url

        prof = (
            db.collection("users").document(uid)
            .collection("profile").document("main").get().to_dict()
        ) or {}
        name = str(prof.get("name") or "").strip()
        path = _primary_photo_path(db, uid, prof.get("photos"))
        return name, ((_photo_url(path) or "") if path else "")
    except Exception:  # noqa: BLE001
        logger.warning("DM push: sender lookup failed for %s", uid,
                       exc_info=True)
        return "", ""


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
        name, photo_url = await asyncio.to_thread(
            _sender_identity, db, sender_uid
        )
        push_body = _DM_PUSH_BODY.get(msg_type) or " ".join(body.split())
        # Push only: DMs surface as the Messages tab's unread badge, never as
        # a Notifications-tab entry.
        await push_only(
            db,
            recipient_uid,
            NOTIF_DM,
            body=_DM_BODY.get(msg_type, body),
            deep_link=f"dm_thread/{thread_id}",
            title=name or "New message",
            push_body=push_body[: CONFIG.push_preview_len],
            push_data={
                "type": "dm",
                "deep_link": f"dm_thread/{thread_id}",
                "thread_id": thread_id,
                "sender_uid": sender_uid,
                "sender_name": name,
                "sender_photo_url": photo_url,
                "msg_type": msg_type,
                "sent_at_ms": int(time.time() * 1000),
            },
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
                actor_uid=other,
            )
        except Exception:  # noqa: BLE001
            logger.exception("mutual-match notification failed for %s", me)


async def notify_checkin(db, uid: str, text: str, deep_link: str = "chat") -> None:
    """Push preview for an Ayma re-engagement message (§7.1, §7.9 step 7)."""
    try:
        await dispatch(db, uid, NOTIF_CHECKIN, body=text, deep_link=deep_link)
    except Exception:  # noqa: BLE001
        logger.exception("check-in notification failed for %s", uid)


async def notify_ayma_reply(db, uid: str, text: str) -> None:
    """Push Ayma's chat reply preview. Sent for every finished turn: the OS
    never displays an FCM notification while the app is in the foreground, so
    a user reading the reply live isn't interrupted, while one who left the
    chat mid-turn (backgrounded, app closed, a message that waited for
    credits) is told it arrived. Tapping opens the Ayma chat. Best-effort."""
    preview = _MARKER.sub("", text).strip()
    try:
        await push_only(
            db, uid, NOTIF_AYMA_REPLY, body=preview, deep_link="chat"
        )
    except Exception:  # noqa: BLE001
        logger.exception("Ayma reply notification failed for %s", uid)


async def notify_skill_done(
    db, uid: str, preview: str, deep_link: str = "chat"
) -> None:
    """Push when a deep dive / match the user asked for finished server-side
    (§ background skills). Best-effort."""
    try:
        await dispatch(
            db, uid, NOTIF_SKILL_DONE,
            fixed_preview=preview, deep_link=deep_link,
        )
    except Exception:  # noqa: BLE001
        logger.exception("skill-done notification failed for %s", uid)


async def notify_new_scored_matches(
    db, uid: str, count: int, *, match_id: str = "", other_uid: str = "",
) -> None:
    """One digest push per cron run for a user, only if it produced matches.

    When exactly one new match was scored, the push deep-links straight to
    that match's request screen (`match_request/{id}`) rather than the list
    — the common case, and what lets a tap open the request directly instead
    of just landing on "New from Ayma" for one more tap. With more than one,
    there's no single match to jump to, so it deep-links to the list as
    before.
    """
    if count <= 0:
        return
    plural = "es" if count > 1 else ""
    deep_link = (
        f"match_request/{match_id}" if count == 1 and match_id else "matches"
    )
    try:
        await dispatch(
            db,
            uid,
            NOTIF_NEW_SCORED,
            fixed_preview=f"Ayma found {count} new match{plural} for you.",
            deep_link=deep_link,
            actor_uid=other_uid if count == 1 else "",
        )
    except Exception:  # noqa: BLE001
        logger.exception("cron-digest notification failed for %s", uid)
