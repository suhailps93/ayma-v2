"""Account soft-delete and recovery (ARCHITECTURE.md §3.6, §3.10 steps 8–9;
founder request 2026-09-20: archive-don't-destroy + identity severance).

``soft_delete`` copies the whole ``users/{uid}`` Firestore subtree (every
collection in ``schema.ACCOUNT_SUBCOLLECTIONS``, including the one known
nested level — ``wiki_pages/{id}/versions/{id}``) plus the user's
``uploads/{uid}/*`` Storage objects into a ``deleted_accounts/{uid}``
quarantine with a ``deleted_at`` stamp, then removes the live copies. The
Firebase Auth account is left intact so the person can still sign in (with a
session they already hold, or via a native Firebase provider — Google/Apple/
phone/email) and see the recovery screen. ``recover`` reverses it. The 30-day
permanent move into ``archived_accounts/{uid}`` (admin-only, retained
indefinitely) is ``account_purge.purge_expired``.

Three things beyond the plain ``users/{uid}`` subtree are also handled here,
per the founder's request:

1. **Identity-mapping severance** (the security-critical part). The only
   custom (non-Firebase-native) identity-provider mapping in this codebase is
   ``instagram_identities/{igId} -> {uid}`` (see ``instagram.py``). On
   ``soft_delete`` we archive a copy of any such mapping pointing at this uid
   into ``deleted_accounts/{uid}/identity_mappings/`` and delete the live
   mapping doc immediately (not at the 30-day purge mark). A later "Sign in
   with Instagram" for the same Instagram account then falls into
   ``instagram.signin``'s "new user" branch and gets a brand new uid + empty
   profile — it can never resolve back to this uid. Google/Apple/phone/email
   don't need this treatment: Firebase Auth resolves those natively, and
   deleting the Firebase Auth user (which ``account_purge`` does once the
   recovery window closes) is what severs *those* the same way.

   Trade-off, documented rather than silently made: unlike native providers,
   an Instagram user who deletes their account cannot recover by signing
   back in via Instagram during the 30-day window (there's no more mapping
   to resolve) — they can still recover via ``POST /account/recover`` with
   an already-authenticated session on the device (Firebase Auth sessions
   persist locally and are untouched by this), just not via a *fresh*
   Instagram sign-in. This was judged the safer default given the founder
   called identity-mapping correctness "the actual security/privacy-
   correctness core of this task" — revisit if product wants Instagram
   recovery-by-resignin preserved instead.

2. **Shared records (matches / DM threads) — point 3 of the founder's
   request.** A DM thread or match is a shared record with another user (B)
   who has an ongoing, legitimate relationship with that data. Deleting A's
   account must not silently destroy B's copy of their conversation. Default
   chosen here (documented so it can be revisited): the live ``matches`` and
   ``dm_threads`` (+ ``messages``) docs are left completely untouched — nothing
   is deleted, hidden, or mutated on them. A's full view of every such
   thread/match is additionally captured into
   ``deleted_accounts/{uid}/matches_snapshot/`` and
   ``.../dm_threads_snapshot/{threadId}/messages/`` for admin lookup. Instead
   of touching the shared doc, a tiny top-level tombstone
   ``deleted_users/{uid}`` is written; ``public_profile.build`` checks it and
   returns a "deleted user" placeholder for that uid going forward, so B's
   UI can render the other side as gone without B's own message history or
   match record ever being deleted.

3. Other top-level, uid-*referencing* (not uid-nested) collections —
   ``blocks`` and the support-ticket-shaped ``feedback`` / ``product_feedback``
   / ``bug_reports`` — are archived and then removed from the live
   collection, same as any other "this is the user's info" data.
"""

from __future__ import annotations

import logging

from firebase_admin import firestore

import schema

logger = logging.getLogger("ayma.account")

_STORAGE_PREFIX = "uploads/{uid}/"
_QUARANTINE_STORAGE_PREFIX = "deleted_accounts/{uid}/"

# Bounded scan for the `blocks` collection, which has no uid-indexed field to
# query on (doc id is "{blocker}_{blocked}") — mirrors admin.py's
# _USER_SCAN_LIMIT discipline. Only run once per account deletion.
_BLOCKS_SCAN_LIMIT = 2000
_QUERY_LIMIT = 500

# Top-level collections that reference a uid via a field (not nested under
# users/{uid}) and are archived + removed from the live collection on full
# account deletion — support-ticket-shaped per-user content.
_UID_FIELD_COLLECTIONS = ("feedback", "product_feedback", "bug_reports")

