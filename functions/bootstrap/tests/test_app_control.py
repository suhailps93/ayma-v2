"""Voice-only screen-awareness / navigation tools (``skills.app_control``).
The ``/voice/context`` endpoint they read is covered by
``test_voice_context_endpoint``."""

from __future__ import annotations

import asyncio
import re
import time
from pathlib import Path

import pytest

import app_registry
import skills
from skills import app_control


def _run(coro):
    # Not asyncio.run(): that unsets the global event loop on exit, and this
    # file sorts before test_backfill_ops.py, whose legacy
    # `get_event_loop().run_until_complete` _run still needs it. A private
    # loop leaves global asyncio state untouched.
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
        self._filter = None

    def document(self, doc_id):
        return _Doc(self.store, (*self.key, doc_id))

    def where(self, field, op, value):
        # Minimal stand-in for Firestore's ``.where`` — enough for
        # ``public_profile._public_pages``'s ``visibility == "public"`` scan
        # and ``read_dm_thread``'s ``participants array_contains uid`` scan.
        self._filter = (field, op, value)
        return self

    def stream(self):
        seen = []
        d = len(self.key)
        for k in list(self.store):
            if len(k) == d + 1 and k[:d] == self.key:
                data = self.store[k] or {}
                if self._filter:
                    field, op, value = self._filter
                    actual = data.get(field)
                    if op == "array_contains":
                        if not isinstance(actual, list) or value not in actual:
                            continue
                    elif actual != value:
                        continue
                s = _Snap(data)
                s.id = k[-1]
                seen.append(s)
        return iter(seen)


class _Db:
    def __init__(self, store=None):
        self.store = {} if store is None else store

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
#
# Every command tool now waits for the client's ack (`app_commands/ack` with
# the command's own id) before claiming anything — see the module docstring's
# "Closing the loop". `_AckStore` plays a healthy client: the instant a
# pending command is written, it acks it. `_fast_acks` shrinks the wait so a
# no-client timeout test doesn't stall the suite.

_PENDING = ("users", "me", "app_commands", "pending")
_ACK = ("users", "me", "app_commands", "ack")


class _AckStore(dict):
    """Store that acks every queued command immediately (a healthy client),
    recording what it acked. ``ok`` lets a test play a client whose handler
    ran but couldn't execute the command."""

    def __init__(self, *a, ok=True, **k):
        super().__init__(*a, **k)
        self._ok = ok
        self.acked = []

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if key == _PENDING and isinstance(value, dict) and value.get("id"):
            self.acked.append(value["id"])
            super().__setitem__(_ACK, {"id": value["id"], "ok": self._ok})


def _acking_db(ok=True):
    return _Db(_AckStore(ok=ok))


def _fast_acks(monkeypatch, timeout=0.05, poll=0.01):
    monkeypatch.setattr(app_control, "_ACK_TIMEOUT_SECONDS", timeout)
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", poll)


def test_open_screen_queues_a_navigate_command_and_confirms_on_ack():
    db = _acking_db()
    out = _run(app_control._bind_open_screen(db, "me")("matches"))
    assert out == "navigated: screen=matches — the user is now on New matches."
    cmd = db.store[_PENDING]
    assert cmd["action"] == "navigate" and cmd["screen"] == "matches"
    assert cmd["path"] == "/matches"
    assert cmd["id"] and db.store.acked == [cmd["id"]]


def test_open_screen_reports_failure_when_the_app_never_acks(monkeypatch):
    _fast_acks(monkeypatch)
    db = _Db()  # no client — nothing ever acks
    out = _run(app_control._bind_open_screen(db, "me")("matches"))
    assert out == app_control._NOT_NAVIGATED
    assert "did NOT navigate" in out


def test_open_screen_reports_failure_on_a_not_ok_ack(monkeypatch):
    # The client answered, but its handler couldn't execute the command —
    # an ok=False ack is a failure, not a success.
    _fast_acks(monkeypatch)
    db = _acking_db(ok=False)
    out = _run(app_control._bind_open_screen(db, "me")("matches"))
    assert out == app_control._NOT_NAVIGATED


def test_open_screen_ignores_a_stale_ack_for_an_older_command(monkeypatch):
    # An ack doc left over from a previous command must not confirm this one
    # — only an ack carrying this command's own id counts.
    _fast_acks(monkeypatch)
    db = _Db()
    db.store[_ACK] = {"id": "old-command", "ok": True}
    out = _run(app_control._bind_open_screen(db, "me")("matches"))
    assert out == app_control._NOT_NAVIGATED


def test_open_screen_confirms_when_the_ack_arrives_mid_wait(monkeypatch):
    _fast_acks(monkeypatch, timeout=2.0, poll=0.01)
    db = _Db()

    async def _scenario():
        task = asyncio.ensure_future(
            app_control._bind_open_screen(db, "me")("matches")
        )
        await asyncio.sleep(0.05)  # tool is now polling for its ack
        cmd_id = db.store[_PENDING]["id"]
        db.store[_ACK] = {"id": cmd_id, "ok": True}
        return await task

    out = _run(_scenario())
    assert out.startswith("navigated: screen=matches")


