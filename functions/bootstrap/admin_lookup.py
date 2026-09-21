"""Admin-only read functions over live users, fully-deleted accounts, and
knowledge-wipe archives (founder request 2026-09-20: "the admin dashboard
[should] have the ability to pull any user and see everything including
photos AI notes stories chat with other users and also data from these stale
keys").

Same discipline as ``admin.py`` (§14.3): plain sync functions taking ``db``
first, returning ``dict``/``list[dict]``, no FastAPI/Pydantic types, unit-
testable directly against a fake Firestore client. Routes wrap these in
``asyncio.to_thread`` behind ``Depends(require_admin_password)`` — see the
``/admin/*`` block in ``main.py``. Nothing here is reachable from any
non-admin endpoint; ``ARCHIVED_ACCOUNTS``/``ARCHIVED_KNOWLEDGE``/
``DELETED_ACCOUNTS`` also fall through Firestore's own default-deny
catch-all rule (no client SDK access exists for them regardless).

Three entry points, matching the three things an admin needs to look up:

* :func:`live_user_detail` — a still-active uid's complete data: account
  fields, profile, every ``schema.ACCOUNT_SUBCOLLECTIONS`` category (photos/
  user_media, appearance + physical + face/body reports, deep dives, skill
  runs, wiki pages incl. version history, chat transcript, etc.), plus the
  cross-user records (matches, dm_threads, blocks) and support tickets
  (feedback/product_feedback/bug_reports) that reference this uid.
* :func:`archived_account_detail` — a fully-deleted uid's data. Checks the
  permanent ``archived_accounts/{uid}`` first, falls back to the still-in-
  its-30-day-window ``deleted_accounts/{uid}`` quarantine, and reports which
  tier it found (or ``None`` if the uid was never deleted).
* :func:`knowledge_archive_list` / :func:`knowledge_archive_detail` — the
  timestamped "delete everything Ayma knows" snapshots for a uid (which may
  still be a live, active account) written by ``knowledge_wipe.py``.
"""

from __future__ import annotations

import schema

_QUERY_LIMIT = 200
_BLOCKS_SCAN_LIMIT = 2000


def _dump_subtree(doc, names, nested_map) -> dict[str, list[dict]]:
    """``{subcollection_name: [{"id": ..., **fields, "_nested": {...}}]}``
    for every name in ``names`` directly under ``doc``, recursing one extra
    level for any name present in ``nested_map`` (currently only
    ``wiki_pages`` -> ``versions``)."""
    out: dict[str, list[dict]] = {}
    for name in names:
        rows = []
        for child in doc.collection(name).stream():
            row = {"id": child.id, **(child.to_dict() or {})}
            for nested in nested_map.get(name, ()):
                nested_rows = [
                    {"id": g.id, **(g.to_dict() or {})}
                    for g in child.reference.collection(nested).stream()
                ]
                if nested_rows:
                    row[nested] = nested_rows
            rows.append(row)
        out[name] = rows
    return out


def _uid_field_rows(db, collection: str, uid: str) -> list[dict]:
    return [
        {"id": s.id, **(s.to_dict() or {})}
        for s in db.collection(collection)
        .where("uid", "==", uid)
        .limit(_QUERY_LIMIT)
        .stream()
    ]


def _matches_for(db, uid: str) -> list[dict]:
    return [
        {"id": s.id, **(s.to_dict() or {})}
        for s in db.collection(schema.MATCHES_COLLECTION)
        .where("uids", "array_contains", uid)
        .limit(_QUERY_LIMIT)
        .stream()
    ]


def _dm_threads_for(db, uid: str) -> list[dict]:
    out = []
    for s in (
        db.collection(schema.DM_THREADS_COLLECTION)
        .where("participants", "array_contains", uid)
        .limit(_QUERY_LIMIT)
        .stream()
    ):
        thread = {"id": s.id, **(s.to_dict() or {})}
        thread["messages"] = [
            {"id": m.id, **(m.to_dict() or {})}
            for m in s.reference.collection(schema.DM_MESSAGES_COLLECTION).stream()
        ]
        out.append(thread)
    return out


def _blocks_for(db, uid: str) -> list[dict]:
    prefix, suffix = f"{uid}_", f"_{uid}"
    out = []
    for s in db.collection(schema.BLOCKS_COLLECTION).limit(
        _BLOCKS_SCAN_LIMIT
    ).stream():
        if s.id.startswith(prefix) or s.id.endswith(suffix):
            out.append({"id": s.id, **(s.to_dict() or {})})
    return out