# Subcollections that exist *only* under deleted_accounts/{uid} (and later
# archived_accounts/{uid}) — the audit-trail copies written by
# soft_delete's _archive_* helpers below. Not part of `schema.
# ACCOUNT_SUBCOLLECTIONS` (they don't exist under the live `users/{uid}`),
# so `_copy_subtree`/`_delete_subtree` never touch them; both `recover`
# (cleanup) and `account_purge` (the move to the permanent archive) need
# their own names for these, hence they're listed here explicitly.
ARCHIVE_EXTRA_SUBCOLLECTIONS = (
    "identity_mappings",
    "matches_snapshot",
    "dm_threads_snapshot",
    "blocks",
    *_UID_FIELD_COLLECTIONS,
)
ARCHIVE_EXTRA_NESTED = {"dm_threads_snapshot": (schema.DM_MESSAGES_COLLECTION,)}


def _copy_named_subtree(src_doc, dst_doc, names, nested_map) -> None:
    for name in names:
        for child in src_doc.collection(name).stream():
            dst_doc.collection(name).document(child.id).set(child.to_dict() or {})
            for nested in nested_map.get(name, ()):
                for grandchild in child.reference.collection(nested).stream():
                    dst_doc.collection(name).document(child.id).collection(
                        nested
                    ).document(grandchild.id).set(grandchild.to_dict() or {})


def _delete_named_subtree(doc, names, nested_map) -> None:
    for name in names:
        for child in doc.collection(name).stream():
            for nested in nested_map.get(name, ()):
                for grandchild in child.reference.collection(nested).stream():
                    grandchild.reference.delete()
            child.reference.delete()


def _copy_subtree(db, src_doc, dst_doc) -> None:
    src_snap = src_doc.get()
    dst_doc.set(src_snap.to_dict() or {})
    _copy_named_subtree(
        src_doc, dst_doc, schema.ACCOUNT_SUBCOLLECTIONS, schema.NESTED_SUBCOLLECTIONS
    )


def _delete_subtree(db, doc) -> None:
    _delete_named_subtree(
        doc, schema.ACCOUNT_SUBCOLLECTIONS, schema.NESTED_SUBCOLLECTIONS
    )
    doc.delete()


def _move_storage(bucket, src_prefix: str, dst_prefix: str) -> int:
    moved = 0
    for blob in list(bucket.list_blobs(prefix=src_prefix)):
        rel = blob.name[len(src_prefix):]
        bucket.copy_blob(blob, bucket, dst_prefix + rel)
        blob.delete()
        moved += 1
    return moved


def _archive_and_clear_identity_mappings(db, dst_doc, uid: str) -> int:
    """Archive + delete any ``instagram_identities/*`` doc mapping to ``uid``.
    See the module docstring, point 1. Returns the number cleared."""
    n = 0
    identities = db.collection(schema.INSTAGRAM_IDENTITIES)
    for snap in identities.where("uid", "==", uid).limit(_QUERY_LIMIT).stream():
        data = snap.to_dict() or {}
        dst_doc.collection("identity_mappings").document(
            f"instagram_{snap.id}"
        ).set({**data, "provider": "instagram", "external_id": snap.id})
        snap.reference.delete()
        n += 1
    return n


def _archive_matches(db, dst_doc, uid: str) -> int:
    n = 0
    for snap in (
        db.collection(schema.MATCHES_COLLECTION)
        .where("uids", "array_contains", uid)
        .limit(_QUERY_LIMIT)
        .stream()
    ):
        dst_doc.collection("matches_snapshot").document(snap.id).set(
            snap.to_dict() or {}
        )
        n += 1
    return n


def _archive_dm_threads(db, dst_doc, uid: str) -> int:
    n = 0
    for snap in (
        db.collection(schema.DM_THREADS_COLLECTION)
        .where("participants", "array_contains", uid)
        .limit(_QUERY_LIMIT)
        .stream()
    ):
        thread_dst = dst_doc.collection("dm_threads_snapshot").document(snap.id)
        thread_dst.set(snap.to_dict() or {})
        for msg in snap.reference.collection(
            schema.DM_MESSAGES_COLLECTION
        ).stream():
            thread_dst.collection(schema.DM_MESSAGES_COLLECTION).document(
                msg.id
            ).set(msg.to_dict() or {})
        n += 1
    return n


