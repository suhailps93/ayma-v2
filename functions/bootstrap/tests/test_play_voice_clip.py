"""``play_voice_clip`` (ACTION PARITY pilot, founder 2026-11-06): the tool
queues one ``play_voice_clip`` app command and reports only what the
client's ack proves — what is playing, and whether a live voice session
was disconnected to play it. The client's playback sequence itself is
covered by the Dart tests (``voice_clip_playback_test.dart``)."""

from __future__ import annotations

import asyncio

from skills import app_control

_PENDING = ("users", "me", "app_commands", "pending")
_ACK = ("users", "me", "app_commands", "ack")


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
    """A healthy client: acks each queued command at once, with a
    playback result. ``ok=False`` plays a client that could not play."""

    def __init__(self, *a, ok=True, voice_paused=False, **k):
        super().__init__(*a, **k)
        self._ok = ok
        self._voice_paused = voice_paused

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if key == _PENDING and isinstance(value, dict) and value.get("id"):
            if self._ok:
                ack = {
                    "id": value["id"],
                    "ok": True,
                    "result": "Playing your voice message now.",
                    "voice_paused": self._voice_paused,
                }
            else:
                ack = {
                    "id": value["id"],
                    "ok": False,
                    "reason": "There is no voice clip in this chat to play.",
                }
            super().__setitem__(_ACK, ack)


class _Db:
    def __init__(self, store=None):
        self.store = {} if store is None else store

    def collection(self, name):
        return _Col(self.store, (name,))


def _bind(db):
    return app_control._bind_play_voice_clip(db, "me")


def test_queues_a_play_command_and_reports_what_is_playing():
    db = _Db(_AckStore())
    out = _run(_bind(db)())
    assert out == "Playing your voice message now."
    cmd = db.store[_PENDING]
    assert cmd["action"] == "play_voice_clip"
    assert cmd["which"] == "latest"
    assert cmd["id"]


def test_selector_normalisation():
    for said, sent in [
        ("play it", "latest"),
        ("", "latest"),
        ("previous one", "latest"),  # unknown phrasing degrades to latest
        ("previous", "previous"),
        ("mine", "mine"),
        ("my voice message", "latest"),
        ("hers", "ayma"),
        ("ayma", "ayma"),
    ]:
        db = _Db(_AckStore())
        _run(_bind(db)(said))
        assert db.store[_PENDING]["which"] == sent, said


def test_voice_paused_result_is_relayed_from_the_ack():
    db = _Db(_AckStore(voice_paused=True))
    out = _run(_bind(db)("latest"))
    # The tool returns the client's own result line, which states the
    # disconnect; the tool adds nothing it cannot prove.
    assert out.startswith("Playing")


def test_no_ack_is_an_honest_failure(monkeypatch):
    monkeypatch.setattr(app_control, "_PLAYBACK_ACK_TIMEOUT_SECONDS", 0.05)
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", 0.01)
    db = _Db()  # no client ever acks
    out = _run(_bind(db)())
    assert "did NOT play" in out


def test_not_ok_ack_relays_the_clients_reason():
    db = _Db(_AckStore(ok=False))
    out = _run(_bind(db)())
    assert out.startswith("Not played:")
    assert "no voice clip" in out


def test_play_voice_clip_is_registered_in_both_tool_sets():
    import skills

    command_names = {s.name for s in app_control.COMMAND_SKILLS}
    assert "play_voice_clip" in command_names
    voice_names = {s.name for s in app_control.VOICE_SKILLS}
    assert "play_voice_clip" in voice_names
    text_names = {
        d["name"]
        for d in skills.session_tool_declarations(
            story=True, profile_edit=True, photo=True,
            deep_dive=True, appearance=True,
        )
    }
    assert "play_voice_clip" in text_names