def test_open_screen_rejects_an_unknown_screen():
    db = _Db()
    out = _run(app_control._bind_open_screen(db, "me")("spaceship"))
    assert "There is no 'spaceship' page" in out and "complete_profile" in out
    assert _PENDING not in db.store


def test_search_explore_queues_the_query(monkeypatch):
    _fast_acks(monkeypatch, timeout=0.5)
    monkeypatch.setattr(app_control, "_RESULT_TIMEOUT_SECONDS", 0.05)
    db = _acking_db()
    out = _run(
        app_control._bind_search_explore(db, "me")("people who love hiking")
    )
    # No results reported in time: navigation is still confirmed, and the
    # model is told the page hadn't loaded rather than that it is empty.
    assert out.startswith(
        "navigated: screen=explore, searching for people who love hiking."
    )
    assert "hadn't finished loading" in out
    cmd = db.store[_PENDING]
    assert cmd["action"] == "search_explore"
    assert cmd["query"] == "people who love hiking"


def test_search_explore_reports_failure_without_an_ack(monkeypatch):
    _fast_acks(monkeypatch)
    db = _Db()
    out = _run(app_control._bind_search_explore(db, "me")("hiking"))
    assert out == app_control._NOT_NAVIGATED


def test_search_explore_needs_a_query():
    db = _Db()
    assert _run(app_control._bind_search_explore(db, "me")("  ")) == (
        "Tell me what to search Explore for."
    )


def test_open_profile_resolves_a_name_and_queues_the_uid():
    db = _acking_db()
    db.seed_user("me", "Me")
    db.seed_user("u-jordan", "Jordan Lee")
    db.seed_user("u-sam", "Sam Fox")
    out = _run(app_control._bind_open_profile(db, "me")("jordan"))
    # Navigation line first, then the honest briefing on the person opened —
    # with no facts and no computed score it must flag that, not leave the
    # model free to talk them up (founder bug 2026-10-25).
    assert out.startswith(
        "navigated: screen=profile — Jordan Lee's profile is open."
    )
    assert "NO compatibility/match score has been computed" in out
    assert "do NOT have enough to judge compatibility" in out
    cmd = db.store[_PENDING]
    assert cmd == {**cmd, "action": "open_profile", "uid": "u-jordan"}


def test_open_profile_reports_failure_without_an_ack(monkeypatch):
    _fast_acks(monkeypatch)
    db = _Db()
    db.seed_user("me", "Me")
    db.seed_user("u-jordan", "Jordan Lee")
    out = _run(app_control._bind_open_profile(db, "me")("jordan"))
    assert out == app_control._NOT_NAVIGATED


def test_open_profile_reports_when_nobody_matches():
    db = _Db()
    db.seed_user("me", "Me")
    db.seed_user("u-sam", "Sam Fox")
    out = _run(app_control._bind_open_profile(db, "me")("Taylor"))
    assert out == "I couldn't find someone called Taylor in the app."
    assert _PENDING not in db.store


# --- registry wiring --------------------------------------------------

_COMMAND_TOOLS = {
    "open_screen", "search_explore", "open_profile", "open_message_thread",
    "open_match_report", "app_action", "account_action", "ui_action",
}


def test_text_declarations_carry_the_command_tools_but_not_current_screen():
    text = {d["name"] for d in skills.session_tool_declarations()}
    assert _COMMAND_TOOLS <= text
    assert "current_screen" not in text
    assert {s.name for s in app_control.VOICE_SKILLS} == (
        _COMMAND_TOOLS | {"current_screen"}
    )


def test_text_tool_fns_bind_the_command_tools():
    fns = skills.make_session_tool_fns(_Db(), "me")
    assert _COMMAND_TOOLS <= set(fns)
    assert "current_screen" not in fns


def test_command_tool_descriptions_are_not_voice_only():
    for s in app_control.COMMAND_SKILLS:
        assert "VOICE ONLY" not in s.declaration["description"]


def test_text_app_action_runs_the_ack_protocol():
    db = _acking_db()
    fn = skills.make_session_tool_fns(db, "me")["app_action"]
    assert _run(fn("dark_mode")) == "Switched you to dark mode."
    assert db.store[_PENDING]["name"] == "dark_mode"


def test_text_app_action_is_honest_when_the_app_never_acks(monkeypatch):
    _fast_acks(monkeypatch)
    fn = skills.make_session_tool_fns(_Db(), "me")["app_action"]
    assert _run(fn("dark_mode")) == app_control._NOT_APPLIED


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
        "current_screen", "open_screen", "search_explore", "open_profile",
        "open_message_thread", "open_match_report", "app_action",
        "account_action",
    } <= set(captured)


# --- open_screen: expanded destination coverage ------------------------

def test_open_screen_covers_every_nested_profile_and_settings_screen():
    # The bug this fixes: Ayma used to claim she could only reach 6 top-level
    # tabs (explore/messages/profile/matches/story/settings) and didn't know
    # she could already open Skills. Every real nested screen from the
    # Profile hub and Settings must be a valid destination now.
    for screen in (
        "ayma", "explore", "messages", "profile", "matches", "story",
        "settings", "ayma_settings", "profile_details", "photos", "skills",
        "voice_preference", "credits", "accent_color", "notifications",
        "notification_settings", "feedback", "terms", "privacy",
        "release_notes",
    ):
        db = _acking_db()
        out = _run(app_control._bind_open_screen(db, "me")(screen))
        assert out.startswith(f"navigated: screen={screen}"), f"{screen}: {out}"
        cmd = db.store[_PENDING]
        assert cmd["screen"] == screen


