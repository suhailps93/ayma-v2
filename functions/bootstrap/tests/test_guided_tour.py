"""Ayma-driven interactive tour (``skills.guided_tour``): start spotlights the
first step, advance moves on only after the user's tap event (and skips a step
whose anchor the client reports absent), stop ends it, and a missing tap is
reported honestly without hanging.
"""

from __future__ import annotations

import asyncio
import time
from datetime import datetime, timedelta, timezone

import pytest

import app_registry
import skills
from skills import app_control, guided_tour


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


# --- minimal tuple-keyed fake Firestore (mirrors tests/test_set_model_stack) --

_PENDING = ("users", "u1", "app_commands", "pending")
_ACK = ("users", "u1", "app_commands", "ack")
_EVENT = ("users", "u1", "app_commands", "tour_event")
_STATE = ("users", "u1", "app_commands", "tour_state")


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
        # Simulate the client acking every spotlight command: ok unless this
        # step's index is in the store's "absent anchor" set.
        if self.key[-1] == "pending" and patch.get("action") == "tour_step":
            ack = (*self.key[:-1], "ack")
            ok = int(patch.get("index", -1)) not in self.store.absent
            self.store[ack] = {"id": patch.get("id"), "ok": ok}

    def delete(self):
        self.store.pop(self.key, None)


class _Col:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _Doc(self.store, (*self.key, doc_id))


class _Store(dict):
    def __init__(self, absent=()):
        super().__init__()
        self.absent = set(absent)


class _Db:
    def __init__(self, absent=()):
        self.store = _Store(absent=absent)

    def collection(self, name):
        return _Col(self.store, (name,))


@pytest.fixture(autouse=True)
def _fast(monkeypatch):
    """Shrink the poll/wait knobs so the bounded loops resolve instantly."""
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", 0.001)
    monkeypatch.setattr(guided_tour, "_TAP_POLL_SECONDS", 0.001)
    monkeypatch.setattr(guided_tour, "_SPOTLIGHT_ACK_TIMEOUT_SECONDS", 1.0)
    monkeypatch.setattr(guided_tour, "_TAP_TIMEOUT_SECONDS", 0.05)


def _tap(db, index, event="tapped"):
    db.store[_EVENT] = {"index": index, "event": event}


def _steps():
    return app_registry.guided_tour_steps()


# --- registration -------------------------------------------------------------


def test_tour_tools_registered_in_both_surfaces():
    names = {s.name for s in skills.all_skills()}
    assert {"start_guided_tour", "advance_guided_tour", "stop_guided_tour"} <= names
    text = {d["name"] for d in skills.session_tool_declarations()}
    assert {"start_guided_tour", "advance_guided_tour", "stop_guided_tour"} <= text


# --- start --------------------------------------------------------------------


def test_start_spotlights_step_0_and_returns_its_line():
    db = _Db()
    msg = _run(guided_tour._bind_start_guided_tour(db, "u1")())
    # The first step is queued and the state records it as the current step.
    assert db.store[_PENDING]["action"] == "tour_step"
    assert db.store[_PENDING]["index"] == 0
    assert db.store[_PENDING]["anchor"] == _steps()[0]["anchor"]
    assert db.store[_STATE]["index"] == 0
    assert db.store[_STATE]["active"] is True
    assert "step 1 of" in msg and _steps()[0]["say"] in msg


def test_text_start_spotlights_the_composer_step_first():
    # In TEXT mode the composer is a real text box, so step 0 (the composer) is
    # shown normally.
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1", voice=False)())
    assert db.store[_PENDING]["anchor"] == "home_composer"
    assert db.store[_STATE]["index"] == 0


