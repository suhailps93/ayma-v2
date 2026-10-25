"""Voice-only screen-awareness / navigation tools (``skills.app_control``).
The ``/voice/context`` endpoint they read is covered by
``test_voice_context_endpoint``."""

from __future__ import annotations

import asyncio
import time

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
    assert out == "navigated: screen=matches — the user is now on Matches."
    cmd = db.store[_PENDING]
    assert cmd["action"] == "navigate" and cmd["screen"] == "matches"
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
    assert "I can open" in out
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
    assert out == "navigated: screen=profile — Jordan Lee's profile is open."
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
    "app_action",
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
    assert _run(fn("dark_mode")) == app_control._APP_ACTIONS["dark_mode"]
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
        "open_message_thread", "app_action",
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
    # Auth/onboarding + the deliberately-hidden Google/Instagram linking
    # screens stay unreachable.
    for screen in ("sign-in", "google_account", "instagram", "complete_profile"):
        db = _Db()
        out = _run(app_control._bind_open_screen(db, "me")(screen))
        assert "I can open" in out


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
    out = _run(app_control._bind_app_action(db, "me")("delete_my_account"))
    assert "I can do" in out
    assert _PENDING not in db.store


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


def test_app_action_relative_adjust_sends_the_adjusted_hex():
    db = _acking_db()
    db.seed_profile("me", ayma_accent_color="#8B5A2B")
    act = app_control._bind_app_action(db, "me")
    current = _run(act("get_accent_color")).split()[-1].rstrip(".")
    r, g, b = (int(current[i:i + 2], 16) for i in (1, 3, 5))
    darker = "#%02X%02X%02X" % (r * 3 // 4, g * 3 // 4, b * 3 // 4)
    _run(act("accent_color", darker))
    assert db.store[_PENDING]["value"] == darker


def test_app_action_declaration_says_any_colour_and_lists_no_presets():
    desc = app_control._APP_ACTION["description"]
    assert "value" in app_control._APP_ACTION["parameters"]["properties"]
    assert "ANY colour" in desc and "get_accent_color" in desc
    assert "cherry_fuchsia" not in desc and "graphite" not in desc
