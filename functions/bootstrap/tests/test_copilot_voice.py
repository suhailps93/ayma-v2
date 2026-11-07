"""Co-pilot voice bridge (copilot_locate / copilot_copy_draft tools).

The tools queue one app command and relay the client's ack: a spoken
report on success, an honest reason line on failure. The fake Firestore
below mirrors test_app_control's harness, with an ack store that can
carry a payload (result / reason), like the real client does.
"""

import asyncio

import gemini  # noqa: F401  (import order: matches test_copilot.py — \
# importing main first trips a db namespace collision in skills.remember)
import main
from skills import app_control
from skills import app_control_copilot
from skills import app_control_mirror


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


# --- fake Firestore -------------------------------------------------------


class _Snap:
    def __init__(self, data):
        self._data = data
        self.exists = data is not None
        self.id = ""

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


class _Db:
    def __init__(self, store=None):
        self.store = {} if store is None else store

    def collection(self, name):
        return _Col(self.store, (name,))


_PENDING = ("users", "me", "app_commands", "pending")
_ACK = ("users", "me", "app_commands", "ack")


class _AckStore(dict):
    """Acks every queued command immediately with a configured payload
    (``None`` = a dead client that never acks)."""

    def __init__(self, ack):
        super().__init__()
        self._ack = ack

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if key == _PENDING and isinstance(value, dict) and value.get("id"):
            if self._ack is not None:
                super().__setitem__(_ACK, {"id": value["id"], **self._ack})


def _db(ack):
    return _Db(_AckStore(ack))


def _fast(monkeypatch):
    monkeypatch.setattr(app_control_copilot, "_COPILOT_ACK_TIMEOUT_SECONDS", 0.05)
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", 0.01)


# --- copilot_locate -------------------------------------------------------


def test_locate_queues_goal_and_relays_the_client_report():
    report = (
        'The highlight ring is now drawn over "Reply". '
        'Say this guidance aloud: "Tap the reply box."'
    )
    db = _db({"ok": True, "result": report})
    out = _run(app_control._bind_copilot_locate(db, "me")("reply to this"))
    assert out == report
    cmd = db.store[_PENDING]
    assert cmd["action"] == "copilot_locate"
    assert cmd["goal"] == "reply to this"


def test_locate_without_a_goal_queues_nothing():
    db = _db({"ok": True, "result": "x"})
    out = _run(app_control._bind_copilot_locate(db, "me")("   "))
    assert "Ask the user" in out
    assert _PENDING not in db.store


def test_locate_not_sharing_tells_the_user_how_to_start_it():
    db = _db({"ok": False, "reason": "not_sharing"})
    out = _run(app_control._bind_copilot_locate(db, "me")("send this"))
    assert "NOT on" in out
    assert "Start sharing" in out


def test_locate_secure_paused_is_an_honest_black_screen_line():
    db = _db({"ok": False, "reason": "secure_paused"})
    out = _run(app_control._bind_copilot_locate(db, "me")("pay this"))
    assert "protected screen" in out
    assert "black" in out


def test_locate_no_ack_is_an_honest_unreachable_line(monkeypatch):
    _fast(monkeypatch)
    db = _db(None)  # nothing ever acks
    out = _run(app_control._bind_copilot_locate(db, "me")("send this"))
    assert "did NOT answer" in out


def test_tools_are_registered_for_text_and_voice():
    command_names = {s.name for s in app_control.COMMAND_SKILLS}
    voice_names = {s.name for s in app_control.VOICE_SKILLS}
    assert "copilot_locate" in command_names
    assert "copilot_copy_draft" in command_names
    assert "copilot_locate" in voice_names
    assert "copilot_copy_draft" in voice_names


# --- copilot_copy_draft ---------------------------------------------------


def test_copy_draft_ok_names_the_paste_step():
    db = _db({"ok": True})
    out = _run(app_control._bind_copilot_copy_draft(db, "me")())
    assert db.store[_PENDING]["action"] == "copilot_copy_draft"
    assert "clipboard" in out
    assert "long-press" in out


def test_copy_draft_without_a_draft_points_back_to_locate():
    db = _db({"ok": False, "reason": "no_draft"})
    out = _run(app_control._bind_copilot_copy_draft(db, "me")())
    assert "copilot_locate" in out


# --- voice context flag ---------------------------------------------------


def test_current_screen_describe_names_the_active_share():
    out = app_control_mirror._describe(
        {"screen": "", "route": "", "copilot_share": "active"}
    )
    assert "copilot_locate" in out
    assert "ACTIVE" in out


def test_voice_context_request_carries_copilot_share():
    req = main.VoiceContextRequest(copilot_share="active")
    assert req.copilot_share == "active"
    assert main.VoiceContextRequest().copilot_share == ""
