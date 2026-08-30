import dataclasses
from datetime import datetime, timedelta, timezone

import account_purge
from config import CONFIG
from firebase_admin import auth as firebase_auth


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    def to_dict(self):
        return dict(self._data)

    @property
    def reference(self):
        return _DocRef()


class _DocRef:
    def delete(self):
        pass

    def collection(self, _name):
        return _Coll([])


class _Coll:
    def __init__(self, snaps):
        self._snaps = snaps

    def stream(self):
        return iter(self._snaps)

    def document(self, _id):
        return _DocRef()


class _Db:
    def __init__(self, deleted):
        self._deleted = deleted

    def collection(self, name):
        assert name == "deleted_accounts"
        return _Coll(self._deleted)


def test_purges_only_accounts_past_the_window(monkeypatch):
    monkeypatch.setattr(
        account_purge, "CONFIG",
        dataclasses.replace(CONFIG, account_recovery_days=30),
    )
    now = datetime(2026, 8, 30, tzinfo=timezone.utc)
    db = _Db([
        _Snap("old", {"deleted_at": now - timedelta(days=45)}),
        _Snap("fresh", {"deleted_at": now - timedelta(days=5)}),
        _Snap("nostamp", {}),
    ])
    deleted_uids = []
    monkeypatch.setattr(
        firebase_auth, "delete_user", lambda uid: deleted_uids.append(uid)
    )
    monkeypatch.setattr(
        account_purge, "_delete_quarantine_storage", lambda b, u: 0
    )

    out = account_purge.purge_expired(db, None, now=now)
    assert out == {"checked": 3, "purged": 1}
    assert deleted_uids == ["old"]


def test_missing_auth_user_is_tolerated(monkeypatch):
    monkeypatch.setattr(
        account_purge, "CONFIG",
        dataclasses.replace(CONFIG, account_recovery_days=1),
    )
    now = datetime.now(timezone.utc)

    def _raise(_uid):
        raise firebase_auth.UserNotFoundError("gone")

    monkeypatch.setattr(firebase_auth, "delete_user", _raise)
    monkeypatch.setattr(
        account_purge, "_delete_quarantine_storage", lambda b, u: 0
    )
    db = _Db([_Snap("x", {"deleted_at": now - timedelta(days=10)})])
    assert account_purge.purge_expired(db, None, now=now)["purged"] == 1