def test_voice_start_skips_the_composer_step():
    # Founder 2026-11-03: in a VOICE session the composer is the call bar (no
    # text box), so the "tap the message box to type" step must be skipped —
    # the tour must never instruct an action that can't be done in this mode.
    steps = _steps()
    assert steps[0]["anchor"] == "home_composer" and steps[0].get("skip_in_voice")
    db = _Db()
    msg = _run(guided_tour._bind_start_guided_tour(db, "u1", voice=True)())
    # Step 0 (composer) was skipped; the first spotlight is step 1 (Explore),
    # and that is where the tour state sits.
    assert db.store[_PENDING]["anchor"] == steps[1]["anchor"]  # explore_tab
    assert db.store[_STATE]["index"] == 1
    assert steps[1]["say"] in msg
    # The composer was never queued.
    assert db.store[_PENDING]["anchor"] != "home_composer"


def test_voice_skip_is_registered_in_the_voice_tool_set_with_voice_true():
    # The voice surface binds start/advance with voice=True so the skip applies;
    # the text surface binds them with voice=False. (Guards the wiring that
    # make_livekit_tools / make_session_tool_fns set up.)
    import inspect
    src = inspect.getsource(skills)
    assert "_GUIDED_TOUR_VOICE_NAMES" in src
    assert "voice=True" in src and "voice=False" in src


def test_start_with_no_steps_is_honest(monkeypatch):
    monkeypatch.setattr(app_registry, "guided_tour_steps", list)
    db = _Db()
    msg = _run(guided_tour._bind_start_guided_tour(db, "u1")())
    assert "isn't available" in msg
    assert _PENDING not in db.store  # nothing queued


# --- advance only after the tap -----------------------------------------------


def test_advance_waits_for_the_tap_then_issues_the_next_step():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    # The user taps the spotlighted control for step 0.
    _tap(db, 0)
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    # Step 1 is now the spotlighted, current step, and its line came back.
    assert db.store[_PENDING]["index"] == 1
    assert db.store[_STATE]["index"] == 1
    assert _steps()[1]["say"] in msg


def test_advance_without_a_tap_reports_honestly_and_does_not_move():
    # Founder 2026-11-03: a verbal "what's next" (the model calling advance with
    # no tap) must NOT move the tour. Without a tap event the wait lapses and the
    # step stays put.
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    # No tap event written → the bounded wait lapses.
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "not tapped" in msg.lower()
    assert db.store[_STATE]["index"] == 0  # still on step 0
    assert db.store[_STATE]["active"] is True
    # The next step was never queued — the tour did not advance.
    assert db.store[_PENDING]["index"] == 0


def test_advance_has_no_skip_parameter():
    # There is deliberately no way to skip ahead without a tap: the tool exposes
    # no parameters, and the bound callable rejects a skip kwarg.
    assert guided_tour.ADVANCE_GUIDED_TOUR.declaration["parameters"]["properties"] == {}
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    with pytest.raises(TypeError):
        _run(guided_tour._bind_advance_guided_tour(db, "u1")(skip=True))


def test_advance_skips_a_step_whose_anchor_is_absent():
    db = _Db(absent={1})  # the client reports step 1's anchor missing
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    _tap(db, 0)
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    # Step 1 was skipped honestly; we landed on step 2.
    assert db.store[_STATE]["index"] == 2
    assert _steps()[2]["say"] in msg


def test_advance_past_the_last_step_completes_the_tour():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    total = len(_steps())
    # Tap through every step.
    for i in range(total):
        _tap(db, i)
        msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "complete" in msg.lower()
    assert db.store[_STATE]["active"] is False
    assert db.store[_PENDING]["action"] == "tour_end"


def test_advance_with_no_running_tour_is_honest():
    db = _Db()
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "no guided tour running" in msg.lower()


# --- stop ---------------------------------------------------------------------


def test_stop_event_ends_the_tour_mid_step():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    _tap(db, 0, event="stop")
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "ended the guided tour" in msg
    assert db.store[_STATE]["active"] is False
    assert db.store[_PENDING]["action"] == "tour_end"


def test_stop_tool_dismisses_and_marks_inactive():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    msg = _run(guided_tour._bind_stop_guided_tour(db, "u1")())
    assert "ended" in msg.lower()
    assert db.store[_STATE]["active"] is False
    assert db.store[_PENDING]["action"] == "tour_end"


