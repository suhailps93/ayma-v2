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
        self._filter = None

    def document(self, doc_id):
        return _Doc(self.store, (*self.key, doc_id))

    def where(self, field, _op, value):
        # Minimal stand-in for Firestore's ``.where`` — enough for
        # ``public_profile._public_pages``'s ``visibility == "public"`` scan.
        self._filter = (field, value)
        return self

    def stream(self):
        seen = []
        d = len(self.key)
        for k in list(self.store):
            if len(k) == d + 1 and k[:d] == self.key:
                data = self.store[k] or {}
                if self._filter and data.get(self._filter[0]) != self._filter[1]:
                    continue
                s = _Snap(data)
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

    def seed_profile(self, uid, **fields):
        self.store[("users", uid)] = {"x": 1}
        self.store[("users", uid, "profile", "main")] = dict(fields)

    def seed_wiki_page(self, uid, page_id, *, title, body, page_type="about"):
        self.store[("users", uid, "wiki_pages", page_id)] = {
            "visibility": "public",
            "page_type": page_type,
            "title": title,
            "ai_body": body,
        }


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


def test_current_screen_gives_a_real_profile_briefing_when_subject_uid_resolves():
    # The bug this fixes: voice used to hand Ayma a bare name for a profile
    # screen even though the doc carries subject_uid — she'd then fabricate
    # details instead of using the person's actual wiki bio. Text chat's
    # ``_viewing_profile_context`` briefing (moved to
    # ``public_profile._viewing_profile_context``) should now back voice too.
    db = _Db()
    db.seed_profile(
        "u-dillu", name="Dillu Renee", location="Austin", birthdate="1994-01-01"
    )
    db.seed_wiki_page(
        "u-dillu", "about", title="About", body="Grew up sailing on the coast."
    )
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "profile",
        "subject_name": "Dillu Renee",
        "subject_uid": "u-dillu",
        "updated_at": _FreshTs(),
    }
    out = _current_screen(db)()
    assert "Dillu Renee" in out
    assert "Austin" in out
    assert "Grew up sailing on the coast." in out


def test_current_screen_falls_back_when_subject_uid_has_no_profile():
    # subject_uid present but it doesn't resolve to a real, named profile —
    # must not crash, and must still say something sensible.
    db = _Db()
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "profile",
        "subject_uid": "u-ghost",
        "updated_at": _FreshTs(),
    }
    out = _current_screen(db)()
    assert "profile" in out
    assert out  # non-empty, no exception raised


def test_current_screen_match_report_branch_is_unchanged():
    # The rich-briefing fetch is scoped to screen == "profile" — a
    # match_report with the same subject_uid still gets the plain _describe
    # line, unchanged.
    db = _Db()
    db.seed_profile("u-dillu", name="Dillu Renee")
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "match_report",
        "subject_name": "Dillu Renee",
        "subject_uid": "u-dillu",
        "updated_at": _FreshTs(),
    }
    assert (
        _current_screen(db)()
        == "The user is looking at the match report for Dillu Renee."
    )


def test_current_screen_dm_branch_is_unchanged():
    db = _Db()
    db.seed_profile("u-dillu", name="Dillu Renee")
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "dm",
        "subject_name": "Dillu Renee",
        "subject_uid": "u-dillu",
        "updated_at": _FreshTs(),
    }
    assert (
        _current_screen(db)()
        == "The user is on their message thread with Dillu Renee."
    )


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
