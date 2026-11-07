"""App-control notification filter (founder feedback item 11,
2026-11-06; staging port 2026-11-07, ordered with the self-check).

The Notifications page filter chips and Ayma share one state (the
client's ``NotificationFilterState``): this tool queues one
``set_notification_filter`` UI command at
``users/{uid}/app_commands/pending``; the Flutter client
(``AppCommandService``) writes the shared filter state, navigates to
the Notifications page, and acks with the line naming the filter it
replaced. That ack line is also how the self-check learns (and then
restores) the user's own filter, which lives only in the client.

The bulk inbox actions (mark-all-read / clear-all /
mark-all-conversations-read) stay v2-only; only the filter was
ordered into staging. Split out of ``skills/app_control.py``
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
    # The filter write + navigation can take longer than a plain
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
