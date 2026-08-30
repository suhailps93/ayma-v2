import pytest

import dm_ops


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data or {})


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    @property
    def id(self):
        return self.key[-1]

    def get(self):
        return _Snap(self.store.docs.get(self.key))

    def set(self, data, merge=False):
        cur = dict(self.store.docs.get(self.key) or {}) if merge else {}
        cur.update(data)
        self.store.docs[self.key] = cur

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key
        self._auto = 0

    def document(self, doc_id=None):
        if doc_id is None:
            self._auto += 1
            doc_id = f"msg{self._auto}"
        return _DocRef(self.store, self.key + (doc_id,))


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def test_post_message_creates_thread_and_message():
    db = FakeDb()
    mid = dm_ops.post_message(db, "a", "b", "text", "hi there")
    assert db.docs[("dm_threads", "a__b")]["participants"] == ["a", "b"]
    msg = db.docs[("dm_threads", "a__b", "messages", mid)]
    assert msg == {
        "sender_uid": "a",
        "type": "text",
        "body": "hi there",
        "created_at": msg["created_at"],
    }


def test_shared_profile_message():
    db = FakeDb()
    mid = dm_ops.post_message(db, "a", "b", "shared_profile", "c")
    assert db.docs[("dm_threads", "a__b", "messages", mid)]["type"] == (
        "shared_profile"
    )
    assert db.docs[("dm_threads", "a__b", "messages", mid)]["body"] == "c"


def test_blocked_pairs_cannot_message():
    db = FakeDb()
    db.docs[("blocks", "b_a")] = {}
    with pytest.raises(PermissionError):
        dm_ops.post_message(db, "a", "b", "text", "hi")


def test_bad_type_rejected():
    with pytest.raises(ValueError):
        dm_ops.post_message(FakeDb(), "a", "b", "hologram", "x")


# --- /dm/{threadId}/messages endpoint --------------------------------------
import main  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from firebase_admin import auth as _fa  # noqa: E402

_client = TestClient(main.app)


def _authed(monkeypatch, uid):
    monkeypatch.setattr(_fa, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer v"}


def test_dm_send_requires_participant(monkeypatch):
    resp = _client.post(
        "/dm/aaa__bbb/messages",
        headers=_authed(monkeypatch, "stranger"),
        json={"type": "text", "body": "hi"},
    )
    assert resp.status_code == 403


def test_dm_send_text(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        main.dm_ops, "post_message",
        lambda db, s, o, t, b: seen.update(s=s, o=o, t=t, b=b) or "m1",
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = _client.post(
        "/dm/aaa__bbb/messages",
        headers=_authed(monkeypatch, "aaa"),
        json={"type": "text", "body": "hey"},
    )
    assert resp.json()["message_id"] == "m1"
    assert seen == {"s": "aaa", "o": "bbb", "t": "text", "b": "hey"}


def test_dm_send_photo_path_must_be_own_uploads(monkeypatch):
    resp = _client.post(
        "/dm/aaa__bbb/messages",
        headers=_authed(monkeypatch, "aaa"),
        json={"type": "photo", "body": "uploads/bbb/x.jpg"},
    )
    assert resp.status_code == 400
