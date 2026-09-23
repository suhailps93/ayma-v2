"""Finalize soft-deleted accounts past the recovery window (ARCHITECTURE.md
§3.6, §3.10 step 10; founder request 2026-09-20: keep the data, only sever
login).

A daily Cloud Scheduler job hits ``POST /cron/purge-deleted``. For every
``deleted_accounts/{uid}`` whose ``deleted_at`` is older than
``CONFIG.account_recovery_days``, this:

1. Moves the whole quarantine Firestore subtree — ``schema.
   ACCOUNT_SUBCOLLECTIONS`` plus ``account_ops.ARCHIVE_EXTRA_SUBCOLLECTIONS``
   (identity_mappings, matches_snapshot, dm_threads_snapshot, blocks,
   feedback, product_feedback, bug_reports) — into ``archived_accounts/{uid}``.
2. Moves (not deletes) the quarantined Storage objects from
   ``deleted_accounts/{uid}/*`` to ``archived_accounts/{uid}/*``.
3. Deletes the now-empty ``deleted_accounts/{uid}`` quarantine doc/subtree.
4. Deletes the Firebase Auth account — *this* is what finally makes the
   user's old login stop working for good (during the quarantine window it
   still worked, on purpose, to support self-service recovery).

Nothing is destroyed. ``archived_accounts/{uid}`` is retained indefinitely
and is reachable only through ``admin_lookup.py`` (admin-only, same
``require_admin_password`` gate as the rest of ``/admin/*``) — see that
module and ``schema.ARCHIVED_ACCOUNTS``'s docstring.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from firebase_admin import auth as firebase_auth
from firebase_admin import firestore

import schema
from account_ops import (
    ARCHIVE_EXTRA_NESTED,
    ARCHIVE_EXTRA_SUBCOLLECTIONS,
    _copy_named_subtree,
    _delete_named_subtree,
)
from config import CONFIG

logger = logging.getLogger("ayma.account")

_QUARANTINE_STORAGE_PREFIX = "deleted_accounts/{uid}/"
_ARCHIVE_STORAGE_PREFIX = "archived_accounts/{uid}/"


def _move_to_permanent_archive(db, uid: str) -> None:
    src = db.collection(schema.DELETED_ACCOUNTS).document(uid)
    dst = db.collection(schema.ARCHIVED_ACCOUNTS).document(uid)

    src_snap = src.get()
    dst.set(src_snap.to_dict() or {})
    dst.set({"archived_at": firestore.SERVER_TIMESTAMP}, merge=True)
    _copy_named_subtree(
        src, dst, schema.ACCOUNT_SUBCOLLECTIONS, schema.NESTED_SUBCOLLECTIONS
    )
    _copy_named_subtree(src, dst, ARCHIVE_EXTRA_SUBCOLLECTIONS, ARCHIVE_EXTRA_NESTED)

    _delete_named_subtree(
        src, schema.ACCOUNT_SUBCOLLECTIONS, schema.NESTED_SUBCOLLECTIONS
    )
    _delete_named_subtree(src, ARCHIVE_EXTRA_SUBCOLLECTIONS, ARCHIVE_EXTRA_NESTED)
    src.delete()


def _move_storage_to_archive(bucket, uid: str) -> int:
    if bucket is None:
        return 0
    moved = 0
    src_prefix = _QUARANTINE_STORAGE_PREFIX.format(uid=uid)
    dst_prefix = _ARCHIVE_STORAGE_PREFIX.format(uid=uid)
    for blob in list(bucket.list_blobs(prefix=src_prefix)):
        rel = blob.name[len(src_prefix):]
        bucket.copy_blob(blob, bucket, dst_prefix + rel)
        blob.delete()
        moved += 1
    return moved


def purge_expired(db, bucket, now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(days=CONFIG.account_recovery_days)

    checked = purged = 0
    for snap in db.collection(schema.DELETED_ACCOUNTS).stream():
        checked += 1
        deleted_at = (snap.to_dict() or {}).get("deleted_at")
        if not isinstance(deleted_at, datetime):
            continue
        if deleted_at.tzinfo is None:
            deleted_at = deleted_at.replace(tzinfo=timezone.utc)
        if deleted_at > cutoff:
            continue

        uid = snap.id
        try:
            _move_storage_to_archive(bucket, uid)
            _move_to_permanent_archive(db, uid)
            try:
                firebase_auth.delete_user(uid)
            except firebase_auth.UserNotFoundError:
                pass
            purged += 1
        except Exception:  # noqa: BLE001 - one bad account can't stop the sweep
            logger.exception("purge failed for %s", uid)

    return {"checked": checked, "purged": purged}