def test_open_screen_still_rejects_deliberately_excluded_screens():
    # Auth/onboarding, the deliberately-hidden Google/Instagram linking
    # screens and the developer panel stay unreachable, with an honest answer.
    for screen in ("sign-in", "google_account", "instagram", "developer panel"):
        db = _Db()
        out = _run(app_control._bind_open_screen(db, "me")(screen))
        assert out.startswith(("There is no", "Not available")), out
        assert _PENDING not in db.store


def test_open_screen_opens_the_profile_completeness_card():
    # Founder bug (2026-10-25): "open the profile completeness card" on the You
    # tab got "there isn't a specific page for profile completeness".
    for words in (
        "profile completeness", "complete_profile",
        "Your profile is 59% complete", "the completeness card",
    ):
        db = _acking_db()
        out = _run(app_control._bind_open_screen(db, "me")(words))
        assert out.startswith("navigated: screen=complete_profile"), words
        assert db.store[_PENDING]["path"] == "/complete-profile"


def test_open_screen_resolves_friendly_aliases():
    for words, key, path in (
        ("my public profile", "my_public_profile", "/profile/me/public"),
        ("credits", "credits", "/profile/plan"),
        ("plan", "credits", "/profile/plan"),
        ("buy credits", "credits", "/profile/plan"),
        ("invite friends", "invite_friends", "/invite-friends"),
        ("delete my account", "delete_account", "/settings/delete-account"),
        ("You tab", "profile", "/profile"),
    ):
        db = _acking_db()
        out = _run(app_control._bind_open_screen(db, "me")(words))
        assert out.startswith(f"navigated: screen={key}"), (words, out)
        assert db.store[_PENDING]["path"] == path


def test_open_screen_is_honest_about_things_that_do_not_exist():
    out = _run(app_control._bind_open_screen(_Db(), "me")("app language"))
    assert out.startswith("Not available:") and "English" in out


def test_open_screen_opens_the_consent_page_without_touching_the_gate():
    db = _acking_db()
    out = _run(app_control._bind_open_screen(db, "me")("face matching consent"))
    assert out.startswith("navigated: screen=biometric_consent")
    assert db.store[_PENDING]["path"] == "/settings/biometric-consent"


def test_open_screen_my_web_research_falls_back_to_skills_without_a_report():
    db = _acking_db()
    out = _run(app_control._bind_open_screen(db, "me")("my_web_research"))
    assert out.startswith("navigated: screen=my_web_research")
    assert db.store[_PENDING]["path"] == "/skills"


def test_open_match_report_opens_a_scored_pair():
    db = _acking_db()
    db.seed_user("me", "Me")
    db.seed_user("u-jordan", "Jordan Lee")
    db.store[("matches", "me__u-jordan")] = {"score": 80}
    out = _run(app_control._bind_open_match_report(db, "me")("Jordan"))
    assert out.startswith("navigated: screen=match_report")
    assert db.store[_PENDING]["path"] == "/match/me__u-jordan"


def test_open_match_report_says_when_there_is_no_report():
    db = _Db()
    db.seed_user("me", "Me")
    db.seed_user("u-jordan", "Jordan Lee")
    out = _run(app_control._bind_open_match_report(db, "me")("Jordan"))
    assert "no match report" in out
    assert _PENDING not in db.store


# --- open_message_thread ------------------------------------------------

def test_open_message_thread_resolves_an_existing_conversation():
    db = _acking_db()
    db.seed_user("me", "Me")
    db.seed_user("u-jordan", "Jordan Lee")
    db.store[("dm_threads", "me__u-jordan")] = {
        "participants": ["me", "u-jordan"]
    }
    out = _run(app_control._bind_open_message_thread(db, "me")("jordan"))
    assert out == "navigated: screen=dm — the conversation with jordan is open."
    cmd = db.store[_PENDING]
    assert cmd == {**cmd, "action": "open_dm_thread", "uid": "u-jordan"}


def test_open_message_thread_reports_failure_without_an_ack(monkeypatch):
    _fast_acks(monkeypatch)
    db = _Db()
    db.seed_user("me", "Me")
    db.seed_user("u-jordan", "Jordan Lee")
    db.store[("dm_threads", "me__u-jordan")] = {
        "participants": ["me", "u-jordan"]
    }
    out = _run(app_control._bind_open_message_thread(db, "me")("jordan"))
    assert out == app_control._NOT_NAVIGATED


def test_open_message_thread_reports_when_no_conversation_exists():
    db = _Db()
    db.seed_user("me", "Me")
    db.seed_user("u-jordan", "Jordan Lee")
    out = _run(app_control._bind_open_message_thread(db, "me")("jordan"))
    assert "couldn't find an existing conversation" in out
    assert _PENDING not in db.store


# --- app_action -----------------------------------------------------------

