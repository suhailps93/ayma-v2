import dataclasses
from datetime import datetime, timedelta, timezone

import account_purge
from config import CONFIG
from fake_firestore import SERVER_TIMESTAMP, FakeDb
from firebase_admin import auth as firebase_auth


def _patch_sentinels(monkeypatch):
    monkeypatch.setattr(account_purge.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)


def test_purges_only_accounts_past_the_window(monkeypatch):
    _patch_sentinels(monkeypatch)
    monkeypatch.setattr(
        account_purge, "CONFIG",
        dataclasses.replace(CONFIG, account_recovery_days=30),
    )
    now = datetime(2026, 8, 30, tzinfo=timezone.utc)
    db = FakeDb()
    db.docs[("deleted_accounts", "old")] = {
        "deleted_at": now - timedelta(days=45), "original_uid": "old",
    }
    db.docs[("deleted_accounts", "old", "profile", "main")] = {"name": "Old Jo"}
    db.docs[("deleted_accounts", "fresh")] = {"deleted_at": now - timedelta(days=5)}
    db.docs[("deleted_accounts", "nostamp")] = {}

    deleted_uids = []
    monkeypatch.setattr(
        firebase_auth, "delete_user", lambda uid: deleted_uids.append(uid)
    )

    out = account_purge.purge_expired(db, None, now=now)
    assert out == {"checked": 3, "purged": 1}
    assert deleted_uids == ["old"]

    # data MOVED (not destroyed) into the permanent, admin-only archive
    assert ("deleted_accounts", "old") not in db.docs
    assert ("deleted_accounts", "old", "profile", "main") not in db.docs
    assert db.docs[("archived_accounts", "old")]["original_uid"] == "old"
    assert db.docs[("archived_accounts", "old")]["archived_at"] is SERVER_TIMESTAMP
    assert db.docs[("archived_accounts", "old", "profile", "main")] == {
        "name": "Old Jo"
    }
    # untouched accounts are left exactly as they were
    assert db.docs[("deleted_accounts", "fresh")]["deleted_at"] == (
        now - timedelta(days=5)
    )
    assert ("archived_accounts", "fresh") not in db.docs


def test_purge_moves_extra_archive_subcollections_too(monkeypatch):
    """identity_mappings / matches_snapshot / dm_threads_snapshot / blocks /
    feedback / product_feedback / bug_reports were written under
    deleted_accounts/{uid} by account_ops.soft_delete — the permanent move
    must carry them into archived_accounts/{uid} too, nothing dropped."""
    _patch_sentinels(monkeypatch)
    monkeypatch.setattr(
        account_purge, "CONFIG",
        dataclasses.replace(CONFIG, account_recovery_days=30),
    )
    now = datetime(2026, 8, 30, tzinfo=timezone.utc)
    db = FakeDb()
    db.docs[("deleted_accounts", "old")] = {"deleted_at": now - timedelta(days=45)}
    db.docs[("deleted_accounts", "old", "identity_mappings", "instagram_999")] = {
        "uid": "old", "provider": "instagram",
    }
    db.docs[("deleted_accounts", "old", "matches_snapshot", "old__u2")] = {
        "status": "mutual_interest"
    }
    db.docs[
        ("deleted_accounts", "old", "dm_threads_snapshot", "old__u2")
    ] = {"participants": ["old", "u2"]}
    db.docs[
        (
            "deleted_accounts", "old", "dm_threads_snapshot", "old__u2",
            "messages", "m1",
        )
    ] = {"text": "hi"}
    db.docs[("deleted_accounts", "old", "blocks", "old_u3")] = {"reason": "spam"}
    db.docs[("deleted_accounts", "old", "feedback", "f1")] = {"note": "meh"}

    monkeypatch.setattr(firebase_auth, "delete_user", lambda uid: None)
    out = account_purge.purge_expired(db, None, now=now)
    assert out["purged"] == 1

    assert db.docs[
        ("archived_accounts", "old", "identity_mappings", "instagram_999")
    ] == {"uid": "old", "provider": "instagram"}
    assert db.docs[
        ("archived_accounts", "old", "matches_snapshot", "old__u2")
    ] == {"status": "mutual_interest"}
    assert db.docs[
        ("archived_accounts", "old", "dm_threads_snapshot", "old__u2")
    ] == {"participants": ["old", "u2"]}
    assert db.docs[
        (
            "archived_accounts", "old", "dm_threads_snapshot", "old__u2",
            "messages", "m1",
        )
    ] == {"text": "hi"}
    assert db.docs[("archived_accounts", "old", "blocks", "old_u3")] == {
        "reason": "spam"
    }
    assert db.docs[("archived_accounts", "old", "feedback", "f1")] == {
        "note": "meh"
    }
    # nothing left behind in the quarantine collection
    assert not any(k[0] == "deleted_accounts" for k in db.docs)


def test_missing_auth_user_is_tolerated(monkeypatch):
    _patch_sentinels(monkeypatch)
    monkeypatch.setattr(
        account_purge, "CONFIG",
        dataclasses.replace(CONFIG, account_recovery_days=1),
    )
    now = datetime.now(timezone.utc)

    def _raise(_uid):
        raise firebase_auth.UserNotFoundError("gone")

    monkeypatch.setattr(firebase_auth, "delete_user", _raise)
    db = FakeDb()
    db.docs[("deleted_accounts", "x")] = {"deleted_at": now - timedelta(days=10)}
    out = account_purge.purge_expired(db, None, now=now)
    assert out["purged"] == 1
    # still archived even though the Auth user was already gone
    assert ("archived_accounts", "x") in db.docs
