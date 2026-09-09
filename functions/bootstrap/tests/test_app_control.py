"""Voice-only screen-awareness / navigation tools (``skills.app_control``).
The ``/voice/context`` endpoint they read is covered by
``test_voice_context_endpoint``."""

from __future__ import annotations

import time

import skills
from skills import app_control


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

    def stream(self):
        # Only used for the roster scan: yield a snap per users/<id> doc.
        seen = []
        for k in list(self.store):
            if len(k) == len(self.key) + 1 and k[: len(self.key)] == self.key:
                s = _Snap(self.store[k])
                s.id = k[-1]
                seen.append(s)
        return iter(seen)


class _Db:
    def __init__(self, store=None):
        self.store = store or {}

    def collection(self, name):
        return _Col(self.store, (name,))

    def seed_user(self, uid, name):
        self.store[("users", uid)] = {"x": 1}
        self.store[("users", uid, "profile", "main")] = {"name": name}


# --- current_screen -----------------------------------------------------

def _current_screen(db):
    return app_control._bind_current_screen(db, "me")


def test_current_screen_empty_when_no_mirror():
    assert _current_screen(_Db())() == "The user hasn't opened anything specific."


def test_current_screen_reads_a_fresh_profile_mirror():
    db = _Db()
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "profile",
        "subject_name": "Jordan Lee",
        "updated_at": _FreshTs(),
    }
    assert _current_screen(db)() == "The user is looking at Jordan Lee's profile."


def test_current_screen_names_the_ayma_chat_screen():
    db = _Db()
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "ayma",
        "updated_at": _FreshTs(),
    }
    assert (
        _current_screen(db)()
        == "The user is on the main chat screen with you."
    )


def test_current_screen_handles_a_profile_with_no_name_yet():
    db = _Db()
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "profile",
        "subject_uid": "u-someone",
        "updated_at": _FreshTs(),
    }
    assert _current_screen(db)() == "The user is looking at someone's profile."


def test_current_screen_uses_a_bare_subject_uid():
    db = _Db()
    db.store[("users", "me", "voice_context", "current")] = {
        "subject_uid": "u-someone",
        "updated_at": _FreshTs(),
    }
    assert _current_screen(db)() == "The user is looking at someone's profile."


def test_current_screen_tolerates_a_multi_minute_call_on_one_screen():
    # The client heartbeats every ~45s; a beat or two can still be missed
    # without the mirror going "blank".
    db = _Db()
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "ayma",
        "updated_at": _AgeTs(200),
    }
    assert (
        _current_screen(db)()
        == "The user is on the main chat screen with you."
    )


def test_current_screen_reports_explore_query():
    db = _Db()
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "explore",
        "note": "hiking",
        "updated_at": _FreshTs(),
    }
    assert (
        _current_screen(db)()
        == "The user is on the Explore screen, searching for 'hiking'."
    )


def test_current_screen_ignores_a_stale_mirror():
    db = _Db()
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "profile",
        "subject_name": "Jordan Lee",
        "updated_at": _StaleTs(),
    }
    assert _current_screen(db)() == "The user hasn't opened anything specific."


class _FreshTs:
    def timestamp(self):
        return time.time()


class _StaleTs:
    def timestamp(self):
        return time.time() - 999


class _AgeTs:
    def __init__(self, seconds):
        self._seconds = seconds

    def timestamp(self):
        return time.time() - self._seconds


# --- open_screen / search_explore / open_profile ----------------------

def test_open_screen_queues_a_navigate_command():
    db = _Db()
    out = app_control._bind_open_screen(db, "me")("matches")
    assert out == "Opening Matches."
    cmd = db.store[("users", "me", "app_commands", "pending")]
    assert cmd["action"] == "navigate" and cmd["screen"] == "matches"


def test_open_screen_rejects_an_unknown_screen():
    db = _Db()
    out = app_control._bind_open_screen(db, "me")("spaceship")
    assert "I can open" in out
    assert ("users", "me", "app_commands", "pending") not in db.store


def test_search_explore_queues_the_query():
    db = _Db()
    out = app_control._bind_search_explore(db, "me")("people who love hiking")
    assert out == "Searching Explore for people who love hiking."
    cmd = db.store[("users", "me", "app_commands", "pending")]
    assert cmd["action"] == "search_explore"
    assert cmd["query"] == "people who love hiking"


def test_search_explore_needs_a_query():
    db = _Db()
    assert app_control._bind_search_explore(db, "me")("  ") == (
        "Tell me what to search Explore for."
    )


def test_open_profile_resolves_a_name_and_queues_the_uid():
    db = _Db()
    db.seed_user("me", "Me")
    db.seed_user("u-jordan", "Jordan Lee")
    db.seed_user("u-sam", "Sam Fox")
    out = app_control._bind_open_profile(db, "me")("jordan")
    assert out == "Opening Jordan Lee's profile."
    cmd = db.store[("users", "me", "app_commands", "pending")]
    assert cmd == {**cmd, "action": "open_profile", "uid": "u-jordan"}


def test_open_profile_reports_when_nobody_matches():
    db = _Db()
    db.seed_user("me", "Me")
    db.seed_user("u-sam", "Sam Fox")
    out = app_control._bind_open_profile(db, "me")("Taylor")
    assert out == "I couldn't find someone called Taylor in the app."
    assert ("users", "me", "app_commands", "pending") not in db.store


# --- registry wiring --------------------------------------------------

def test_voice_tools_are_not_in_the_text_declarations():
    text = {d["name"] for d in skills.session_tool_declarations()}
    voice_only = {s.name for s in app_control.VOICE_SKILLS}
    assert voice_only.isdisjoint(text)
    assert voice_only == {
        "current_screen", "open_screen", "search_explore", "open_profile"
    }


def test_make_livekit_tools_includes_the_voice_tools(monkeypatch):
    captured = []

    def _fake_function_tool(fn, *, name, description):
        captured.append(name)
        return (name, fn)

    fake_mod = type("m", (), {"function_tool": _fake_function_tool})
    monkeypatch.setitem(
        __import__("sys").modules, "livekit", type("l", (), {})()
    )
    monkeypatch.setitem(
        __import__("sys").modules, "livekit.agents", fake_mod
    )
    skills.make_livekit_tools(_Db(), "me")
    assert {
        "current_screen", "open_screen", "search_explore", "open_profile"
    } <= set(captured)