def test_app_action_queues_a_known_action():
    db = _acking_db()
    out = _run(app_control._bind_app_action(db, "me")("dark_mode"))
    assert out == "Switched you to dark mode."
    cmd = db.store[_PENDING]
    assert cmd == {**cmd, "action": "app_action", "name": "dark_mode"}


def test_app_action_reports_failure_without_an_ack(monkeypatch):
    _fast_acks(monkeypatch)
    db = _Db()
    out = _run(app_control._bind_app_action(db, "me")("dark_mode"))
    assert out == app_control._NOT_APPLIED


def test_app_action_rejects_an_unknown_action():
    db = _Db()
    out = _run(app_control._bind_app_action(db, "me")("log_out"))
    assert "account_action" in out
    assert _PENDING not in db.store


def _patch_appearance_run(monkeypatch, rid="rpt-9"):
    """Make run_appearance_report runnable in-process: stub the credit check
    and the engine so calling the tool returns the real ``[appearance:<id>]``
    card marker. Returns a dict the fake engine fills with what it was asked."""
    import token_ledger
    from skills import run_appearance_report as rar

    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    seen: dict = {}

    async def _fake_run(db, uid, **kw):
        seen.update(uid=uid, source=kw.get("source"))
        return {"id": rid}

    monkeypatch.setattr(rar.engine, "run_appearance", _fake_run)
    return seen


def _patch_deep_dive_run(monkeypatch):
    """Make a self web-research re-run runnable in-process, returning the
    ``[deep_dive:<id>]`` card marker. Returns a dict the fake engine fills."""
    import skill_memory
    import skill_runs
    import token_ledger
    from skills import deep_dive as dd

    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    seen: dict = {}

    async def _fake_run(full_name, db=None, uid=None, context="", is_self=False):
        seen.update(name=full_name, is_self=is_self)
        return {"confidence": "ok", "facts": ["x"], "summary": "s"}

    monkeypatch.setattr(dd.engine, "profile_full_name", lambda db, uid: "Sam Doe")
    monkeypatch.setattr(dd.engine, "profile_dive_context", lambda db, uid, n: "")
    monkeypatch.setattr(dd.engine, "run", _fake_run)
    monkeypatch.setattr(dd.engine, "teaser", lambda d: "Here's what I found")
    monkeypatch.setattr(dd.engine, "dive_report_id", lambda name: "dive-1")
    monkeypatch.setattr(skill_memory, "save_web_findings", lambda db, uid, d: None)
    monkeypatch.setattr(skill_runs, "record", lambda *a, **k: None)
    return seen


def test_app_action_rerun_report_executes_the_report(monkeypatch):
    # Founder bug 2026-10-28: "rerun the appearance report" routed to app_action
    # used to DEFLECT ("use the run_appearance_report tool"), never re-running.
    # Now the app-driving path runs it and returns the real card marker.
    seen = _patch_appearance_run(monkeypatch, "rpt-aa")
    db = _Db()
    for phrase in ("rerun appearance report", "regenerate appearance report",
                   "recalculate my appearance report"):
        out = _run(app_control._bind_app_action(db, "me")(phrase))
        assert "[appearance:rpt-aa]" in out, phrase
        assert "tool" not in out  # not the old deflection pointer
    assert seen["source"] == "chat_tool"
    assert _PENDING not in db.store  # a run, not a queued navigate/app_action


def test_open_screen_rerun_appearance_executes_the_report(monkeypatch):
    # The same re-run routed to open_screen must RUN the report, not open the
    # existing one (its words also match the my_appearance destination).
    seen = _patch_appearance_run(monkeypatch, "rpt-os")
    db = _Db()
    for phrase in ("rerun appearance report", "regenerate appearance report",
                   "recalculate my appearance report", "refresh appearance report"):
        out = _run(app_control._bind_open_screen(db, "me")(phrase))
        assert "[appearance:rpt-os]" in out, phrase
        assert "did NOT navigate" not in out
    assert seen["source"] == "chat_tool"
    assert _PENDING not in db.store  # no navigate command queued


def test_open_screen_bare_appearance_report_still_opens(monkeypatch):
    # A plain "appearance report" (no re-run verb) stays an OPEN — it navigates
    # to the existing report and never silently re-runs.
    seen = _patch_appearance_run(monkeypatch)
    db = _acking_db()
    out = _run(app_control._bind_open_screen(db, "me")("appearance report"))
    assert out.startswith("navigated: screen=my_appearance")
    assert "source" not in seen  # run_appearance was never called


def test_rerun_web_research_executes_deep_dive(monkeypatch):
    # The web-research re-run must execute too (a self deep dive), via both
    # open_screen and app_action.
    db = _Db()
    for tool in ("_bind_open_screen", "_bind_app_action"):
        seen = _patch_deep_dive_run(monkeypatch)
        out = _run(getattr(app_control, tool)(db, "me")("rerun web research"))
        assert "[deep_dive:dive-1]" in out, tool
        assert seen["is_self"] is True, tool


