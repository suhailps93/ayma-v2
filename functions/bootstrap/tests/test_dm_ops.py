import pytest

from firebase_admin import firestore

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

    def delete(self):
        self.store.docs.pop(self.key, None)

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


def test_post_message_increments_only_the_recipients_unread_counter():
    db = FakeDb()
    dm_ops.post_message(db, "a", "b", "text", "hi")
    unread = db.docs[("dm_threads", "a__b")]["unread"]
    assert list(unread) == ["b"]
    assert isinstance(unread["b"], firestore.Increment)


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


def test_post_message_allowed_verdict_stores_no_flag():
    db = FakeDb()
    mid = dm_ops.post_message(
        db, "a", "b", "text", "hi there",
        moderation={"flagged": False, "reason": "", "categories": []},
    )
    msg = db.docs[("dm_threads", "a__b", "messages", mid)]
    assert "moderated" not in msg
    assert "moderation_reason" not in msg
    assert msg["body"] == "hi there"


def test_post_message_flagged_verdict_still_delivers_and_flags():
    db = FakeDb()
    mid = dm_ops.post_message(
        db, "a", "b", "text", "nasty stuff",
        moderation={
            "flagged": True,
            "reason": "harassment",
            "categories": ["harassment"],
        },
    )
    msg = db.docs[("dm_threads", "a__b", "messages", mid)]
    # Delivered in full — flagging never redacts the text.
    assert msg["body"] == "nasty stuff"
    assert msg["moderated"] is True
    assert msg["moderation_reason"] == "harassment"
    assert msg["moderation_categories"] == ["harassment"]


def test_post_message_with_no_moderation_arg_stores_no_flag():
    """Back-compat: callers (or types) that never pass moderation still work."""
    db = FakeDb()
    mid = dm_ops.post_message(db, "a", "b", "shared_profile", "c")
    msg = db.docs[("dm_threads", "a__b", "messages", mid)]
    assert "moderated" not in msg


def test_mark_moderated_flags_an_existing_message():
    db = FakeDb()
    mid = dm_ops.post_message(db, "a", "b", "text", "nasty stuff")
    dm_ops.mark_moderated(
        db, "a__b", mid,
        {"flagged": True, "reason": "harassment", "categories": ["harassment"]},
    )
    msg = db.docs[("dm_threads", "a__b", "messages", mid)]
    assert msg["body"] == "nasty stuff"  # never redacted
    assert msg["moderated"] is True
    assert msg["moderation_reason"] == "harassment"
    assert msg["moderation_categories"] == ["harassment"]


def test_mark_moderated_is_a_noop_for_an_unflagged_verdict():
    db = FakeDb()
    mid = dm_ops.post_message(db, "a", "b", "text", "hi there")
    dm_ops.mark_moderated(
        db, "a__b", mid, {"flagged": False, "reason": "", "categories": []}
    )
    msg = db.docs[("dm_threads", "a__b", "messages", mid)]
    assert "moderated" not in msg


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
    """The moderation pass must never run inline before the response — the
    message is persisted (unmoderated) and returned immediately; moderation
    happens in a background task afterwards (see the tests below)."""
    seen = {}
    monkeypatch.setattr(
        main.dm_ops, "post_message",
        lambda db, s, o, t, b, att=None, mod=None, rs=None: seen.update(
            s=s, o=o, t=t, b=b, att=att, mod=mod
        )
        or "m1",
    )
    monkeypatch.setattr(main, "get_db", lambda: object())

    async def _should_not_block_the_response(_text):
        raise AssertionError(
            "moderate() must not be awaited before the response is sent"
        )

    monkeypatch.setattr(
        main.dm_moderation, "moderate", _should_not_block_the_response
    )
    resp = _client.post(
        "/dm/aaa__bbb/messages",
        headers=_authed(monkeypatch, "aaa"),
        json={"type": "text", "body": "hey"},
    )
    assert resp.status_code == 200
    assert resp.json()["message_id"] == "m1"
    assert seen == {
        "s": "aaa", "o": "bbb", "t": "text", "b": "hey", "att": None,
        "mod": None,
    }


def test_dm_send_text_flagged_updates_doc_in_background(monkeypatch):
    """Founder's explicit policy: flag it, never block it. The flag is
    applied to the already-sent message by the post-response background
    task, via ``dm_ops.mark_moderated``."""
    monkeypatch.setattr(
        main.dm_ops, "post_message",
        lambda db, s, o, t, b, att=None, mod=None, rs=None: "m2",
    )
    monkeypatch.setattr(main, "get_db", lambda: object())

    seen = {}

    def _fake_mark_moderated(db, thread_id, msg_id, moderation):
        seen.update(thread_id=thread_id, msg_id=msg_id, moderation=moderation)

    monkeypatch.setattr(main.dm_ops, "mark_moderated", _fake_mark_moderated)

    async def _flagged(_text):
        return {
            "flagged": True,
            "reason": "harassment",
            "categories": ["harassment"],
        }

    monkeypatch.setattr(main.dm_moderation, "moderate", _flagged)
    resp = _client.post(
        "/dm/aaa__bbb/messages",
        headers=_authed(monkeypatch, "aaa"),
        json={"type": "text", "body": "nasty stuff"},
    )
    assert resp.status_code == 200
    assert resp.json()["message_id"] == "m2"
    assert seen == {
        "thread_id": "aaa__bbb",
        "msg_id": "m2",
        "moderation": {
            "flagged": True,
            "reason": "harassment",
            "categories": ["harassment"],
        },
    }