# --- stale state TTL (Antigravity review 2026-11-03 finding 2) ----------------
#
# tour_state kept active:true forever across app kills, so a later advance
# polled a dead overlay for the full tap wait. State older than 15 minutes is
# now expired: the orphan is dismissed and cleared, honestly, without waiting.


def _age_state(db, minutes: float) -> None:
    db.store[_STATE]["updated_at"] = datetime.now(timezone.utc) - timedelta(
        minutes=minutes
    )


def test_advance_on_stale_state_expires_it_without_waiting(monkeypatch):
    monkeypatch.setattr(guided_tour, "_TAP_TIMEOUT_SECONDS", 5.0)
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    _age_state(db, 16)
    start = time.monotonic()
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert time.monotonic() - start < 5.0  # never polled the dead overlay
    assert "timed out" in msg.lower() or "expired" in msg.lower()
    assert db.store[_STATE]["active"] is False  # orphan cleared
    assert db.store[_PENDING]["action"] == "tour_end"  # overlay dismissed


def test_advance_on_fresh_or_undated_state_still_waits():
    # A recent state — or an old doc from before updated_at existed — is a
    # live tour: advance waits for the tap, it doesn't expire.
    for undated in (False, True):
        db = _Db()
        _run(guided_tour._bind_start_guided_tour(db, "u1")())
        if undated:
            del db.store[_STATE]["updated_at"]
        else:
            _age_state(db, 1)
        msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
        assert "not tapped" in msg.lower()
        assert db.store[_STATE]["active"] is True


# --- null index guard (Antigravity review 2026-11-03 finding 4) ----------------
#
# int(data.get("index", -1)) throws TypeError when Firestore holds an explicit
# null — outside any try/except. A null/garbage index must read as "no event" /
# "no runnable tour", never crash. (Note: `or` would be wrong here — step 0 is
# valid and falsy — so the guard checks None explicitly.)


def test_advance_ignores_a_null_index_tap_event_without_crashing():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    db.store[_EVENT] = {"index": None, "event": "tapped"}
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "not tapped" in msg.lower()  # the null event matched nothing
    assert db.store[_STATE]["index"] == 0  # still on step 0


def test_advance_on_null_index_state_ends_honestly_without_crashing():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    db.store[_STATE]["index"] = None
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "no guided tour running" in msg.lower()
    assert db.store[_STATE]["active"] is False


def test_step_zero_index_is_not_treated_as_missing():
    # Regression pin for the `or`-style guard: index 0 is a real step and a
    # tap event for it must still advance.
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    _tap(db, 0)
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 1
    assert _steps()[1]["say"] in msg


# --- sync-path tap bound (Antigravity review 2026-11-03 finding 5) -------------
#
# advance's 110s tap wait held a /chat HTTP turn open. The text surface now
# binds a short sync bound; voice keeps the long quiet wait. A lapse still
# reports honestly and the persisted tap is picked up by the next advance, so
# progress is never lost on either surface.


def test_text_surface_advance_uses_the_short_sync_bound(monkeypatch):
    monkeypatch.setattr(guided_tour, "_TAP_TIMEOUT_SYNC_SECONDS", 0.05)
    monkeypatch.setattr(guided_tour, "_TAP_TIMEOUT_SECONDS", 5.0)
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    fns = skills.make_session_tool_fns(db, "u1")
    start = time.monotonic()
    msg = _run(fns["advance_guided_tour"]())
    assert time.monotonic() - start < 5.0  # the sync bound, not the voice one
    assert "not tapped" in msg.lower()
    assert db.store[_STATE]["active"] is True  # still waiting, tour intact


def test_advance_accepts_an_explicit_tap_timeout(monkeypatch):
    monkeypatch.setattr(guided_tour, "_TAP_TIMEOUT_SECONDS", 5.0)
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    start = time.monotonic()
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1", tap_timeout=0.05)())
    assert time.monotonic() - start < 5.0
    assert "not tapped" in msg.lower()