def _archive_blocks(db, dst_doc, uid: str) -> int:
    n = 0
    prefix, suffix = f"{uid}_", f"_{uid}"
    for snap in db.collection(schema.BLOCKS_COLLECTION).limit(
        _BLOCKS_SCAN_LIMIT
    ).stream():
        if snap.id.startswith(prefix) or snap.id.endswith(suffix):
            dst_doc.collection("blocks").document(snap.id).set(
                snap.to_dict() or {}
            )
            snap.reference.delete()
            n += 1
    return n


def _archive_uid_field_collections(db, dst_doc, uid: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for name in _UID_FIELD_COLLECTIONS:
        n = 0
        for snap in (
            db.collection(name).where("uid", "==", uid).limit(_QUERY_LIMIT).stream()
        ):
            dst_doc.collection(name).document(snap.id).set(snap.to_dict() or {})
            snap.reference.delete()
            n += 1
        out[name] = n
    return out


def is_recovery_required(db, uid: str) -> bool:
    """A ``deleted_accounts/{uid}`` quarantine exists with no live account."""
    quarantined = db.collection(schema.DELETED_ACCOUNTS).document(uid).get().exists
    live = db.collection(schema.USERS).document(uid).get().exists
    return quarantined and not live


def soft_delete(db, bucket, uid: str) -> dict:
    src = db.collection(schema.USERS).document(uid)
    if not src.get().exists:
        return {"deleted": False, "reason": "no live account"}

    dst = db.collection(schema.DELETED_ACCOUNTS).document(uid)
    _copy_subtree(db, src, dst)
    dst.set(
        {"deleted_at": firestore.SERVER_TIMESTAMP, "original_uid": uid},
        merge=True,
    )

    identities_cleared = _archive_and_clear_identity_mappings(db, dst, uid)
    matches_archived = _archive_matches(db, dst, uid)
    dm_threads_archived = _archive_dm_threads(db, dst, uid)
    blocks_archived = _archive_blocks(db, dst, uid)
    uid_field_archived = _archive_uid_field_collections(db, dst, uid)

    # Tombstone so any shared record still live for another user (matches,
    # dm_threads — deliberately NOT touched above) can render "deleted user"
    # without needing to know which archive tier this uid ended up in.
    db.collection(schema.DELETED_USERS).document(uid).set(
        {"deleted_at": firestore.SERVER_TIMESTAMP}
    )

    files = 0
    if bucket is not None:
        files = _move_storage(
            bucket,
            _STORAGE_PREFIX.format(uid=uid),
            _QUARANTINE_STORAGE_PREFIX.format(uid=uid),
        )

    _delete_subtree(db, src)
    return {
        "deleted": True,
        "files_moved": files,
        "identity_mappings_cleared": identities_cleared,
        "matches_archived": matches_archived,
        "dm_threads_archived": dm_threads_archived,
        "blocks_archived": blocks_archived,
        **{f"{k}_archived": v for k, v in uid_field_archived.items()},
    }


def recover(db, bucket, uid: str) -> dict:
    src = db.collection(schema.DELETED_ACCOUNTS).document(uid)
    if not src.get().exists:
        return {"restored": False, "reason": "nothing to recover"}

    dst = db.collection(schema.USERS).document(uid)
    _copy_subtree(db, src, dst)
    # strip the quarantine bookkeeping from the restored account doc
    dst.update(
        {
            "deleted_at": firestore.DELETE_FIELD,
            "original_uid": firestore.DELETE_FIELD,
        }
    )

    # Note: identity_mappings/matches_snapshot/dm_threads_snapshot/blocks/
    # feedback/product_feedback/bug_reports archived under `src` by
    # soft_delete are deliberately NOT restored here (they aren't
    # `ACCOUNT_SUBCOLLECTIONS`, so `_copy_subtree`/`_delete_subtree` never
    # touch them) — those are audit-trail copies of data whose live source
    # of truth is elsewhere (instagram_identities, matches, dm_threads) or
    # was genuinely deleted (blocks/feedback/bug_reports) and isn't restored
    # by recovering the *account*, only by whatever process re-adds it
    # normally (e.g. signing in with Instagram again creates a fresh
    # mapping; re-blocking someone re-creates a block).
    db.collection(schema.DELETED_USERS).document(uid).delete()

    files = 0
    if bucket is not None:
        files = _move_storage(
            bucket,
            _QUARANTINE_STORAGE_PREFIX.format(uid=uid),
            _STORAGE_PREFIX.format(uid=uid),
        )

    _delete_named_subtree(src, ARCHIVE_EXTRA_SUBCOLLECTIONS, ARCHIVE_EXTRA_NESTED)
    _delete_subtree(db, src)
    return {"restored": True, "files_moved": files}
