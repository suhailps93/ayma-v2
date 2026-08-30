import notifications_ops
import pytest
from config import CONFIG
from notifications_schema import FCM_TOKENS_FIELD, default_prefs


class _Doc:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def get(self):
        data = self._store.get(self._key)
        doc = self

        class _S:
            exists = data is not None

            def to_dict(self):
                return dict(data) if data else {}

        return _S()

    def set(self, payload, merge=False):
        cur = self._store.get(self._key) or {}
        if not merge:
            cur = {}
        for k, v in payload.items():
            cur[k] = _apply(cur.get(k), v)
        self._store[self._key] = cur

    def collection(self, name):
        return _Col(self._store, self._key + (name,))


class _Col:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def document(self, doc_id):
        return _Doc(self._store, self._key + (doc_id,))


class _Db:
    def __init__(self):
        self._store = {}

    def collection(self, name):
        return _Col(self._store, (name,))


class _ArrayUnion:
    def __init__(self, values):
        self.values = values


class _ArrayRemove:
    def __init__(self, values):
        self.values = values


def _apply(current, value):
    if isinstance(value, _ArrayUnion):
        out = list(current or [])
        for v in value.values:
            if v not in out:
                out.append(v)
        return out
    if isinstance(value, _ArrayRemove):
        return [v for v in (current or []) if v not in value.values]
    return value


@pytest.fixture(autouse=True)
def _patch_firestore(monkeypatch):
    monkeypatch.setattr(notifications_ops.firestore, "ArrayUnion", _ArrayUnion)
    monkeypatch.setattr(notifications_ops.firestore, "ArrayRemove", _ArrayRemove)


def test_register_token_is_idempotent():
    db = _Db()
    notifications_ops.register_token(db, "u1", "tok-a")
    notifications_ops.register_token(db, "u1", "tok-a")
    notifications_ops.register_token(db, "u1", "tok-b")
    tokens = db._store[("users", "u1")][FCM_TOKENS_FIELD]
    assert tokens == ["tok-a", "tok-b"]


def test_register_token_trims_to_the_cap():
    db = _Db()
    for i in range(CONFIG.max_fcm_tokens + 5):
        notifications_ops.register_token(db, "u1", f"tok-{i}")
    tokens = db._store[("users", "u1")][FCM_TOKENS_FIELD]
    assert len(tokens) == CONFIG.max_fcm_tokens
    # the most recently registered token is always kept
    assert tokens[-1] == f"tok-{CONFIG.max_fcm_tokens + 4}"


def test_register_token_rejects_empty():
    with pytest.raises(ValueError):
        notifications_ops.register_token(_Db(), "u1", "   ")


def test_unregister_token_removes_it():
    db = _Db()
    notifications_ops.register_token(db, "u1", "tok-a")
    notifications_ops.register_token(db, "u1", "tok-b")
    notifications_ops.unregister_token(db, "u1", "tok-a")
    assert db._store[("users", "u1")][FCM_TOKENS_FIELD] == ["tok-b"]


def test_read_prefs_defaults_then_reflects_a_toggle():
    db = _Db()
    assert notifications_ops.read_prefs(db, "u1") == default_prefs()
    notifications_ops.set_pref(db, "u1", "dm_message", False)
    prefs = notifications_ops.read_prefs(db, "u1")
    assert prefs["dm_message"] is False
    assert prefs["mutual_match"] is True


def test_set_pref_rejects_unknown_category():
    with pytest.raises(ValueError):
        notifications_ops.set_pref(_Db(), "u1", "nope", True)
