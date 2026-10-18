"""Notification dispatch (ARCHITECTURE.md §7.1, §7.3–7.5, §7.9 step 3).

One shared entry point, [dispatch], used by every trigger (DM message, mutual
match, cron digest, Ayma check-in). It:

1. checks ``notification_prefs`` — a muted category writes **nothing** (§7.7);
2. writes the durable ``users/{uid}/notifications/{id}`` centre doc (§7.3);
3. enforces the §7.5 cooldown — at most one *push* per user per
   ``CONFIG.push_cooldown_seconds`` (the centre doc is always written);
4. sends the FCM push to every registered device token, pruning tokens FCM
   reports as dead.

Never raises for a delivery problem — push is a nudge, not a guarantee.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from firebase_admin import firestore, messaging

from config import CONFIG
from notifications_ops import read_prefs
from notifications_schema import (
    FCM_TOKENS_FIELD,
    LAST_PUSH_AT_FIELD,
    NOTIFICATIONS_COLLECTION,
    is_valid_type,
)

logger = logging.getLogger("ayma.notifications")


def _preview(body: str, fixed: str | None) -> str:
    if fixed:
        return fixed
    text = " ".join((body or "").split())
    if len(text) <= CONFIG.push_preview_len:
        return text
    return text[: CONFIG.push_preview_len - 1].rstrip() + "…"


def _in_cooldown(last, now: datetime) -> bool:
    if not isinstance(last, datetime):
        return False
    if last.tzinfo is None:
        last = last.replace(tzinfo=timezone.utc)
    return (now - last) < timedelta(seconds=CONFIG.push_cooldown_seconds)


def _deliver(tokens: list[str], title: str, body: str, deep_link: str):
    """Send one multicast push. Split out so tests patch here, not the SDK."""
    msg = messaging.MulticastMessage(
        tokens=tokens,
        notification=messaging.Notification(title=title, body=body),
        data={"deep_link": deep_link} if deep_link else {},
        # High priority so a closed/idle device is woken promptly (Android
        # otherwise batches normal-priority pushes in Doze); the APNs
        # equivalent is priority 10 + an audible alert.
        android=messaging.AndroidConfig(priority="high"),
        apns=messaging.APNSConfig(
            headers={"apns-priority": "10"},
            payload=messaging.APNSPayload(aps=messaging.Aps(sound="default")),
        ),
    )
    return messaging.send_each_for_multicast(msg)


def _dead_token(exc: Exception | None) -> bool:
    return isinstance(
        exc, (messaging.UnregisteredError, messaging.SenderIdMismatchError)
    )


def _push(db, uid: str, user_ref, tokens: list[str], title: str,
          body: str, deep_link: str) -> bool:
    try:
        resp = _deliver(tokens, title, body, deep_link)
    except Exception:  # noqa: BLE001
        logger.exception("FCM multicast failed for %s", uid)
        return False

    dead: list[str] = []
    success = 0
    for token, r in zip(tokens, getattr(resp, "responses", []) or []):
        if getattr(r, "success", False):
            success += 1
        elif _dead_token(getattr(r, "exception", None)):
            dead.append(token)
    if dead:
        user_ref.set(
            {FCM_TOKENS_FIELD: firestore.ArrayRemove(dead)}, merge=True
        )
    return success > 0


async def push_only(
    db,
    uid: str,
    type_: str,
    *,
    body: str,
    deep_link: str = "",
    title: str = "Ayma",
) -> dict:
    """Push without a notification-centre entry and outside the §7.5 cooldown.

    For events whose content already lives in the app (an Ayma chat reply): the
    user waiting on that reply must get it even right after another push, and
    a centre row per chat turn would only be noise. Still honours the
    category's mute pref and prunes dead tokens. Never touches
    ``last_push_at``, so it doesn't delay the digest-style pushes.
    """
    if not is_valid_type(type_):
        raise ValueError(f"unknown notification type: {type_}")
    if not read_prefs(db, uid).get(type_, True):
        return {"muted": True, "pushed": False}
    user_ref = db.collection("users").document(uid)
    data = user_ref.get().to_dict() or {}
    tokens = [
        t for t in (data.get(FCM_TOKENS_FIELD) or []) if isinstance(t, str) and t
    ]
    if not tokens:
        return {"muted": False, "pushed": False, "no_tokens": True}
    pushed = _push(
        db, uid, user_ref, tokens, title, _preview(body, None), deep_link
    )
    return {"muted": False, "pushed": pushed}


async def dispatch(
    db,
    uid: str,
    type_: str,
    *,
    body: str = "",
    deep_link: str = "",
    fixed_preview: str | None = None,
    title: str = "Ayma",
    actor_uid: str = "",
) -> dict:
    """Run the pipeline for one (user, event). Returns a small status dict
    (``muted`` / ``doc`` / ``pushed`` / ``cooldown`` / ``no_tokens``).

    ``actor_uid`` — the other person the notification is about (the DM sender,
    the matched user). The notification centre groups by it and shows their
    face + name.
    """
    if not is_valid_type(type_):
        raise ValueError(f"unknown notification type: {type_}")

    if not read_prefs(db, uid).get(type_, True):
        return {"muted": True, "doc": False, "pushed": False}

    preview = _preview(body, fixed_preview)
    record: dict = {
        "type": type_,
        "body": preview,
        "deep_link": deep_link,
        "created_at": firestore.SERVER_TIMESTAMP,
        "read": False,
    }
    if actor_uid:
        record["actor_uid"] = actor_uid
    db.collection("users").document(uid).collection(
        NOTIFICATIONS_COLLECTION
    ).document().set(record)

    user_ref = db.collection("users").document(uid)
    data = user_ref.get().to_dict() or {}
    now = datetime.now(timezone.utc)
    if _in_cooldown(data.get(LAST_PUSH_AT_FIELD), now):
        return {"muted": False, "doc": True, "pushed": False, "cooldown": True}

    tokens = [
        t for t in (data.get(FCM_TOKENS_FIELD) or []) if isinstance(t, str) and t
    ]
    if not tokens:
        return {"muted": False, "doc": True, "pushed": False, "no_tokens": True}

    pushed = _push(db, uid, user_ref, tokens, title, preview, deep_link)
    if pushed:
        user_ref.set(
            {LAST_PUSH_AT_FIELD: firestore.SERVER_TIMESTAMP}, merge=True
        )
    return {"muted": False, "doc": True, "pushed": pushed}
