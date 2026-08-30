"""Admin console data (ARCHITECTURE.md §14.3).

Read-only inspection over the final data model, gated by ``require_admin_password``
(§14.3) and served through the Admin SDK so it sees every tier, including
``ai_only`` wiki pages and ``deleted_accounts`` (§9.2).
"""

from __future__ import annotations

import schema

_USER_SCAN_LIMIT = 400
_LIST_LIMIT = 50


def _profile(db, uid: str) -> dict:
    snap = schema.profile_doc(db, uid).get()
    return snap.to_dict() or {} if snap.exists else {}


def _summary(db, uid: str, account: dict, profile: dict) -> dict:
    return {
        "uid": uid,
        "name": profile.get(schema.PF_NAME, ""),
        "community": account.get(schema.FIELD_COMMUNITY, ""),
        "session_mode": account.get(schema.FIELD_SESSION_MODE, ""),
        "paused": profile.get(schema.PF_PAUSED, False) is True,
        "trust_flags": len(account.get(schema.FIELD_TRUST_FLAGS) or []),
    }


def search_users(db, query: str) -> list[dict]:
    """Exact-uid hit first, then a bounded case-insensitive name-substring scan."""
    query = query.strip()
    if not query:
        return []
    out: list[dict] = []
    seen: set[str] = set()

    exact = db.collection(schema.USERS).document(query).get()
    if exact.exists:
        acct = exact.to_dict() or {}
        out.append(_summary(db, query, acct, _profile(db, query)))
        seen.add(query)

    needle = query.lower()
    for snap in db.collection(schema.USERS).limit(_USER_SCAN_LIMIT).stream():
        if snap.id in seen or len(out) >= _LIST_LIMIT:
            break
        prof = _profile(db, snap.id)
        if needle in str(prof.get(schema.PF_NAME, "")).lower():
            out.append(_summary(db, snap.id, snap.to_dict() or {}, prof))
            seen.add(snap.id)
    return out


def user_detail(db, uid: str) -> dict:
    account_snap = db.collection(schema.USERS).document(uid).get()
    account = account_snap.to_dict() or {} if account_snap.exists else {}
    profile = _profile(db, uid)

    wiki = []
    for s in schema.user_subcollection(db, uid, schema.WIKI_PAGES).stream():
        d = s.to_dict() or {}
        wiki.append({
            "page_id": s.id,
            "page_type": d.get("page_type", ""),
            "visibility": d.get("visibility", ""),
            "ai_body": d.get("ai_body", ""),
            "user_edits": d.get("user_edits", ""),
            "user_hidden": d.get("user_hidden", False) is True,
            "lint_flags": d.get("lint_flags") or [],
        })

    matches = []
    for s in (
        db.collection(schema.MATCHES_COLLECTION)
        .where("uids", "array_contains", uid)
        .limit(_LIST_LIMIT)
        .stream()
    ):
        d = s.to_dict() or {}
        matches.append({
            "match_id": s.id,
            "uids": d.get("uids", []),
            "status": d.get("status", ""),
            "score": d.get("score"),
        })

    threads = []
    for s in (
        db.collection(schema.DM_THREADS_COLLECTION)
        .where("participants", "array_contains", uid)
        .limit(_LIST_LIMIT)
        .stream()
    ):
        d = s.to_dict() or {}
        threads.append({
            "thread_id": s.id,
            "participants": d.get("participants", []),
            "last_message_at": str(d.get("last_message_at", "")),
            "hidden_for": d.get("hidden_for", []),
        })

    deleted_snap = db.collection(schema.DELETED_ACCOUNTS).document(uid).get()

    return {
        "uid": uid,
        "exists": account_snap.exists,
        "account": {
            k: account.get(k)
            for k in (
                schema.FIELD_SESSION_MODE, schema.FIELD_COMMUNITY,
                "marketing_turn_count", "interview_turn_count",
                schema.FIELD_LAST_ACTIVE_AT, "admin",
            )
        },
        "profile": profile,
        "trust_flags": account.get(schema.FIELD_TRUST_FLAGS) or [],
        "wiki_pages": wiki,
        "matches": matches,
        "dm_threads": threads,
        "deleted_account": deleted_snap.to_dict() if deleted_snap.exists else None,
    }