def test_run_appearance_report_skill_is_registered_and_triggers(monkeypatch):
    # The chat/voice tool set must carry run_appearance_report, and calling it
    # must actually drive appearance.run_appearance (the server re-run).
    import token_ledger
    from skills import run_appearance_report as rar

    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    seen = {}

    async def _fake_run(db, uid, **kw):
        seen.update(uid=uid, kw=kw)
        return {"id": "app-123"}

    monkeypatch.setattr(rar.engine, "run_appearance", _fake_run)

    fns = skills.make_session_tool_fns(_Db(), "me")
    assert "run_appearance_report" in fns
    out = _run(fns["run_appearance_report"]())
    assert "[appearance:app-123]" in out
    assert seen["uid"] == "me"
    assert seen["kw"]["source"] == "chat_tool"


def test_run_appearance_report_reports_out_of_credits(monkeypatch):
    import token_ledger
    from skills import run_appearance_report as rar

    def _capped(uid):
        raise token_ledger.TokenCapExceeded()

    monkeypatch.setattr(token_ledger, "check", _capped)
    out = _run(rar._bind(_Db(), "me")())
    assert "out of credits" in out.lower()


# --- accent colour ---------------------------------------------------------

def test_app_action_accent_color_applies_a_brown_hex_exactly():
    db = _acking_db()
    out = _run(app_control._bind_app_action(db, "me")("accent_color", "#8b5a2b"))
    assert "#8B5A2B" in out
    assert db.store[_PENDING]["name"] == "accent_color"
    assert db.store[_PENDING]["value"] == "#8B5A2B"


def test_resolve_accent_keeps_any_valid_hex_without_snapping():
    assert app_control._resolve_accent("#abcdef") == "#ABCDEF"
    assert app_control._resolve_accent("6F4E37") == "#6F4E37"
    assert app_control._resolve_accent("#808080") == "#808080"
    assert app_control._resolve_accent("#050403") == "#050403"


def test_app_action_accent_color_rejects_a_non_hex_without_queueing():
    db = _Db()
    out = _run(app_control._bind_app_action(db, "me")("accent_color", "brown"))
    assert "#RRGGBB" in out
    assert _PENDING not in db.store


def test_app_action_get_accent_color_reports_the_saved_hex_for_relative_edits():
    db = _Db()
    db.seed_profile("me", ayma_accent_color="#8b5a2b")
    out = _run(app_control._bind_app_action(db, "me")("get_accent_color"))
    assert "#8B5A2B" in out
    assert _PENDING not in db.store


def test_app_action_get_accent_color_defaults_to_cherry_fuchsia():
    out = _run(app_control._bind_app_action(_Db(), "me")("get_accent_color"))
    assert "#DA4B65" in out


def test_get_accent_color_reports_the_default_name_and_hex():
    out = _run(app_control._bind_app_action(_Db(), "me")("get_accent_color"))
    assert "Cherry Fuchsia" in out and "#DA4B65" in out and "'default'" in out


@pytest.mark.parametrize(
    "word", ["default", "Reset", "cherry fuchsia", "reset to default", "#da4b65"]
)
def test_app_action_accent_default_resets_via_the_screens_own_action(word):
    db = _acking_db()
    out = _run(app_control._bind_app_action(db, "me")("accent_color", word))
    if word == "#da4b65":
        assert db.store[_PENDING]["value"] == "#DA4B65"
        return
    assert db.store[_PENDING]["name"] == "accent_color"
    assert db.store[_PENDING]["value"] == "default"
    assert "Cherry Fuchsia" in out and "#DA4B65" in out


def test_default_accent_matches_flutter_theme():
    theme = (
        Path(__file__).resolve().parents[3] / "ayma_flutter" / "lib" / "theme.dart"
    ).read_text()
    m = re.search(r"static const accent = Color\(0xFF([0-9A-Fa-f]{6})\)", theme)
    assert m and "#" + m.group(1).upper() == app_control._DEFAULT_ACCENT


def test_app_action_description_states_the_default_accent():
    desc = app_control._APP_ACTION["description"]
    assert "Cherry Fuchsia (#DA4B65)" in desc and "'default'" in desc


def test_persona_states_the_default_accent():
    persona = (Path(app_control.__file__).parents[1] / "persona.md").read_text()
    assert "Cherry Fuchsia (#DA4B65)" in persona


