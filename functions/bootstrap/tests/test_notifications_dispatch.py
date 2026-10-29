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

    @property
    def id(self):
        return self._k[-1]

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
        lambda tokens, title, body, dl, notif_id="": seen.update(
            tokens=tokens, body=body, dl=dl, notif_id=notif_id) or _Resp(),
    )

    res = _run(nd.dispatch(db, "u1", "dm_message", body=long,
                           deep_link="dm_thread/t1"))

    assert res["doc"] and res["pushed"]
    doc = _notif_docs(db, "u1")[0]
    assert doc["type"] == "dm_message" and doc["read"] is False
    assert len(doc["body"]) == CONFIG.push_preview_len and doc["body"].endswith("…")
    assert seen["tokens"] == ["tok-a", "tok-b"]
    # The push carries the centre doc id so a tap can mark that exact in-app
    # notification read and keep the bell/OS badge in sync (§7.6).
    notif_keys = [
        k[-1] for k in db.store if k[:3] == ("users", "u1", "notifications")
    ]
    assert seen["notif_id"] and seen["notif_id"] in notif_keys
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


def test_dedup_id_collapses_to_one_rolling_centre_doc(monkeypatch):
    # Two fires with the same dedup_id land on one centre doc (the second
    # overwrites the first with the latest count), where auto-ids would stack
    # two rows — the public-profile-update duplicate-notification fix.
    db = _Db({("users", "u1"): {}})
    monkeypatch.setattr(nd, "_push", lambda *a, **k: False)
    _run(nd.dispatch(db, "u1", "profile_suggestions",
                     fixed_preview="Ayma suggests 1 update to your public profile.",
                     dedup_id="profile_suggestions_pending"))
    _run(nd.dispatch(db, "u1", "profile_suggestions",
                     fixed_preview="Ayma suggests 2 updates to your public profile.",
                     dedup_id="profile_suggestions_pending"))
    docs = _notif_docs(db, "u1")
    assert len(docs) == 1
    assert docs[0]["body"] == "Ayma suggests 2 updates to your public profile."
    assert docs[0]["read"] is False
    # A stable id reuses one doc key, not an auto-generated one.
    keys = [k for k in db.store if k[:3] == ("users", "u1", "notifications")]
    assert keys == [("users", "u1", "notifications", "profile_suggestions_pending")]


def test_without_dedup_id_two_fires_stack_two_docs(monkeypatch):
    db = _Db({("users", "u1"): {}})
    monkeypatch.setattr(nd, "_push", lambda *a, **k: False)
    _run(nd.dispatch(db, "u1", "mutual_match", fixed_preview="a"))
    _run(nd.dispatch(db, "u1", "mutual_match", fixed_preview="b"))
    assert len(_notif_docs(db, "u1")) == 2


def test_unknown_type_raises():
    with pytest.raises(ValueError):
        _run(nd.dispatch(_Db(), "u1", "bogus"))


def test_push_only_sends_without_centre_doc_cooldown_or_last_push(monkeypatch):
    recent = datetime.now(timezone.utc) - timedelta(seconds=5)
    db = _Db({("users", "u1"): {
        "fcm_tokens": ["tok-a"], "last_push_at": recent}})

    class _Resp:
        responses = [type("R", (), {"success": True, "exception": None})()]

    seen = {}
    monkeypatch.setattr(
        nd, "_deliver",
        lambda tokens, title, body, dl, notif_id="": seen.update(
            tokens=tokens, title=title, body=body, dl=dl,
            notif_id=notif_id) or _Resp(),
    )

    res = _run(nd.push_only(db, "u1", "ayma_reply", body="hello  there",
                            deep_link="chat"))

    assert res == {"muted": False, "pushed": True}
    # push_only writes no centre doc, so there is no notif_id to carry.
    assert seen == {"tokens": ["tok-a"], "title": "Ayma",
                    "body": "hello there", "dl": "chat", "notif_id": ""}
    assert _notif_docs(db, "u1") == []
    assert db.store[("users", "u1")]["last_push_at"] == recent


def test_push_only_respects_the_mute_pref(monkeypatch):
    db = _Db({
        ("users", "u1"): {"fcm_tokens": ["tok-a"]},
        ("users", "u1", "notification_prefs", "main"): {"ayma_reply": False},
    })
    monkeypatch.setattr(nd, "_deliver",
                        lambda *a: pytest.fail("muted category must not push"))
    res = _run(nd.push_only(db, "u1", "ayma_reply", body="hi"))
    assert res == {"muted": True, "pushed": False}