def test_dm_send_text_moderation_error_fails_open(monkeypatch):
    """A moderation-check hiccup — in ``dm_moderation.moderate`` itself, or
    in the background task around it — must never affect the (already-sent)
    message or the response the sender got."""
    monkeypatch.setattr(
        main.dm_ops, "post_message",
        lambda db, s, o, t, b, att=None, mod=None, rs=None: "m3",
    )
    monkeypatch.setattr(main, "get_db", lambda: object())

    def _mark_moderated_should_not_be_called(*_a, **_kw):
        raise AssertionError("mark_moderated must not run for a failed check")

    monkeypatch.setattr(
        main.dm_ops, "mark_moderated", _mark_moderated_should_not_be_called
    )

    async def _boom(_text):
        raise RuntimeError("gemini timeout")

    monkeypatch.setattr(main.dm_moderation, "moderate", _boom)
    resp = _client.post(
        "/dm/aaa__bbb/messages",
        headers=_authed(monkeypatch, "aaa"),
        json={"type": "text", "body": "hi"},
    )
    assert resp.status_code == 200
    assert resp.json()["message_id"] == "m3"


def test_dm_send_photo_path_must_be_own_uploads(monkeypatch):
    resp = _client.post(
        "/dm/aaa__bbb/messages",
        headers=_authed(monkeypatch, "aaa"),
        json={"type": "photo", "body": "uploads/bbb/x.jpg"},
    )
    assert resp.status_code == 400


def test_dm_send_image_passes_attachment(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        main.dm_ops, "post_message",
        lambda db, s, o, t, b, att=None, mod=None, rs=None: seen.update(
            t=t, b=b, att=att
        )
        or "m2",
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = _client.post(
        "/dm/aaa__bbb/messages",
        headers=_authed(monkeypatch, "aaa"),
        json={
            "type": "image",
            "body": "on the trail",
            "attachment_url": "https://example.com/x.jpg",
            "attachment_path": "uploads/aaa/dm/aaa__bbb/1.jpg",
            "mime": "image/jpeg",
            "file_name": "x.jpg",
            "size": 4096,
        },
    )
    assert resp.status_code == 200
    assert seen["t"] == "image"
    assert seen["b"] == "on the trail"
    assert seen["att"] == {
        "attachment_url": "https://example.com/x.jpg",
        "attachment_path": "uploads/aaa/dm/aaa__bbb/1.jpg",
        "mime": "image/jpeg",
        "file_name": "x.jpg",
        "size": 4096,
    }


def test_dm_send_image_rejects_foreign_attachment_path(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = _client.post(
        "/dm/aaa__bbb/messages",
        headers=_authed(monkeypatch, "aaa"),
        json={
            "type": "file",
            "attachment_path": "uploads/bbb/dm/aaa__bbb/1.pdf",
        },
    )
    assert resp.status_code == 400


def test_post_message_writes_attachment_fields():
    db = FakeDb()
    mid = dm_ops.post_message(
        db,
        "a",
        "b",
        "file",
        "",
        {
            "attachment_url": "https://example.com/r.pdf",
            "attachment_path": "uploads/a/dm/a__b/9.pdf",
            "mime": "application/pdf",
            "file_name": "r.pdf",
            "size": 2048,
        },
    )
    msg = db.docs[("dm_threads", "a__b", "messages", mid)]
    assert msg["type"] == "file"
    assert msg["attachment_path"] == "uploads/a/dm/a__b/9.pdf"
    assert msg["file_name"] == "r.pdf"
    assert msg["size"] == 2048


def test_gif_is_a_known_attachment_type():
    """A GIF is its own message type and carries an attachment (url/path/…)."""
    import dm_schema

    assert "gif" in dm_schema.MESSAGE_TYPES
    assert "gif" in dm_schema.ATTACHMENT_MESSAGE_TYPES


def test_post_message_stores_a_gif_attachment():
    """A GIF message sends, stores and reads back with its url + type (§6.6)."""
    db = FakeDb()
    mid = dm_ops.post_message(
        db,
        "a",
        "b",
        "gif",
        "",
        {
            "attachment_url": "https://example.com/party.gif",
            "attachment_path": "uploads/a/dm/a__b/inserted_1.gif",
            "mime": "image/gif",
            "file_name": "inserted_1.gif",
            "size": 65536,
        },
    )
    msg = db.docs[("dm_threads", "a__b", "messages", mid)]
    assert msg["type"] == "gif"
    assert msg["attachment_url"] == "https://example.com/party.gif"
    assert msg["mime"] == "image/gif"
    assert msg["size"] == 65536


def test_dm_send_gif_passes_attachment(monkeypatch):
    """The endpoint accepts type `gif` and forwards the attachment (url/type)."""
    seen = {}
    monkeypatch.setattr(
        main.dm_ops, "post_message",
        lambda db, s, o, t, b, att=None, mod=None, rs=None: seen.update(
            t=t, b=b, att=att
        )
        or "mgif",
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = _client.post(
        "/dm/aaa__bbb/messages",
        headers=_authed(monkeypatch, "aaa"),
        json={
            "type": "gif",
            "attachment_url": "https://example.com/party.gif",
            "attachment_path": "uploads/aaa/dm/aaa__bbb/inserted_1.gif",
            "mime": "image/gif",
            "file_name": "inserted_1.gif",
            "size": 65536,
        },
    )
    assert resp.status_code == 200
    assert resp.json()["message_id"] == "mgif"
    assert seen["t"] == "gif"
    assert seen["att"]["attachment_url"] == "https://example.com/party.gif"
    assert seen["att"]["mime"] == "image/gif"
