"""Account soft-delete and recovery (ARCHITECTURE.md §3.6, §3.10 steps 8–9).

``soft_delete`` copies the whole ``users/{uid}`` Firestore subtree plus the
user's ``uploads/{uid}/*`` Storage objects into a ``deleted_accounts/{uid}``
quarantine with a ``deleted_at`` stamp, then removes the live copies. The
Firebase Auth account is left intact so the person can still sign in and see the
recovery screen. ``recover`` reverses it. The 30-day permanent purge is Step 37.
"""

from __future__ import annotations

import logging

from firebase_admin import firestore

logger = logging.getLogger("ayma.account")

# The subcollections under users/{uid} that make up an account (§3.6).
_SUBCOLLECTIONS = (
    "profile",
    "wiki_pages",
    "raw_turns",
    "pending_questions",
    "user_media",
)

_STORAGE_PREFIX = "uploads/{uid}/"
_QUARANTINE_STORAGE_PREFIX = "deleted_accounts/{uid}/"


def _copy_subtree(db, src_doc, dst_doc) -> None:
    src_snap = src_doc.get()
    dst_doc.set(src_snap.to_dict() or {})
    for name in _SUBCOLLECTIONS:
        for child in src_doc.collection(name).stream():
            dst_doc.collection(name).document(child.id).set(
                child.to_dict() or {}
            )


def _delete_subtree(db, doc) -> None:
    for name in _SUBCOLLECTIONS:
        for child in doc.collection(name).stream():
            child.reference.delete()
    doc.delete()


def _move_storage(bucket, src_prefix: str, dst_prefix: str) -> int:
    moved = 0
    for blob in list(bucket.list_blobs(prefix=src_prefix)):
        rel = blob.name[len(src_prefix):]
        bucket.copy_blob(blob, bucket, dst_prefix + rel)
        blob.delete()
        moved += 1
    return moved


def is_recovery_required(db, uid: str) -> bool:
    """A ``deleted_accounts/{uid}`` quarantine exists with no live account."""
    quarantined = db.collection("deleted_accounts").document(uid).get().exists
    live = db.collection("users").document(uid).get().exists
    return quarantined and not live


def soft_delete(db, bucket, uid: str) -> dict:
    src = db.collection("users").document(uid)
    if not src.get().exists:
        return {"deleted": False, "reason": "no live account"}

    dst = db.collection("deleted_accounts").document(uid)
    _copy_subtree(db, src, dst)
    dst.set(
        {"deleted_at": firestore.SERVER_TIMESTAMP, "original_uid": uid},
        merge=True,
    )

    files = 0
    if bucket is not None:
        files = _move_storage(
            bucket,
            _STORAGE_PREFIX.format(uid=uid),
            _QUARANTINE_STORAGE_PREFIX.format(uid=uid),
        )

    _delete_subtree(db, src)
    return {"deleted": True, "files_moved": files}


def recover(db, bucket, uid: str) -> dict:
    src = db.collection("deleted_accounts").document(uid)
    if not src.get().exists:
        return {"restored": False, "reason": "nothing to recover"}

    dst = db.collection("users").document(uid)
    _copy_subtree(db, src, dst)
    # strip the quarantine bookkeeping from the restored account doc
    dst.update(
        {
            "deleted_at": firestore.DELETE_FIELD,
            "original_uid": firestore.DELETE_FIELD,
        }
    )

    files = 0
    if bucket is not None:
        files = _move_storage(
            bucket,
            _QUARANTINE_STORAGE_PREFIX.format(uid=uid),
            _STORAGE_PREFIX.format(uid=uid),
        )

    _delete_subtree(db, src)
    return {"restored": True, "files_moved": files}