def test_push_only_without_tokens_does_nothing(monkeypatch):
    db = _Db({("users", "u1"): {}})
    monkeypatch.setattr(nd, "_deliver", lambda *a: pytest.fail("no push"))
    res = _run(nd.push_only(db, "u1", "ayma_reply", body="hi"))
    assert res == {"muted": False, "pushed": False, "no_tokens": True}


def test_deliver_requests_high_priority_for_android_and_apns(monkeypatch):
    captured = {}
    monkeypatch.setattr(
        nd.messaging, "send_each_for_multicast",
        lambda msg: captured.setdefault("msg", msg),
    )
    nd._deliver(["tok"], "Ayma", "hi", "chat")
    msg = captured["msg"]
    assert msg.android.priority == "high"
    assert msg.apns.headers["apns-priority"] == "10"
    assert msg.data == {"deep_link": "chat"}


def test_push_data_sends_data_only_bypasses_cooldown(monkeypatch):
    recent = datetime.now(timezone.utc)
    db = _Db({("users", "u1"): {"fcm_tokens": ["tok"], "last_push_at": recent}})

    class _Resp:
        responses = [type("R", (), {"success": True, "exception": None})()]

    seen = {}
    monkeypatch.setattr(nd, "_deliver", lambda *a: pytest.fail("notification"))
    monkeypatch.setattr(
        nd, "_deliver_data",
        lambda tokens, title, body, data: seen.update(
            title=title, body=body, data=data) or _Resp(),
    )

    res = _run(nd.dispatch(
        db, "u1", "dm_message", body="📷 Photo", title="Dillu",
        push_body="Photo", push_data={"type": "dm", "thread_id": "t"},
    ))

    assert res["pushed"] is True
    assert seen["title"] == "Dillu" and seen["body"] == "Photo"
    notif_id = next(
        k[-1] for k in db.store if k[:3] == ("users", "u1", "notifications")
    )
    assert seen["data"] == {
        "type": "dm", "thread_id": "t", "title": "Dillu", "body": "Photo",
        "notif_id": notif_id}
    assert db.store[("users", "u1")]["last_push_at"] == recent


def test_push_data_still_respects_mute(monkeypatch):
    db = _Db({("users", "u1", "notification_prefs", "main"): {"dm_message": False}})
    monkeypatch.setattr(nd, "_deliver_data", lambda *a: pytest.fail("no push"))
    res = _run(nd.dispatch(db, "u1", "dm_message", push_data={"type": "dm"}))
    assert res["muted"] is True


def test_deliver_sends_notification_payload_on_heads_up_channel(monkeypatch):
    """A `notification`-payload push carries title/body and is pinned to the
    IMPORTANCE_HIGH Android channel so it pops as a heads-up alert (the founder
    bug: pushes were landing silently / not at all)."""
    sent = {}
    monkeypatch.setattr(
        nd.messaging, "send_each_for_multicast",
        lambda msg: sent.update(msg=msg) or type("R", (), {"responses": []})(),
    )

    nd._deliver(["tok-a"], "Ayma", "Your web search is ready", "chat")

    msg = sent["msg"]
    assert msg.notification.title == "Ayma"
    assert msg.notification.body == "Your web search is ready"
    assert msg.android.priority == "high"
    assert msg.android.notification.channel_id == nd.ANDROID_DEFAULT_CHANNEL
    # iOS still gets an audible alert at APNs priority 10.
    assert msg.apns.headers["apns-priority"] == "10"


def test_deliver_data_is_android_data_only_and_ios_mutable_for_avatar(monkeypatch):
    """A DM push is Android data-only (the native service draws the chat-style
    notification with the sender's avatar) and carries an APNs alert marked
    ``mutable-content: 1`` so the iOS Notification Service Extension can
    download ``sender_photo_url`` and attach it. The avatar URL and sender
    identity ride in the data payload, copied into APNs ``userInfo``."""
    sent = {}
    monkeypatch.setattr(
        nd.messaging, "send_each_for_multicast",
        lambda msg: sent.update(msg=msg) or type("R", (), {"responses": []})(),
    )

    nd._deliver_data(
        ["tok-a"], "Dillu", "hey there",
        {"type": "dm", "thread_id": "t", "sender_photo_url": "https://x/p.jpg"},
    )

    msg = sent["msg"]
    # Android: data-only, no notification payload (native service renders it).
    assert msg.notification is None
    assert msg.android.notification is None
    assert msg.android.priority == "high"
    assert msg.data["sender_photo_url"] == "https://x/p.jpg"
    assert msg.data["type"] == "dm"
    # iOS: alert + mutable-content so the service extension can attach the image.
    assert msg.apns.headers["apns-priority"] == "10"
    assert msg.apns.payload.aps.mutable_content is True
    assert msg.apns.payload.aps.alert.title == "Dillu"
    assert msg.apns.payload.aps.alert.body == "hey there"
