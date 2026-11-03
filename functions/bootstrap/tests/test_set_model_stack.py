"""Ayma's self-service model-stack tools (``skills.set_model_stack``): set_brain /
set_voice_mode / set_realtime_model persist to the SAME ``profile/main`` fields
the "Ayma's models" screen writes, and reconnect_voice drives the client command.
"""

from __future__ import annotations

import asyncio

import pytest

import schema
import voice_catalog
from skills import app_control, session_tool_declarations, set_model_stack


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


# --- minimal tuple-keyed fake Firestore (mirrors tests/test_app_control.py) ---

_PROFILE = ("users", "u1", "profile", "main")
_PENDING = ("users", "u1", "app_commands", "pending")
_ACK = ("users", "u1", "app_commands", "ack")


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
        return _Col(self.store, (*self.key, name))

    def get(self):
        return _Snap(self.store.get(self.key))

    def set(self, patch, merge=False):
        cur = self.store.get(self.key) if merge else None
        self.store[self.key] = {**(cur or {}), **patch}
        # Auto-ack: a client that acks every pending command (ok = store.ok).
        if self.key[-1] == "pending" and getattr(self.store, "ok", None) is not None:
            ack = (*self.key[:-1], "ack")
            self.store[ack] = {"id": patch.get("id"), "ok": self.store.ok}


class _Col:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _Doc(self.store, (*self.key, doc_id))


class _Store(dict):
    def __init__(self, ok=None):
        super().__init__()
        self.ok = ok  # None = never acks; True/False = auto-ack with that ok


class _Db:
    def __init__(self, ok=None):
        self.store = _Store(ok=ok)

    def collection(self, name):
        return _Col(self.store, (name,))


@pytest.fixture(autouse=True)
def _offline_catalog(monkeypatch):
    """Force the voice catalog's documented offline fallback so realtime-model
    validation is deterministic and never hits the LiveKit gateway in tests."""
    monkeypatch.setattr(voice_catalog, "_fetch_livekit_models", lambda: None)
    voice_catalog.clear_cache()
    yield
    voice_catalog.clear_cache()


# --- set_brain ----------------------------------------------------------------


def test_set_brain_muse_persists_the_meta_vendor():
    db = _Db()
    msg = _run(set_model_stack._bind_set_brain(db, "u1")("Muse"))
    assert db.store[_PROFILE][schema.PF_AYMA_BRAIN_MODEL] == "meta"
    assert "Muse Spark" in msg and "saved" in msg


def test_set_brain_gemini_persists_gemini():
    db = _Db()
    _run(set_model_stack._bind_set_brain(db, "u1")("gemini"))
    assert db.store[_PROFILE][schema.PF_AYMA_BRAIN_MODEL] == "gemini"


def test_set_brain_open_weights_is_an_honest_redirect_not_a_write():
    db = _Db()
    msg = _run(set_model_stack._bind_set_brain(db, "u1")("open weights"))
    assert _PROFILE not in db.store  # nothing written
    assert "cascade" in msg.lower()


def test_set_brain_unknown_is_honest_and_writes_nothing():
    db = _Db()
    msg = _run(set_model_stack._bind_set_brain(db, "u1")("banana"))
    assert _PROFILE not in db.store
    assert "isn't an available brain" in msg


# --- set_voice_mode -----------------------------------------------------------


def test_set_voice_mode_cascade():
    db = _Db()
    _run(set_model_stack._bind_set_voice_mode(db, "u1")("cascade"))
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "cascade"


def test_set_voice_mode_text_alias_is_cascade():
    db = _Db()
    _run(set_model_stack._bind_set_voice_mode(db, "u1")("text mode"))
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "cascade"


def test_set_voice_mode_realtime_from_native_audio():
    db = _Db()
    _run(set_model_stack._bind_set_voice_mode(db, "u1")("native audio"))
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "realtime"


def test_set_voice_mode_unknown_is_honest():
    db = _Db()
    msg = _run(set_model_stack._bind_set_voice_mode(db, "u1")("telepathy"))
    assert _PROFILE not in db.store
    assert "isn't a voice mode" in msg


# --- set_realtime_model -------------------------------------------------------


def test_set_realtime_model_gemini_live_sets_model_and_realtime_mode():
    db = _Db()
    msg = _run(set_model_stack._bind_set_realtime_model(db, "u1")("Gemini Live"))
    assert db.store[_PROFILE][schema.PF_AYMA_REALTIME_MODEL] == "gemini-live"
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "realtime"
    assert "saved" in msg


def test_set_realtime_model_unknown_is_honest_and_writes_nothing():
    db = _Db()
    msg = _run(set_model_stack._bind_set_realtime_model(db, "u1")("hal 9000"))
    assert _PROFILE not in db.store
    assert "isn't an available realtime model" in msg


# --- reconnect_voice ----------------------------------------------------------