def live_user_detail(db, uid: str) -> dict:
    """Everything currently live for ``uid``. ``None``-safe: returns
    ``{"uid": uid, "exists": False}`` for a uid with no live account (it may
    still be worth checking :func:`archived_account_detail` for that uid)."""
    account_snap = db.collection(schema.USERS).document(uid).get()
    if not account_snap.exists:
        return {"uid": uid, "exists": False}

    doc = schema.user_doc(db, uid)
    subcollections = _dump_subtree(
        doc, schema.ACCOUNT_SUBCOLLECTIONS, schema.NESTED_SUBCOLLECTIONS
    )
    return {
        "uid": uid,
        "exists": True,
        "account": account_snap.to_dict() or {},
        **subcollections,
        "matches": _matches_for(db, uid),
        "dm_threads": _dm_threads_for(db, uid),
        "blocks": _blocks_for(db, uid),
        "feedback": _uid_field_rows(db, "feedback", uid),
        "product_feedback": _uid_field_rows(db, "product_feedback", uid),
        "bug_reports": _uid_field_rows(db, "bug_reports", uid),
        "recovery_pending": db.collection(schema.DELETED_ACCOUNTS)
        .document(uid)
        .get()
        .exists,
    }


# Mirrors account_ops.ARCHIVE_EXTRA_SUBCOLLECTIONS/ARCHIVE_EXTRA_NESTED —
# duplicated as plain data here (not imported) to keep admin_lookup.py
# read-only and independent of account_ops' write-path internals; update
# both lists together if a new archive-only subcollection is added.
_EXTRA_NAMES = (
    "identity_mappings",
    "matches_snapshot",
    "dm_threads_snapshot",
    "blocks",
    "feedback",
    "product_feedback",
    "bug_reports",
)
_EXTRA_NESTED = {"dm_threads_snapshot": (schema.DM_MESSAGES_COLLECTION,)}


def archived_account_detail(db, uid: str) -> dict | None:
    """A fully-deleted uid's data — the permanent ``archived_accounts/{uid}``
    if the recovery window has closed, else the still-recoverable
    ``deleted_accounts/{uid}`` quarantine. ``None`` if this uid was never
    soft-deleted at all. The returned dict's ``"tier"`` says which one:
    ``"archived"`` (permanent, Auth account gone) or ``"quarantined"``
    (within the ``CONFIG.account_recovery_days`` self-recovery window)."""
    for collection, tier in (
        (schema.ARCHIVED_ACCOUNTS, "archived"),
        (schema.DELETED_ACCOUNTS, "quarantined"),
    ):
        root_doc = db.collection(collection).document(uid)
        snap = root_doc.get()
        if not snap.exists:
            continue
        names = tuple(schema.ACCOUNT_SUBCOLLECTIONS)
        subcollections = _dump_subtree(root_doc, names, schema.NESTED_SUBCOLLECTIONS)
        extra = _dump_subtree(root_doc, _EXTRA_NAMES, _EXTRA_NESTED)
        return {
            "uid": uid,
            "tier": tier,
            "account": snap.to_dict() or {},
            **subcollections,
            **extra,
        }
    return None


def knowledge_archive_list(db, uid: str) -> list[dict]:
    """Summary rows (id, archived_at, original_uid) for every "delete
    everything Ayma knows" snapshot taken for ``uid`` — most recent last
    (archive ids are timestamp-prefixed, so lexical order is chronological).
    """
    rows = [
        {"archive_id": s.id, **(s.to_dict() or {})}
        for s in db.collection(schema.ARCHIVED_KNOWLEDGE)
        .document(uid)
        .collection("snapshots")
        .stream()
    ]
    rows.sort(key=lambda r: r["archive_id"])
    return rows


def knowledge_archive_detail(db, uid: str, archive_id: str) -> dict | None:
    """Full content of one ``archived_knowledge/{uid}/snapshots/{archive_id}``
    snapshot, or ``None`` if it doesn't exist."""
    root_doc = (
        db.collection(schema.ARCHIVED_KNOWLEDGE)
        .document(uid)
        .collection("snapshots")
        .document(archive_id)
    )
    snap = root_doc.get()
    if not snap.exists:
        return None
    subcollections = _dump_subtree(
        root_doc, schema.KNOWLEDGE_SUBCOLLECTIONS, schema.NESTED_SUBCOLLECTIONS
    )
    feedback = [
        {"id": s.id, **(s.to_dict() or {})}
        for s in root_doc.collection("feedback").stream()
    ]
    return {
        "uid": uid,
        "archive_id": archive_id,
        **(snap.to_dict() or {}),
        **subcollections,
        "feedback": feedback,
    }
