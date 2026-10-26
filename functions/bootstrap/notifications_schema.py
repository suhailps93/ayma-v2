"""Notification schema constants (ARCHITECTURE.md §7.3, §7.7, §7.8, §7.9 step 1).

Three shapes:

* ``fcm_tokens`` — an array of device-token strings on ``users/{uid}``.
* ``users/{uid}/notifications/{id}`` — the durable notification-center record,
  written for every push (and for muted-category events, nothing is written).
* ``users/{uid}/notification_prefs`` — one bool per category, default ``True``.
"""

from __future__ import annotations

NOTIF_DM = "dm_message"
NOTIF_MUTUAL = "mutual_match"
NOTIF_NEW_SCORED = "new_scored_match"
NOTIF_CHECKIN = "ayma_checkin"
# A skill the user asked for (deep dive / match) finished server-side while the
# app was backgrounded or closed.
NOTIF_SKILL_DONE = "skill_result"
# Ayma's reply to a chat message finished while the user was away from the
# chat (app backgrounded/closed, or a message that waited for credits). Push
# only — the reply itself is the durable record, so no centre entry is written.
NOTIF_AYMA_REPLY = "ayma_reply"
# Ayma has proposed one or more new updates to the user's PUBLIC profile that
# are waiting to be reviewed (applied or dismissed). Deep-links to the review
# screen; deduped so the user isn't re-pinged for an unchanged pending set.
NOTIF_PROFILE_SUGGESTIONS = "profile_suggestions"

NOTIFICATION_TYPES: tuple[str, ...] = (
    NOTIF_DM,
    NOTIF_MUTUAL,
    NOTIF_NEW_SCORED,
    NOTIF_CHECKIN,
    NOTIF_SKILL_DONE,
    NOTIF_AYMA_REPLY,
    NOTIF_PROFILE_SUGGESTIONS,
)

NOTIFICATIONS_COLLECTION = "notifications"
NOTIFICATION_PREFS_DOC = "notification_prefs"
FCM_TOKENS_FIELD = "fcm_tokens"

# The last time a push actually went out to a user — a top-level field on
# ``users/{uid}`` the dispatch helper (Step 55) reads for the §7.5 cooldown.
LAST_PUSH_AT_FIELD = "last_push_at"


def default_prefs() -> dict[str, bool]:
    """All categories on — the §7.7 default."""
    return {t: True for t in NOTIFICATION_TYPES}


def is_valid_type(value: str) -> bool:
    return value in NOTIFICATION_TYPES