def test_app_action_relative_adjust_sends_the_adjusted_hex():
    db = _acking_db()
    db.seed_profile("me", ayma_accent_color="#8B5A2B")
    act = app_control._bind_app_action(db, "me")
    current = re.search(r"current accent colour is (#[0-9A-F]{6})", _run(act("get_accent_color"))).group(1)
    r, g, b = (int(current[i:i + 2], 16) for i in (1, 3, 5))
    darker = "#%02X%02X%02X" % (r * 3 // 4, g * 3 // 4, b * 3 // 4)
    _run(act("accent_color", darker))
    assert db.store[_PENDING]["value"] == darker


def test_app_action_declaration_says_any_colour_and_lists_no_presets():
    desc = app_control._APP_ACTION["description"]
    assert "value" in app_control._APP_ACTION["parameters"]["properties"]
    assert "ANY colour" in desc and "get_accent_color" in desc
    assert "cherry_fuchsia" not in desc and "graphite" not in desc


# --- app_action: every registered setting ---------------------------------

def test_app_action_client_settings_send_their_command():
    for action, value, name, sent_value in (
        ("theme", "dark", "dark_mode", None),
        ("theme", "match system", "system_theme", None),
        ("pause_matching", "on", "pause_matching", None),
        ("pause_matching", "off", "resume_matching", None),
        ("resume_matching", "", "resume_matching", None),
        ("wing_flutter", "off", "wing_flutter", "off"),
        ("nav bar animation", "on", "nav_bar_flutter", "on"),
    ):
        db = _acking_db()
        out = _run(app_control._bind_app_action(db, "me")(action, value))
        assert not out.startswith(("There is no", "The app did NOT")), out
        cmd = db.store[_PENDING]
        assert cmd["name"] == name, (action, value)
        assert cmd.get("value") == sent_value


def test_app_action_rejects_a_bad_value_without_queueing():
    db = _Db()
    out = _run(app_control._bind_app_action(db, "me")("wing_flutter", "purple"))
    assert "on or off" in out
    assert _PENDING not in db.store


def test_app_action_turns_off_one_notification_category_server_side():
    db = _Db()
    out = _run(app_control._bind_app_action(db, "me")("notify_dm_message", "off"))
    assert out.startswith("Done:")
    assert db.store[("users", "me", "notification_prefs", "main")] == {
        "dm_message": False
    }
    assert _PENDING not in db.store


def test_app_action_notify_all_covers_every_category():
    from notifications_schema import NOTIFICATION_TYPES

    db = _Db()
    _run(app_control._bind_app_action(db, "me")("all notifications", "off"))
    prefs = db.store[("users", "me", "notification_prefs", "main")]
    assert prefs == {t: False for t in NOTIFICATION_TYPES}


def test_app_action_partner_age_range_and_distance_use_the_edit_profile_path(
    monkeypatch,
):
    from skills import questionnaire

    calls = []
    monkeypatch.setattr(
        questionnaire, "save_partner_preferences",
        lambda db, uid, **kw: calls.append(kw) or [],
    )
    act = app_control._bind_app_action(_Db(), "me")
    assert _run(act("partner_age_range", "25 to 35")).startswith("Done:")
    assert _run(act("distance", "25 miles")).startswith("Done:")
    assert calls == [{"age_min": 25, "age_max": 35}, {"distance_pref": "25"}]


def test_app_action_relays_the_18_plus_refusal(monkeypatch):
    from skills import questionnaire

    def _refuse(db, uid, **kw):
        raise ValueError("partner ages must be 18 or over")

    monkeypatch.setattr(questionnaire, "save_partner_preferences", _refuse)
    out = _run(app_control._bind_app_action(_Db(), "me")("age range", "16-30"))
    assert "18 or over" in out


def test_app_action_points_profile_fields_to_their_own_tool():
    out = _run(app_control._bind_app_action(_Db(), "me")("profile_fields", "x"))
    assert "set_profile_field" in out


def test_app_action_unknown_setting_is_honest():
    out = _run(app_control._bind_app_action(_Db(), "me")("app language", "fr"))
    assert out.startswith("Not available:")


# --- account_action: explicit confirmation before anything happens --------

def _turns(*user_lines):
    from transcript import Turn

    return [Turn("user", line) for line in user_lines]


def test_account_action_first_call_only_asks():
    db = _acking_db()
    out = _run(app_control._bind_account_action(db, "me")("sign_out"))
    assert out.startswith("Not done yet") and "yes, sign me out" in out
    assert _PENDING not in db.store


def test_account_action_refuses_confirmation_without_a_request_first():
    db = _acking_db()
    out = _run(app_control._bind_account_action(db, "me")("sign_out", True))
    assert out.startswith("Not done")
    assert _PENDING not in db.store


def test_account_action_text_needs_a_new_affirmative_message():
    db = _acking_db()
    first = app_control._bind_account_action(
        db, "me", turns=_turns("sign me out")
    )
    _run(first("sign_out"))
    # Same message (the model chaining ask + confirm in one turn): refused.
    assert _run(first("sign_out", True)).startswith("Not done")
    assert _PENDING not in db.store
    # A later "no" is refused too.
    no = app_control._bind_account_action(
        db, "me", turns=_turns("sign me out", "no, not sure")
    )
    assert _run(no("sign_out", True)).startswith("Not done")
    yes = app_control._bind_account_action(
        db, "me", turns=_turns("sign me out", "yes, sign me out")
    )
    out = _run(yes("sign_out", True))
    assert out.startswith("Done:")
    assert db.store[_PENDING]["name"] == "sign_out"


def test_account_action_voice_needs_time_for_the_spoken_yes(monkeypatch):
    db = _acking_db()
    act = app_control._bind_account_action(db, "me")
    _run(act("log out"))
    assert _run(act("sign_out", True)).startswith("Not done")
    monkeypatch.setattr(app_control, "_CONFIRM_MIN_GAP_SECONDS", 0.0)
    assert _run(act("sign_out", True)).startswith("Done:")
    assert db.store[_PENDING]["name"] == "sign_out"


def test_account_action_wipe_memory_runs_server_side(monkeypatch):
    import knowledge_wipe

    wiped = []
    monkeypatch.setattr(
        knowledge_wipe, "wipe_knowledge", lambda db, uid: wiped.append(uid)
    )
    monkeypatch.setattr(app_control, "_CONFIRM_MIN_GAP_SECONDS", 0.0)
    db = _Db()
    act = app_control._bind_account_action(db, "me")
    _run(act("wipe_memory"))
    assert _run(act("wipe_memory", True)).startswith("Done:")
    assert wiped == ["me"]


def _navigated_only(db, out, path):
    """The tool refused to act and only queued a navigate to ``path``."""
    assert out.startswith("Not done, by design"), out
    assert "navigated:" in out
    cmd = db.store[_PENDING]
    assert cmd["action"] == "navigate" and cmd["path"] == path, cmd


def test_account_action_purchase_only_opens_the_plan_page():
    for words in ("buy credits", "subscribe for me", "purchase"):
        db = _acking_db()
        out = _run(app_control._bind_account_action(db, "me")(words, True))
        _navigated_only(db, out, "/profile/plan")
        assert "Plan page" in out


def test_app_action_purchase_only_opens_the_plan_page():
    db = _acking_db()
    out = _run(app_control._bind_app_action(db, "me")("buy credits"))
    _navigated_only(db, out, "/profile/plan")


def test_open_screen_purchase_words_open_the_plan_page():
    db = _acking_db()
    out = _run(app_control._bind_open_screen(db, "me")("checkout"))
    assert out.startswith(("navigated:", "Not done, by design"))
    assert db.store[_PENDING]["path"] == "/profile/plan"


@pytest.mark.parametrize("confirmed", [False, True])
def test_account_action_delete_account_is_navigate_only(monkeypatch, confirmed):
    monkeypatch.setattr(app_control, "_CONFIRM_MIN_GAP_SECONDS", 0.0)
    db = _acking_db()
    act = app_control._bind_account_action(
        db, "me", turns=_turns("delete my account", "yes, delete my account")
    )
    out = _run(act("delete my account", confirmed))
    _navigated_only(db, out, "/settings/delete-account")
    assert "Tap Delete account there when you're ready" in out
    # Never an executing command, whatever the model passes.
    assert db.store[_PENDING].get("name") is None


@pytest.mark.parametrize("confirmed", [False, True])
def test_account_action_withdraw_consent_is_navigate_only(monkeypatch, confirmed):
    monkeypatch.setattr(app_control, "_CONFIRM_MIN_GAP_SECONDS", 0.0)
    db = _acking_db()
    act = app_control._bind_account_action(db, "me")
    out = _run(act("withdraw my consent", confirmed))
    _navigated_only(db, out, "/settings/biometric-consent")
    assert db.store[_PENDING].get("name") is None


def test_app_action_delete_account_is_navigate_only():
    db = _acking_db()
    out = _run(app_control._bind_app_action(db, "me")("delete_account"))
    _navigated_only(db, out, "/settings/delete-account")


def test_navigate_only_is_honest_when_the_app_never_navigates(monkeypatch):
    _fast_acks(monkeypatch)
    out = _run(app_control._bind_account_action(_Db(), "me")("delete_account"))
    assert out.startswith("Not done, by design") and "did NOT navigate" in out


def test_no_tool_path_sends_delete_or_withdraw_to_the_app():
    for a in app_registry.account_actions():
        if a["key"] in ("delete_account", "withdraw_consent"):
            assert a["handler"] == "navigate_only", a
    src = (Path(app_control.__file__)).read_text(encoding="utf-8")
    assert "deleteAccount" not in src and "withdraw_biometric" not in src


def test_sign_out_still_works_with_one_confirmation(monkeypatch):
    monkeypatch.setattr(app_control, "_CONFIRM_MIN_GAP_SECONDS", 0.0)
    db = _acking_db()
    act = app_control._bind_account_action(db, "me")
    assert _run(act("sign out")).startswith("Not done yet")
    assert _PENDING not in db.store
    assert _run(act("sign_out", True)) == "Done: signing them out now."
    assert db.store[_PENDING] == {**db.store[_PENDING], "name": "sign_out"}


# --- ui_action -----------------------------------------------------------

class _UiAckStore(_AckStore):
    """A healthy client that also reports the screen after the action, or
    refuses with a reason (the app-side denylist)."""

    def __init__(self, *a, reason="", **k):
        super().__init__(*a, **k)
        self._reason = reason

    def __setitem__(self, key, value):
        dict.__setitem__(self, key, value)
        if key == _PENDING and isinstance(value, dict) and value.get("id"):
            self.acked.append(value["id"])
            ack = {"id": value["id"], "ok": not self._reason}
            if self._reason:
                ack["reason"] = self._reason
            else:
                ack["result"] = '[s1] switch "Dark mode" = on'
            dict.__setitem__(self, _ACK, ack)


def test_ui_action_taps_an_allowed_control_and_reports_the_screen():
    db = _Db(_UiAckStore())
    out = _run(app_control._bind_ui_action(db, "me")("s1", "Dark mode", "tap"))
    assert out.startswith("Done: tap on Dark mode.") and '"Dark mode" = on' in out
    cmd = db.store[_PENDING]
    assert cmd["action"] == "ui_action" and cmd["control"] == "s1"
    assert cmd["label"] == "Dark mode" and cmd["op"] == "tap"


def test_ui_action_sets_text_in_a_profile_field():
    db = _Db(_UiAckStore())
    out = _run(app_control._bind_ui_action(db, "me")(
        "[f2]", "First name", "set_text", "Sam"))
    assert out.startswith("Done:")
    assert db.store[_PENDING]["value"] == "Sam"


@pytest.mark.parametrize("control,label,op", [
    ("b4", "Delete account", "tap"),
    ("b2", "Upgrade to Pro", "tap"),
    ("b3", "Start free trial", "tap"),
    ("b1", "Subscribe", "tap"),
    ("b5", "Withdraw consent", "tap"),
    ("c1", "I agree to the Terms of Service", "tap"),
    ("c2", "I have read the biometric policy", "tap"),
    ("f1", "Password", "set_text"),
    ("f3", "Verification code", "set_text"),
    ("b6", "Sign out", "tap"),
    ("b7", "Wipe memory", "tap"),
])
def test_ui_action_denylist_is_enforced_server_side(control, label, op):
    db = _Db(_UiAckStore())
    out = _run(app_control._bind_ui_action(db, "me")(control, label, op, "x"))
    assert out.startswith("Not done, by design:"), out
    assert _PENDING not in db.store


def test_ui_action_denies_everything_on_a_denied_route_from_the_mirror():
    db = _Db(_UiAckStore())
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "", "route": "/settings/delete-account",
        "updated_at": _FreshTs(),
    }
    out = _run(app_control._bind_ui_action(db, "me")("b1", "Continue", "tap"))
    assert out.startswith("Not done, by design:")
    assert _PENDING not in db.store


