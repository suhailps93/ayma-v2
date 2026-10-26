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

    async def _fake_push_only(db, uid, type_, **kw):
        calls.append({"uid": uid, "type": type_, "push_only": True, **kw})
        return {"pushed": True}

    monkeypatch.setattr(nt, "dispatch", _fake_dispatch)
    monkeypatch.setattr(
        nt, "_sender_identity", lambda db, uid: ("Dillu", "https://x/p.jpg")
    )
    monkeypatch.setattr(nt, "push_only", _fake_push_only)
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
    # DMs never create a Notifications-tab entry: push-only path.
    assert _capture[0]["push_only"] is True


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


def test_new_scored_matches_deep_links_straight_to_the_one_match(_capture):
    # A single new match: the push should open that match's request screen
    # directly, not the "New from Ayma" list — so a tap lands exactly where
    # the founder wants it, not one more tap away.
    _run(nt.notify_new_scored_matches(
        object(), "u1", 1, match_id="u1__bob", other_uid="bob"))
    assert _capture[0]["deep_link"] == "match_request/u1__bob"
    assert _capture[0]["actor_uid"] == "bob"


def test_new_scored_matches_falls_back_to_the_list_without_a_match_id(_capture):
    # Defensive: if the caller didn't pass a match_id (shouldn't happen for
    # count == 1, but never crash a best-effort push over it), fall back to
    # the list link rather than a broken `match_request/` deep link.
    _run(nt.notify_new_scored_matches(object(), "u1", 1))
    assert _capture[0]["deep_link"] == "matches"


def test_new_scored_matches_multiple_still_deep_links_to_the_list(_capture):
    # More than one new match: no single one to jump to, so the digest still
    # opens the list — and doesn't tag a single actor_uid for a grouped push.
    _run(nt.notify_new_scored_matches(
        object(), "u1", 2, match_id="u1__bob", other_uid="bob"))
    assert _capture[0]["deep_link"] == "matches"
    assert _capture[0]["actor_uid"] == ""


def test_profile_suggestions_zero_count_is_a_noop(_capture):
    _run(nt.notify_profile_suggestions(object(), "u1", 0))
    assert _capture == []


def test_profile_suggestions_deep_links_to_the_review_screen(_capture):
    _run(nt.notify_profile_suggestions(object(), "u1", 1))
    _run(nt.notify_profile_suggestions(object(), "u1", 3))
    assert _capture[0]["type"] == "profile_suggestions"
    assert _capture[0]["fixed_preview"] == (
        "Ayma suggests 1 update to your public profile."
    )
    assert _capture[1]["fixed_preview"] == (
        "Ayma suggests 3 updates to your public profile."
    )
    assert _capture[0]["deep_link"] == "profile_suggestions"


def test_ayma_reply_pushes_a_clean_preview_to_the_chat(monkeypatch):
    seen = []

    async def _fake_push_only(db, uid, type_, **kw):
        seen.append({"uid": uid, "type": type_, **kw})
        return {"pushed": True}

    monkeypatch.setattr(nt, "push_only", _fake_push_only)
    _run(nt.notify_ayma_reply(
        object(), "u1", "Here is your report.\n\n[face_report:abc-123]"))
    assert seen == [{
        "uid": "u1", "type": "ayma_reply",
        "body": "Here is your report.", "deep_link": "chat",
    }]


def test_ayma_reply_never_raises(monkeypatch):
    async def _boom(*_a, **_kw):
        raise RuntimeError("fcm down")

    monkeypatch.setattr(nt, "push_only", _boom)
    _run(nt.notify_ayma_reply(object(), "u1", "hi"))


def test_dm_push_carries_sender_identity_for_the_chat_notification(_capture):
    _run(nt.notify_new_dm(_ThreadDb(None), "a__bob", "a", "bob",
                          "text", "hello"))
    call = _capture[0]
    assert call["title"] == "Dillu"
    assert call["push_body"] == "hello"
    data = call["push_data"]
    assert data["type"] == "dm"
    assert data["deep_link"] == "dm_thread/a__bob"
    assert data["thread_id"] == "a__bob"
    assert data["sender_uid"] == "a"
    assert data["sender_name"] == "Dillu"
    assert data["sender_photo_url"] == "https://x/p.jpg"
    assert "$" not in str(data) and "credit" not in str(data).lower()


def test_dm_photo_push_body_is_plain_photo(_capture):
    _run(nt.notify_new_dm(_ThreadDb(None), "a__bob", "a", "bob",
                          "photo", "uploads/a/p.jpg"))
    assert _capture[0]["push_body"] == "Photo"
    assert _capture[0]["push_data"]["msg_type"] == "photo"


def test_dm_push_without_profile_falls_back_to_blank_identity(
        _capture, monkeypatch):
    monkeypatch.setattr(nt, "_sender_identity", lambda db, uid: ("", ""))
    _run(nt.notify_new_dm(_ThreadDb(None), "a__bob", "a", "bob", "text", "yo"))
    assert _capture[0]["title"] == "New message"
    assert _capture[0]["push_data"]["sender_photo_url"] == ""
