"""Unit tests for the soft-delete / recover subtree machinery, against a small
in-memory Firestore fake."""

import account_ops


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self._store = store
        self.key = key

    def get(self):
        return _Snap(self._store.docs.get(self.key))

    def set(self, data, merge=False):
        cur = self._store.docs.get(self.key) if merge else None
        cur = dict(cur) if cur else {}
        cur.update(data)
        self._store.docs[self.key] = cur

    def update(self, data):
        cur = dict(self._store.docs.get(self.key) or {})
        for k, v in data.items():
            if v == "__DELETE__":
                cur.pop(k, None)
            else:
                cur[k] = v
        self._store.docs[self.key] = cur

    def delete(self):
        self._store.docs.pop(self.key, None)

    def collection(self, name):
        return _CollRef(self._store, self.key + (name,))

    @property
    def reference(self):
        return self


class _CollRef:
    def __init__(self, store, key):
        self._store = store
        self.key = key

    def document(self, doc_id):
        return _DocRef(self._store, self.key + (doc_id,))

    def stream(self):
        depth = len(self.key)
        for key, data in list(self._store.docs.items()):
            if len(key) == depth + 1 and key[:depth] == self.key:
                yield _StreamSnap(self._store, key, data)


class _StreamSnap:
    def __init__(self, store, key, data):
        self._store = store
        self._key = key
        self.id = key[-1]
        self._data = data

    def to_dict(self):
        return dict(self._data)

    @property
    def reference(self):
        return _DocRef(self._store, self._key)


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def _seed_account(db, uid):
    db.docs[("users", uid)] = {"created_at": 1, "marketing_turn_count": 3}
    db.docs[("users", uid, "profile", "main")] = {"name": "Jo"}
    db.docs[("users", uid, "wiki_pages", "career")] = {"ai_body": "Nurse."}
    db.docs[("users", uid, "raw_turns", "s1")] = {"turn_count": 2}
    db.docs[("users", uid, "pending_questions", "q1")] = {"status": "pending"}


def test_soft_delete_then_recover_round_trips(monkeypatch):
    # firestore sentinels -> plain markers for the fake
    monkeypatch.setattr(account_ops.firestore, "SERVER_TIMESTAMP", 999)
    monkeypatch.setattr(account_ops.firestore, "DELETE_FIELD", "__DELETE__")

    db = FakeDb()
    _seed_account(db, "u1")

    out = account_ops.soft_delete(db, None, "u1")
    assert out["deleted"] is True
    # live tree gone
    assert ("users", "u1") not in db.docs
    assert ("users", "u1", "wiki_pages", "career") not in db.docs
    # quarantine populated
    assert db.docs[("deleted_accounts", "u1")]["deleted_at"] == 999
    assert db.docs[("deleted_accounts", "u1", "wiki_pages", "career")] == {
        "ai_body": "Nurse."
    }
    assert account_ops.is_recovery_required(db, "u1") is True

    rec = account_ops.recover(db, None, "u1")
    assert rec["restored"] is True
    assert db.docs[("users", "u1", "profile", "main")] == {"name": "Jo"}
    assert db.docs[("users", "u1", "raw_turns", "s1")] == {"turn_count": 2}
    # quarantine cleared, bookkeeping stripped from the restored doc
    assert ("deleted_accounts", "u1") not in db.docs
    assert "deleted_at" not in db.docs[("users", "u1")]
    assert account_ops.is_recovery_required(db, "u1") is False


def test_soft_delete_is_a_noop_without_a_live_account():
    db = FakeDb()
    out = account_ops.soft_delete(db, None, "ghost")
    assert out["deleted"] is False


def test_is_recovery_required_needs_quarantine_and_no_live():
    db = FakeDb()
    assert account_ops.is_recovery_required(db, "u1") is False
    db.docs[("deleted_accounts", "u1")] = {"deleted_at": 1}
    assert account_ops.is_recovery_required(db, "u1") is True
    db.docs[("users", "u1")] = {"x": 1}
    assert account_ops.is_recovery_required(db, "u1") is False
