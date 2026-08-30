"""FCM token + notification-preference writes (ARCHITECTURE.md §7.2, §7.7,
§7.9 steps 1–2). Dispatch (writing ``notifications`` docs + sending the push)
is Step 55.
"""

from __future__ import annotations

import logging

from firebase_admin import firestore

from config import CONFIG
from notifications_schema import (
    FCM_TOKENS_FIELD,
    NOTIFICATION_PREFS_DOC,
    default_prefs,
    is_valid_type,
)

logger = logging.getLogger("ayma.notifications")


def register_token(db, uid: str, token: str) -> None:
    """Add ``token`` to ``users/{uid}.fcm_tokens`` (idempotent via ArrayUnion).

    If the array would exceed ``CONFIG.max_fcm_tokens`` it is trimmed to the
    most recent entries — oldest tokens (likely stale devices) drop off first.
    """
    token = token.strip()
    if not token:
        raise ValueError("empty FCM token")
    ref = db.collection("users").document(uid)
    ref.set({FCM_TOKENS_FIELD: firestore.ArrayUnion([token])}, merge=True)

    snap = ref.get()
    tokens = (snap.to_dict() or {}).get(FCM_TOKENS_FIELD) or []
    if len(tokens) > CONFIG.max_fcm_tokens:
        # Keep this token plus the newest others.
        trimmed = [t for t in tokens if t != token][-(CONFIG.max_fcm_tokens - 1):]
        trimmed.append(token)
        ref.set({FCM_TOKENS_FIELD: trimmed}, merge=True)


def unregister_token(db, uid: str, token: str) -> None:
    """Remove ``token`` from ``users/{uid}.fcm_tokens`` (sign-out / refresh)."""
    token = token.strip()
    if not token:
        return
    db.collection("users").document(uid).set(
        {FCM_TOKENS_FIELD: firestore.ArrayRemove([token])}, merge=True
    )


def read_prefs(db, uid: str) -> dict[str, bool]:
    """Return the user's category prefs, filling defaults for missing keys."""
    snap = (
        db.collection("users")
        .document(uid)
        .collection(NOTIFICATION_PREFS_DOC)
        .document("main")
        .get()
    )
    stored = (snap.to_dict() or {}) if snap.exists else {}
    prefs = default_prefs()
    for key, value in stored.items():
        if key in prefs and isinstance(value, bool):
            prefs[key] = value
    return prefs


def set_pref(db, uid: str, category: str, enabled: bool) -> dict[str, bool]:
    """Toggle one category; returns the full resolved prefs (§7.9 step 9)."""
    if not is_valid_type(category):
        raise ValueError(f"unknown notification category: {category}")
    (
        db.collection("users")
        .document(uid)
        .collection(NOTIFICATION_PREFS_DOC)
        .document("main")
        .set({category: bool(enabled)}, merge=True)
    )
    return read_prefs(db, uid)