def test_ui_action_plan_page_switch_is_a_purchase_but_tabs_are_fine():
    db = _Db(_UiAckStore())
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "", "route": "/profile/plan", "updated_at": _FreshTs(),
    }
    act = app_control._bind_ui_action(db, "me")
    assert _run(act("b2", "Switch to Plus", "tap")).startswith("Not done")
    assert _run(act("t1", "Max", "tap")).startswith("Done:")


def test_ui_action_relays_the_app_side_refusal():
    db = _Db(_UiAckStore(reason="that control is no longer on screen"))
    out = _run(app_control._bind_ui_action(db, "me")("b9", "Save", "tap"))
    assert out == "Not done: that control is no longer on screen"


def test_ui_action_needs_an_id_and_label_except_back_and_page_scroll():
    db = _Db(_UiAckStore())
    act = app_control._bind_ui_action(db, "me")
    assert _run(act("", "", "tap")).startswith("Pass the control")
    assert _run(act("", "", "back")).startswith("Done:")
    assert _run(act("", "", "scroll_down")).startswith("Done:")
    assert _run(act("b1", "Save", "fly")).startswith("'fly' isn't")


def test_ui_action_is_a_command_tool_in_voice_and_text():
    assert "ui_action" in {s.name for s in app_control.COMMAND_SKILLS}
    desc = app_control._UI_ACTION["description"]
    assert "Delete" not in desc or "Never for" in desc
    assert "{{" not in desc and "set_text" in desc


