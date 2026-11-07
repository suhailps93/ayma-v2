"""App-control inbox actions: the bulk buttons on the Notifications
page and the Messages list (ACTION PARITY priority gaps, founder
feedback items 9–11, 2026-11-06).

The buttons existed for the user — "Mark all read" and "Clear all" on
the Notifications page, and (added with this work) "Mark all read" on
the conversations list, plus the notification filter chips — but Ayma
had no commands for them, so when the user asked her she was unaware
they existed. Each tool here queues one UI command at
``users/{uid}/app_commands/pending``; the Flutter client
(``AppCommandService`` + ``InboxActions``) runs the same
NotificationService / DmService writes the buttons run and acks with
the count that actually moved.

``clear_all_notifications`` is destructive (the user's own button asks
for confirmation and says it cannot be undone), so its tool
description makes Ayma confirm with the user in conversation before
calling it — the ask-plus-confirm in chat is the check, the same shape
as the tap-side dialog. Split out of ``skills/app_control.py``
following the Tier-2 family layout.
"""

from __future__ import annotations

from typing import Callable

from .app_control_queue import _await_ack, _prompt, _queue_command

# The filter keys the client understands (NotificationFilter in
# inbox_actions.dart). Phrasings the user/model might use map onto
# them; anything else is refused honestly rather than guessed.
_FILTERS = {
    "": "all",
    "all": "all",
    "everything": "all",
    "unread": "unread",
    "unread only": "unread",
    "matches": "matches",
    "new matches": "matches",
    "ayma": "ayma",
    "check-ins": "ayma",
    "checkins": "ayma",
    "check-ins and replies": "ayma",
    "reports": "reports",
    "report": "reports",
    "suggestions": "suggestions",
    "suggestion": "suggestions",
    "profile suggestions": "suggestions",
}

_FILTER_KEYS = ("all", "unread", "matches", "ayma", "reports", "suggestions")


async def _run_inbox_command(db, uid: str, payload: dict, not_done: str) -> str:
    """Queue one inbox command and relay its ack honestly."""
    cmd_id = _queue_command(db, uid, payload)
    # Bulk writes (a batch per notification) can take longer than a
    # navigation's 6s, so these get the inbox timeout.
    from skills import app_control as _facade  # deferred: owns the knobs

    ack = await _await_ack(
        db, uid, cmd_id, timeout=_facade._INBOX_ACK_TIMEOUT_SECONDS
    )
    if not ack:
        return not_done
    if not ack.get("ok"):
        reason = str(ack.get("reason") or "").strip()
        return (
            f"Not done: {reason}" if reason else not_done
        )
    result = str(ack.get("result") or "").strip()
    return result[:500] if result else "Done."


def _bind_mark_all_notifications_read(db, uid: str) -> Callable[..., str]:
    async def mark_all_notifications_read() -> str:
        return await _run_inbox_command(
            db, uid,
            {"action": "mark_all_notifications_read"},
            "The app did NOT mark the notifications read — tell the user "
            "it didn't work and that the button is at the top of the "
            "Notifications page.",
        )

    return mark_all_notifications_read


def _bind_clear_all_notifications(db, uid: str) -> Callable[..., str]:
    async def clear_all_notifications() -> str:
        return await _run_inbox_command(
            db, uid,
            {"action": "clear_all_notifications"},
            "The app did NOT clear the notifications — tell the user it "
            "didn't work and that the button is at the top of the "
            "Notifications page.",
        )

    return clear_all_notifications


def _bind_set_notification_filter(db, uid: str) -> Callable[..., str]:
    async def set_notification_filter(filter: str = "") -> str:
        key = _FILTERS.get(filter.strip().lower())
        if key is None:
            return (
                "There is no notification filter by that name — the "
                "filters are: " + ", ".join(_FILTER_KEYS) + ". Tell the "
                "user which filters exist and ask which one they want."
            )
        return await _run_inbox_command(
            db, uid,
            {"action": "set_notification_filter", "filter": key},
            "The app did NOT change the notification filter — tell the "
            "user it didn't work; the filter chips are at the top of "
            "the Notifications page.",
        )

    return set_notification_filter


def _bind_mark_all_conversations_read(db, uid: str) -> Callable[..., str]:
    async def mark_all_conversations_read() -> str:
        return await _run_inbox_command(
            db, uid,
            {"action": "mark_all_conversations_read"},
            "The app did NOT mark the conversations read — tell the "
            "user it didn't work and that the button is at the top of "
            "the Messages list.",
        )

    return mark_all_conversations_read


_MARK_ALL_NOTIFICATIONS_READ = {
    "name": "mark_all_notifications_read",
    "description": _prompt("app_control_mark_all_notifications_read"),
    "parameters": {"type": "object", "properties": {}},
}

_CLEAR_ALL_NOTIFICATIONS = {
    "name": "clear_all_notifications",
    "description": _prompt("app_control_clear_all_notifications"),
    "parameters": {"type": "object", "properties": {}},
}

_SET_NOTIFICATION_FILTER = {
    "name": "set_notification_filter",
    "description": _prompt("app_control_set_notification_filter"),
    "parameters": {
        "type": "object",
        "properties": {
            "filter": {
                "type": "string",
                "description": (
                    "Which filter to show on the Notifications page: "
                    "'all', 'unread', 'matches', 'ayma' (her check-ins, "
                    "replies and finished tasks), 'reports' or "
                    "'suggestions'."
                ),
            }
        },
        "required": ["filter"],
    },
}

_MARK_ALL_CONVERSATIONS_READ = {
    "name": "mark_all_conversations_read",
    "description": _prompt("app_control_mark_all_conversations_read"),
    "parameters": {"type": "object", "properties": {}},
}