def test_reconnect_voice_confirms_when_the_client_acks_a_live_call():
    db = _Db(ok=True)  # a live call acks ok=True
    msg = _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert db.store[_PENDING]["action"] == "reconnect_voice"
    assert "Reconnecting now" in msg


def test_reconnect_voice_is_honest_when_no_call_is_live(monkeypatch):
    monkeypatch.setattr(app_control, "_ACK_TIMEOUT_SECONDS", 0.05)
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", 0.01)
    db = _Db(ok=False)  # client acks ok=False — nothing live to reconnect
    msg = _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert "next voice call" in msg


def test_reconnect_voice_is_one_shot_and_does_not_loop():
    # Founder 2026-11-03: the reconnected session is re-seeded with the
    # "reconnect" transcript and fired reconnect_voice AGAIN → infinite loop.
    # The one-shot cooldown guard must make the SECOND call (the fresh session's
    # re-fire) a no-op: no new reconnect command is queued.
    db = _Db(ok=True)
    msg1 = _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert db.store[_PENDING]["action"] == "reconnect_voice"
    assert "Reconnecting now" in msg1
    first_id = db.store[_PENDING]["id"]

    # The fresh session calls it again immediately — must NOT queue a reconnect.
    msg2 = _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert db.store[_PENDING]["id"] == first_id  # no new command queued
    assert "already reconnecting" in msg2.lower()
    assert "reconnecting now" not in msg2.lower()


def test_failed_reconnect_does_not_mark_so_a_later_reconnect_still_works(monkeypatch):
    # A genuinely-failed reconnect (no live call) must not arm the cooldown, so
    # it can't block — nor retry-storm — a real reconnect afterwards.
    monkeypatch.setattr(app_control, "_ACK_TIMEOUT_SECONDS", 0.05)
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", 0.01)
    db = _Db(ok=False)
    _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert (db.store.get(_PROFILE) or {}).get("ayma_reconnect_requested_at") is None


# --- registration -------------------------------------------------------------


@pytest.mark.parametrize("msg,expected", [
    # brain — both directions (the one-way bug was Meta->Gemini)
    ("change back to gemini", ("set_brain", "gemini")),
    ("switch to muse", ("set_brain", "meta")),
    ("switch my brain to gemini", ("set_brain", "gemini")),
    ("use the muse spark brain", ("set_brain", "meta")),
    ("change the brain to meta", ("set_brain", "meta")),
    # voice mode
    ("switch to cascade", ("set_voice_mode", "cascade")),
    ("use cascade mode", ("set_voice_mode", "cascade")),
    ("go to realtime mode", ("set_voice_mode", "realtime")),
    ("switch to text mode", ("set_voice_mode", "cascade")),
    # realtime model
    ("switch to gemini live", ("set_realtime_model", "gemini-live")),
])
def test_detect_stack_command_matches_clear_commands(msg, expected):
    assert set_model_stack.detect_stack_command(msg) == expected


@pytest.mark.parametrize("msg", [
    "I love how you use Gemini at work",   # brand mention, not a command
    "tell me about your brain",            # question, no change verb target
    "change the subject",                  # change verb, no stack target
    "set a reminder for tomorrow",         # unrelated 'set'
    "how does cascade work?",              # no change verb
    "",                                    # empty
])
def test_detect_stack_command_ignores_non_commands(msg):
    assert set_model_stack.detect_stack_command(msg) is None


def test_run_stack_command_writes_the_right_field_both_directions():
    db = _Db()
    msg = _run(set_model_stack.run_stack_command(db, "u1", "set_brain", "meta"))
    assert db.store[_PROFILE][schema.PF_AYMA_BRAIN_MODEL] == "meta"
    assert "Muse Spark" in msg
    # and back again — symmetry (the reported bug)
    msg2 = _run(set_model_stack.run_stack_command(db, "u1", "set_brain", "gemini"))
    assert db.store[_PROFILE][schema.PF_AYMA_BRAIN_MODEL] == "gemini"
    assert "Gemini" in msg2


def test_run_stack_command_voice_mode_and_realtime_model():
    db = _Db()
    _run(set_model_stack.run_stack_command(db, "u1", "set_voice_mode", "cascade"))
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "cascade"
    _run(set_model_stack.run_stack_command(db, "u1", "set_realtime_model", "gemini-live"))
    assert db.store[_PROFILE][schema.PF_AYMA_REALTIME_MODEL] == "gemini-live"


def test_all_four_tools_are_registered_for_text_and_voice():
    names = {d["name"] for d in session_tool_declarations()}
    assert {
        "set_brain", "set_voice_mode", "set_realtime_model", "reconnect_voice"
    } <= names
    # _REGISTRY feeds BOTH session_tool_declarations (text) and make_livekit_tools
    # (voice), so membership here is membership in the voice tool set too.
    import skills

    reg = {s.name for s in skills._REGISTRY}
    assert {
        "set_brain", "set_voice_mode", "set_realtime_model", "reconnect_voice"
    } <= reg
