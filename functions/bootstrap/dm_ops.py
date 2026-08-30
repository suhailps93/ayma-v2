"""Direct-message thread + message writes (ARCHITECTURE.md §6.6, §6.7, §6.8,
§6.11 steps 8–10).
"""

from __future__ import annotations

import logging

from firebase_admin import firestore

from dm_schema import (
    DM_MESSAGES_COLLECTION,
    DM_THREADS_COLLECTION,
    MESSAGE_TYPES,
    thread_id,
)
from matching_schema import block_id

logger = logging.getLogger("ayma.dm")


def blocked_between(db, uid_a: str, uid_b: str) -> bool:
    blocks = db.collection("blocks")
    return (
        blocks.document(block_id(uid_a, uid_b)).get().exists
        or blocks.document(block_id(uid_b, uid_a)).get().exists
    )


def ensure_thread(db, uid_a: str, uid_b: str) -> str:
    tid = thread_id(uid_a, uid_b)
    ref = db.collection(DM_THREADS_COLLECTION).document(tid)
    if not ref.get().exists:
        lo, hi = sorted((uid_a, uid_b))
        ref.set(
            {
                "participants": [lo, hi],
                "created_at": firestore.SERVER_TIMESTAMP,
                "last_message_at": firestore.SERVER_TIMESTAMP,
                "last_read_at": {},
            }
        )
    return tid


def post_message(
    db, sender_uid: str, thread_with: str, msg_type: str, body: str
) -> str:
    """Append a message to the pair's thread. Returns the message id. Raises on
    a bad type or when the pair has a block between them."""
    if msg_type not in MESSAGE_TYPES:
        raise ValueError(f"bad message type: {msg_type}")
    if blocked_between(db, sender_uid, thread_with):
        raise PermissionError("blocked")

    tid = ensure_thread(db, sender_uid, thread_with)
    thread_ref = db.collection(DM_THREADS_COLLECTION).document(tid)
    msg_ref = thread_ref.collection(DM_MESSAGES_COLLECTION).document()
    msg_ref.set(
        {
            "sender_uid": sender_uid,
            "type": msg_type,
            "body": body,
            "created_at": firestore.SERVER_TIMESTAMP,
        }
    )
    thread_ref.set(
        {"last_message_at": firestore.SERVER_TIMESTAMP}, merge=True
    )
    return msg_ref.id
