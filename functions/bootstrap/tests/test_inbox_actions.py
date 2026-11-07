"""Notification filter tool (founder feedback item 11; staging port
2026-11-07): the tool queues the matching client command and reports
only what the client's ack proves. The bulk inbox actions stay
v2-only — only the filter was ordered into staging. The client
behaviour itself is covered by the Dart tests
(``inbox_actions_test.dart``)."""

from __future__ import annotations

import asyncio

from skills import app_control

_PENDING = ("users", "me", "app_commands", "pending")
_ACK = ("users", "me", "app_commands", "ack")

_RESULTS = {
    "set_notification_filter": "Showing Unread notifications.",
}


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


class _Snap:
    def __init__(self, data):
        self._data = data
        self.exists = data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _Doc:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def collection(self, name):
        return _Col(self.store, (*self.key, name) if self.key else (name,))

    def get(self):
        return _Snap(self.store.get(self.key))

    def set(self, patch, merge=False):
        cur = self.store.get(self.key) if merge else None
        self.store[self.key] = {**(cur or {}), **patch}

    def delete(self):
        self.store.pop(self.key, None)


class _Col:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _Doc(self.store, (*self.key, doc_id))


class _AckStore(dict):
    """A healthy client: acks each queued command at once with the
    result line that command would produce. ``ok=False`` plays a
    client that could not run it."""

    def __init__(self, *a, ok=True, **k):
        super().__init__(*a, **k)
        self._ok = ok

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if key == _PENDING and isinstance(value, dict) and value.get("id"):
            if self._ok:
                ack = {
                    "id": value["id"],
                    "ok": True,
                    "result": _RESULTS[value["action"]],
                }
            else:
                ack = {
                    "id": value["id"],
                    "ok": False,
                    "reason": "That inbox action failed.",
                }
            super().__setitem__(_ACK, ack)


class _Db:
    def __init__(self, store=None):
        self.store = store if store is not None else _AckStore()

    def collection(self, name):
        return _Col(self.store, (name,))


def _queued(db):
    return db.store.get(_PENDING)


def test_set_notification_filter_normalises_phrasings():
    cases = {
        "unread": "unread",
        "Unread only": "unread",
        "new matches": "matches",
        "check-ins": "ayma",
        "report": "reports",
        "profile suggestions": "suggestions",
        "": "all",
        "everything": "all",
    }
    for said, key in cases.items():
        db = _Db()
        _run(app_control._bind_set_notification_filter(db, "me")(said))
        cmd = _queued(db)
        assert cmd["action"] == "set_notification_filter", said
        assert cmd["filter"] == key, said


def test_set_notification_filter_relays_the_ack_line():
    db = _Db()
    out = _run(app_control._bind_set_notification_filter(db, "me")("unread"))
    assert out == "Showing Unread notifications."


def test_set_notification_filter_refuses_an_unknown_filter():
    db = _Db()
    out = _run(app_control._bind_set_notification_filter(db, "me")("dm"))
    assert _queued(db) is None  # nothing queued for a filter that doesn't exist
    assert "no notification filter by that name" in out
    for key in ("all", "unread", "matches", "ayma", "reports", "suggestions"):
        assert key in out


def test_no_ack_is_an_honest_failure(monkeypatch):
    monkeypatch.setattr(app_control, "_INBOX_ACK_TIMEOUT_SECONDS", 0.05)
    db = _Db(store={})  # no client listening: nothing ever acks
    out = _run(app_control._bind_set_notification_filter(db, "me")("unread"))
    assert "did NOT change the notification filter" in out


def test_not_ok_ack_relays_the_reason():
    db = _Db(store=_AckStore(ok=False))
    out = _run(app_control._bind_set_notification_filter(db, "me")("unread"))
    assert out == "Not done: That inbox action failed."


def test_filter_tool_is_registered_everywhere():
    names = {s.declaration["name"] for s in app_control.COMMAND_SKILLS}
    voice = {s.declaration["name"] for s in app_control.VOICE_SKILLS}
    assert "set_notification_filter" in names
    assert "set_notification_filter" in voice
    # Staging split: the bulk inbox actions were NOT ported.
    bulk = {
        "mark_all_notifications_read",
        "clear_all_notifications",
        "mark_all_conversations_read",
    }
    assert not (bulk & names)
