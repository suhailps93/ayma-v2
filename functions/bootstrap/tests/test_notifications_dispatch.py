import asyncio
from datetime import datetime, timedelta, timezone

import notifications_dispatch as nd
import pytest
from config import CONFIG


def _run(coro):
    return asyncio.run(coro)


class _Doc:
    def __init__(self, store, key):
        self._s = store
        self._k = key

    def get(self):
        data = self._s.get(self._k)
        outer = self

        class _S:
            exists = data is not None

            def to_dict(self_):
                return dict(data) if data else {}

        return _S()

    def set(self, payload, merge=False):
        cur = dict(self._s.get(self._k) or {}) if merge else {}
        for k, v in payload.items():
            if isinstance(v, _ArrRemove):
                cur[k] = [x for x in (cur.get(k) or []) if x not in v.values]
            else:
                cur[k] = v
        self._s[self._k] = cur

    def collection(self, name):
        return _Col(self._s, self._k + (name,))


class _Col:
    _auto = 0

    def __init__(self, store, key):
        self._s = store
        self._k = key

    def document(self, doc_id=None):
        if doc_id is None:
            _Col._auto += 1
            doc_id = f"auto{_Col._auto}"
        return _Doc(self._s, self._k + (doc_id,))


class _Db:
    def __init__(self, seed=None):
        self.store = dict(seed or {})

    def collection(self, name):
        return _Col(self.store, (name,))


class _ArrRemove:
    def __init__(self, values):
        self.values = values


@pytest.fixture(autouse=True)
def _patch(monkeypatch):
    monkeypatch.setattr(nd.firestore, "SERVER_TIMESTAMP", "TS")
    monkeypatch.setattr(nd.firestore, "ArrayRemove", _ArrRemove)


def _notif_docs(db, uid):
    return [
        v for k, v in db.store.items()
        if k[:3] == ("users", uid, "notifications")
    ]


def test_muted_category_writes_nothing(monkeypatch):
    db = _Db({("users", "u1", "notification_prefs", "main"): {"dm_message": False}})
    delivered = []
    monkeypatch.setattr(nd, "_deliver", lambda *a: delivered.append(a))

    res = _run(nd.dispatch(db, "u1", "dm_message", body="hi"))

    assert res == {"muted": True, "doc": False, "pushed": False}
    assert _notif_docs(db, "u1") == []
    assert delivered == []


def test_writes_doc_and_pushes_with_truncated_preview(monkeypatch):
    long = "x" * (CONFIG.push_preview_len + 50)
    db = _Db({("users", "u1"): {"fcm_tokens": ["tok-a", "tok-b"]}})

    class _Resp:
        responses = [
            type("R", (), {"success": True, "exception": None})(),
            type("R", (), {"success": True, "exception": None})(),
        ]

    seen = {}
    monkeypatch.setattr(
        nd, "_deliver",
        lambda tokens, title, body, dl: seen.update(
            tokens=tokens, body=body, dl=dl) or _Resp(),
    )

    res = _run(nd.dispatch(db, "u1", "dm_message", body=long,
                           deep_link="dm_thread/t1"))

    assert res["doc"] and res["pushed"]
    doc = _notif_docs(db, "u1")[0]
    assert doc["type"] == "dm_message" and doc["read"] is False
    assert len(doc["body"]) == CONFIG.push_preview_len and doc["body"].endswith("…")
    assert seen["tokens"] == ["tok-a", "tok-b"]
    assert db.store[("users", "u1")]["last_push_at"] == "TS"
    assert "actor_uid" not in doc  # only written when given


def test_actor_uid_is_written_when_given(monkeypatch):
    db = _Db({("users", "u1"): {}})
    monkeypatch.setattr(nd, "_push", lambda *a, **k: False)
    _run(nd.dispatch(db, "u1", "dm_message", body="hi",
                     deep_link="dm_thread/t1", actor_uid="sender-9"))
    assert _notif_docs(db, "u1")[0]["actor_uid"] == "sender-9"


def test_cooldown_suppresses_push_but_keeps_doc(monkeypatch):
    recent = datetime.now(timezone.utc) - timedelta(seconds=10)
    db = _Db({("users", "u1"): {
        "fcm_tokens": ["tok-a"], "last_push_at": recent}})
    monkeypatch.setattr(nd, "_deliver",
                        lambda *a: pytest.fail("should not push"))

    res = _run(nd.dispatch(db, "u1", "mutual_match",
                           fixed_preview="new match"))

    assert res == {"muted": False, "doc": True, "pushed": False, "cooldown": True}
    assert _notif_docs(db, "u1")[0]["body"] == "new match"


def test_dead_tokens_are_pruned(monkeypatch):
    db = _Db({("users", "u1"): {"fcm_tokens": ["good", "dead"]}})

    class _Resp:
        responses = [
            type("R", (), {"success": True, "exception": None})(),
            type("R", (), {
                "success": False,
                "exception": nd.messaging.UnregisteredError("gone"),
            })(),
        ]

    monkeypatch.setattr(nd, "_deliver", lambda *a: _Resp())

    res = _run(nd.dispatch(db, "u1", "ayma_checkin", body="hey"))

    assert res["pushed"] is True
    assert db.store[("users", "u1")]["fcm_tokens"] == ["good"]


def test_no_tokens_writes_doc_only(monkeypatch):
    db = _Db({("users", "u1"): {}})
    monkeypatch.setattr(nd, "_deliver", lambda *a: pytest.fail("no push"))
    res = _run(nd.dispatch(db, "u1", "new_scored_match", fixed_preview="2 new"))
    assert res == {"muted": False, "doc": True, "pushed": False, "no_tokens": True}


def test_unknown_type_raises():
    with pytest.raises(ValueError):
        _run(nd.dispatch(_Db(), "u1", "bogus"))