# --- screen context (generic capture) ------------------------------------

def test_describe_names_any_route_and_includes_the_live_capture():
    out = app_control._describe({
        "screen": "", "route": "/settings/accent-color",
        "visible": 'Title: Accent colour\n[b1] button "Save"',
    })
    assert out.startswith("The user is on Accent colour.")
    assert "Route: /settings/accent-color" in out
    assert '[b1] button "Save"' in out and "ui_action" in out


def test_describe_lists_what_sits_on_settings_like_the_you_tab():
    out = app_control._describe({"screen": "", "route": "/settings"})
    assert "Delete account" in out and "Accent colour" in out


def test_describe_keeps_the_slug_line_for_known_screens():
    out = app_control._describe({
        "screen": "messages", "route": "/messages", "visible": "Sam: hi",
    })
    assert out.startswith("The user is on their Messages list.")
    assert "Sam: hi" in out


def test_current_screen_reads_route_and_capture_from_the_mirror():
    db = _Db()
    db.store[("users", "me", "voice_context", "current")] = {
        "screen": "", "route": "/notifications",
        "visible": '[i1] item "Sam liked your profile"', "updated_at": _FreshTs(),
    }
    out = app_control._bind_current_screen(db, "me")()
    assert "Notifications" in out and "Sam liked your profile" in out


def test_text_account_action_is_bound_with_the_transcript():
    db = _acking_db()
    fns = skills.make_session_tool_fns(
        db, "me",
        session_ctx={"session_id": "s", "turn_index": 1,
                     "turns": _turns("sign me out")},
    )
    _run(fns["account_action"]("sign_out"))
    assert _run(fns["account_action"]("sign_out", True)).startswith("Not done")


# --- screen context ------------------------------------------------------

def test_describe_profile_tab_lists_the_completeness_card():
    out = app_control._describe({"screen": "profile_tab"})
    assert "Your profile is N% complete" in out
    assert "complete_profile" in out and "My public profile" in out
