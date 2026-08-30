"""Permanent purge of soft-deleted accounts past the recovery window
(ARCHITECTURE.md §3.6, §3.10 step 10).

A daily Cloud Scheduler job hits ``POST /cron/purge-deleted``. For every
``deleted_accounts/{uid}`` whose ``deleted_at`` is older than
``CONFIG.account_recovery_days``, this removes the Firestore quarantine subtree,
the quarantined Storage objects, and the Firebase Auth account itself.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from firebase_admin import auth as firebase_auth

from account_ops import _SUBCOLLECTIONS
from config import CONFIG

logger = logging.getLogger("ayma.account")

_QUARANTINE_STORAGE_PREFIX = "deleted_accounts/{uid}/"


def _delete_quarantine_subtree(db, uid: str) -> None:
    doc = db.collection("deleted_accounts").document(uid)
    for name in _SUBCOLLECTIONS:
        for child in doc.collection(name).stream():
            child.reference.delete()
    doc.delete()


def _delete_quarantine_storage(bucket, uid: str) -> int:
    if bucket is None:
        return 0
    n = 0
    for blob in list(
        bucket.list_blobs(prefix=_QUARANTINE_STORAGE_PREFIX.format(uid=uid))
    ):
        blob.delete()
        n += 1
    return n


def purge_expired(db, bucket, now: datetime | None = None) -> dict:
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(days=CONFIG.account_recovery_days)

    checked = purged = 0
    for snap in db.collection("deleted_accounts").stream():
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
            _delete_quarantine_storage(bucket, uid)
            _delete_quarantine_subtree(db, uid)
            try:
                firebase_auth.delete_user(uid)
            except firebase_auth.UserNotFoundError:
                pass
            purged += 1
        except Exception:  # noqa: BLE001 - one bad account can't stop the sweep
            logger.exception("purge failed for %s", uid)

    return {"checked": checked, "purged": purged}
