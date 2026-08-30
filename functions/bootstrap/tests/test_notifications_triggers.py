import asyncio
from datetime import datetime, timedelta, timezone

import notifications_triggers as nt
import pytest


def _run(coro):
    return asyncio.run(coro)


class _ThreadDb:
    def __init__(self, last_read_at):
        self._doc = {"last_read_at": last_read_at} if last_read_at else {}

    def collection(self, name):
        assert name == "dm_threads"
        return self

    def document(self, _):
        return self

    def get(self):
        doc = self._doc

        class _S:
            exists = True

            def to_dict(self_):
                return doc

        return _S()


@pytest.fixture(autouse=True)
def _capture(monkeypatch):
    calls = []

    async def _fake_dispatch(db, uid, type_, **kw):
        calls.append({"uid": uid, "type": type_, **kw})
        return {"pushed": True}

    monkeypatch.setattr(nt, "dispatch", _fake_dispatch)
    return calls


def test_dm_push_suppressed_while_recipient_is_viewing(_capture):
    fresh = datetime.now(timezone.utc) - timedelta(seconds=5)
    _run(nt.notify_new_dm(
        _ThreadDb({"bob": fresh}), "a__bob", "a", "bob", "text", "hi"))
    assert _capture == []


def test_dm_push_sent_when_not_viewing(_capture):
    stale = datetime.now(timezone.utc) - timedelta(minutes=10)
    _run(nt.notify_new_dm(
        _ThreadDb({"bob": stale}), "a__bob", "a", "bob", "text", "hello there"))
    assert len(_capture) == 1
    assert _capture[0]["uid"] == "bob"
    assert _capture[0]["type"] == "dm_message"
    assert _capture[0]["body"] == "hello there"
    assert _capture[0]["deep_link"] == "dm_thread/a__bob"


def test_dm_photo_uses_a_fixed_body(_capture):
    _run(nt.notify_new_dm(_ThreadDb(None), "a__bob", "a", "bob",
                          "photo", "uploads/a/p.jpg"))
    assert _capture[0]["body"] == "📷 Photo"


def test_mutual_match_notifies_both_users(_capture):
    _run(nt.notify_mutual_match(object(), "a", "b"))
    assert {c["uid"] for c in _capture} == {"a", "b"}
    assert all(c["type"] == "mutual_match" for c in _capture)
    by_uid = {c["uid"]: c for c in _capture}
    assert by_uid["a"]["deep_link"] == "profile/b"
    assert by_uid["b"]["deep_link"] == "profile/a"


def test_new_scored_matches_zero_count_is_a_noop(_capture):
    _run(nt.notify_new_scored_matches(object(), "u1", 0))
    assert _capture == []


def test_new_scored_matches_pluralizes(_capture):
    _run(nt.notify_new_scored_matches(object(), "u1", 1))
    _run(nt.notify_new_scored_matches(object(), "u1", 3))
    assert _capture[0]["fixed_preview"] == "Ayma found 1 new match for you."
    assert _capture[1]["fixed_preview"] == "Ayma found 3 new matches for you."
    assert _capture[1]["deep_link"] == "matches"
