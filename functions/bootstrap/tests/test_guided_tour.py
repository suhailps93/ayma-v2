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
        # Simulate the rewired client (founder 2026-11-07): a tour_step is
        # acked ok ONLY when the user is on the step's screen and the anchor
        # resolves; "not_on_screen" when they are somewhere else (the tour
        # must navigate and retry); "anchor_absent" only when they ARE on
        # the screen but the control is genuinely missing. navigate acks ok
        # unless fail_navigate.
        if self.key[-1] != "pending":
            return
        action = patch.get("action")
        if action not in ("tour_step", "navigate"):
            return
        self.store.commands.append(dict(patch))
        ack = (*self.key[:-1], "ack")
        if action == "navigate":
            self.store[ack] = {
                "id": patch.get("id"),
                "ok": not self.store.fail_navigate,
            }
            return
        idx = int(patch.get("index", -1))
        if idx in self.store.unacked:
            return
        steps = app_registry.guided_tour_steps()
        step = steps[idx] if 0 <= idx < len(steps) else {}
        if idx in self.store.absent:
            self.store[ack] = {
                "id": patch.get("id"),
                "ok": False,
                "reason": "anchor_absent",
                "screen": step.get("screen"),
                "route": step.get("route") or "",
            }
        elif idx in self.store.off_screen_once and idx not in self.store.off_seen:
            self.store.off_seen.add(idx)
            self.store[ack] = {
                "id": patch.get("id"),
                "ok": False,
                "reason": "not_on_screen",
                "screen": self.store.user_screen,
                "route": self.store.user_route,
            }
        else:
            self.store[ack] = {
                "id": patch.get("id"),
                "ok": True,
                "screen": step.get("screen"),
                "route": step.get("route") or "",
            }

    def delete(self):
        self.store.pop(self.key, None)


class _Col:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _Doc(self.store, (*self.key, doc_id))


class _Store(dict):
    def __init__(self, absent=(), unacked=(), off_screen_once=(), fail_navigate=False):
        super().__init__()
        self.absent = set(absent)
        self.unacked = set(unacked)
        # Steps whose FIRST presentation finds the user on another screen.
        self.off_screen_once = set(off_screen_once)
        self.off_seen = set()
        self.fail_navigate = fail_navigate
        # The fake user's current screen (what a not_on_screen ack reports).
        self.user_screen = "ayma"
        self.user_route = "/"
        # Every app command payload, in order (ordering assertions).
        self.commands = []


class _Db:
    def __init__(self, absent=(), unacked=(), off_screen_once=(), fail_navigate=False):
        self.store = _Store(
            absent=absent,
            unacked=unacked,
            off_screen_once=off_screen_once,
            fail_navigate=fail_navigate,
        )

    def collection(self, name):
        return _Col(self.store, (name,))


@pytest.fixture(autouse=True)
def _fast(monkeypatch):
    """Shrink the poll/wait knobs so the bounded loops resolve instantly."""
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", 0.001)
    monkeypatch.setattr(guided_tour, "_TAP_POLL_SECONDS", 0.001)
    monkeypatch.setattr(guided_tour, "_SPOTLIGHT_ACK_TIMEOUT_SECONDS", 1.0)
    monkeypatch.setattr(guided_tour, "_TAP_TIMEOUT_SECONDS", 0.05)


def _tap(db, index, event="tapped", ts=None):
    payload = {"index": index, "event": event}
    if ts is not None:
        payload["ts"] = ts
    db.store[_EVENT] = payload


def _outcome(db, index, event="performed", attempt=1):
    db.store[_EVENT] = {"index": index, "event": event, "attempt": attempt}


def _steps():
    return app_registry.guided_tour_steps()


def _start_on_explore_step(db):
    """Start the tour and move past the look-only orb step to Explore (1)."""
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    _tap(db, 0)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 1


# --- registration -------------------------------------------------------------


def test_tour_tools_registered_in_both_surfaces():
    names = {s.name for s in skills.all_skills()}
    assert {
        "start_guided_tour",
        "advance_guided_tour",
        "skip_guided_tour",
        "stop_guided_tour",
    } <= names
    text = {d["name"] for d in skills.session_tool_declarations()}
    assert {
        "start_guided_tour",
        "advance_guided_tour",
        "skip_guided_tour",
        "stop_guided_tour",
    } <= text


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


def test_text_walk_includes_the_composer_step():
    # In TEXT mode the composer is a real text box, so the walk presents the
    # composer step (skip_in_voice) like any other.
    steps = _steps()
    composer = next(i for i, s in enumerate(steps) if s.get("skip_in_voice"))
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1", voice=False)())
    for _ in range(composer):
        _tap(db, db.store[_STATE]["index"])
        _run(guided_tour._bind_advance_guided_tour(db, "u1", voice=False)())
    assert db.store[_STATE]["index"] == composer
    assert db.store[_PENDING]["anchor"] == "home_composer"


def test_voice_walk_skips_the_composer_step():
    # Founder 2026-11-03: in a VOICE session the composer is the call bar (no
    # text box), so the "tap the message box to type" step must be skipped —
    # the tour must never instruct an action that can't be done in this mode.
    steps = _steps()
    composer = next(i for i, s in enumerate(steps) if s.get("skip_in_voice"))
    assert steps[composer]["anchor"] == "home_composer"
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1", voice=True)())
    seen = [db.store[_STATE]["index"]]
    for _ in range(composer):
        _tap(db, db.store[_STATE]["index"])
        _run(guided_tour._bind_advance_guided_tour(db, "u1", voice=True)())
        seen.append(db.store[_STATE]["index"])
    assert composer not in seen
    assert seen[-1] == composer + 1


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


# --- tour_event timestamp freshness (Scout live auto-advance regression guard) -
#
# If an unconsumed tour_event persists across tours/sessions (e.g. if _clear_event
# failed or a client write raced), an event at step k from a previous tour must
# NOT be consumed by a later tour at step k. _await_tour_event validates that
# event['ts'] is fresh relative to tour_state's updated_at.


def test_is_event_fresh_unit():
    now = datetime.now(timezone.utc)
    t_past = now - timedelta(seconds=10)
    t_future = now + timedelta(seconds=10)

    # Stale: event occurred before state was updated
    assert not guided_tour._is_event_fresh({"ts": t_past}, now)
    assert not guided_tour._is_event_fresh({"ts": t_past.timestamp()}, now.timestamp())
    assert not guided_tour._is_event_fresh({"ts": t_past.isoformat()}, now.isoformat())

    # Fresh: event occurred at or after state was updated
    assert guided_tour._is_event_fresh({"ts": now}, now)
    assert guided_tour._is_event_fresh({"ts": t_future}, now)
    assert guided_tour._is_event_fresh({"ts": t_future.timestamp()}, now.timestamp())
    assert guided_tour._is_event_fresh({"ts": t_future.isoformat()}, now.isoformat())

    # State has timestamp, but event has no timestamp -> stale
    assert not guided_tour._is_event_fresh({}, now)
    assert not guided_tour._is_event_fresh({"ts": None}, now)
    assert not guided_tour._is_event_fresh({"ts": "not-a-date"}, now)

    # Undated state (None or unresolved sentinel) -> accepted (backwards compatible)
    assert guided_tour._is_event_fresh({"ts": t_past}, None)
    assert guided_tour._is_event_fresh({}, None)


def test_advance_ignores_stale_tap_event_and_stays_put():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    now = datetime.now(timezone.utc)
    db.store[_STATE]["updated_at"] = now
    # Event ts is 15 seconds older than current step presentation
    _tap(db, 0, ts=now - timedelta(seconds=15))

    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "not tapped" in msg.lower()
    assert db.store[_STATE]["index"] == 0  # didn't advance
    assert db.store[_PENDING]["index"] == 0


def test_advance_consumes_fresh_tap_event_and_advances():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    now = datetime.now(timezone.utc)
    db.store[_STATE]["updated_at"] = now
    # Event ts is 1 second after step presentation
    _tap(db, 0, ts=now + timedelta(seconds=1))

    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 1
    assert db.store[_PENDING]["index"] == 1
    assert _steps()[1]["say"] in msg


def test_unconsumed_event_from_prior_session_not_consumed_by_later_tour():
    # Scout live scenario: an unconsumed tap at a step persisted across
    # sessions. A new tour started at that same step. Previously, advance
    # consumed the old tap and auto-advanced past the step without the user
    # tapping.
    db = _Db()
    prior_session_ts = datetime.now(timezone.utc) - timedelta(minutes=10)
    # Stale unconsumed event at index 0 left behind in Firestore
    _tap(db, 0, ts=prior_session_ts)

    # Tour 2 starts now in voice mode, at step 0.
    msg_start = _run(guided_tour._bind_start_guided_tour(db, "u1", voice=True)())
    assert _steps()[0]["say"] in msg_start
    assert db.store[_STATE]["index"] == 0
    now = datetime.now(timezone.utc)
    db.store[_STATE]["updated_at"] = now

    # Advance runs: the stale tap at index 0 is IGNORED, not consumed
    msg_advance = _run(guided_tour._bind_advance_guided_tour(db, "u1", voice=True)())
    assert "not tapped" in msg_advance.lower()
    assert db.store[_STATE]["index"] == 0  # STILL on step 0!
    assert db.store[_PENDING]["index"] == 0

    # User now actually taps the highlighted control:
    _tap(db, 0, ts=now + timedelta(seconds=2))
    msg_advance2 = _run(guided_tour._bind_advance_guided_tour(db, "u1", voice=True)())
    # Now it advances to step 1!
    assert db.store[_STATE]["index"] == 1
    assert db.store[_PENDING]["index"] == 1
    assert _steps()[1]["say"] in msg_advance2


def test_stale_stop_event_does_not_abort_later_tour():
    db = _Db()
    prior_session_ts = datetime.now(timezone.utc) - timedelta(minutes=5)
    # Stale stop event left behind
    _tap(db, 0, event="stop", ts=prior_session_ts)

    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    now = datetime.now(timezone.utc)
    db.store[_STATE]["updated_at"] = now

    # Advance ignores the stale stop event and remains active
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "not tapped" in msg.lower()
    assert db.store[_STATE]["active"] is True
    assert db.store[_STATE]["index"] == 0


def test_await_tour_event_reads_state_doc_when_not_passed():
    db = _Db()
    now = datetime.now(timezone.utc)
    db.store[_STATE] = {"index": 0, "active": True, "updated_at": now}
    _tap(db, 0, ts=now - timedelta(seconds=5))

    # Calling _await_tour_event without state_updated_at reads the state doc
    # and ignores the stale event.
    ev = _run(guided_tour._await_tour_event(db, "u1", 0, timeout=0.01))
    assert ev is None

    # Fresh event is returned
    _tap(db, 0, ts=now + timedelta(seconds=1))
    ev_fresh = _run(guided_tour._await_tour_event(db, "u1", 0, timeout=0.01))
    assert ev_fresh is not None
    assert ev_fresh["event"] == "tapped"


def test_written_tour_event_doc_shape_is_exactly_what_the_poller_consumes():
    # The EXACT doc the client writes on a tap (app_command_service `event()`:
    # {index:int, event:'tapped', ts:serverTimestamp → Admin SDK datetime}) must
    # satisfy every field the poller checks: _index_of, the 'event' truthiness,
    # and _is_event_fresh against the step's updated_at. Field-by-field, so a
    # future rename on either side breaks this test (founder/Scout, 2026-11-03).
    state_updated_at = datetime(2026, 11, 3, 17, 57, 13, tzinfo=timezone.utc)
    written = {
        "index": 0,
        "event": "tapped",
        "ts": datetime(2026, 11, 3, 17, 58, 4, tzinfo=timezone.utc),
    }
    assert guided_tour._index_of(written) == 0
    assert bool(written.get("event")) is True
    assert guided_tour._is_event_fresh(written, state_updated_at) is True
    # And the full poller returns exactly this doc.
    db = _Db()
    db.store[_STATE] = {"index": 0, "active": True, "updated_at": state_updated_at}
    db.store[_EVENT] = dict(written)
    ev = _run(guided_tour._await_tour_event(db, "u1", 0, timeout=0.01))
    assert ev is not None and ev["event"] == "tapped" and int(ev["index"]) == 0


def test_fast_tap_at_the_presentation_instant_is_fresh_not_rejected():
    # After _write_state is recorded BEFORE the spotlight, a fast tapper's
    # event.ts is >= state.updated_at, so _is_event_fresh accepts it — the latent
    # race that could reject a real immediate tap. A genuinely older event (a
    # prior tour at the same index) is still rejected.
    t = datetime(2026, 11, 3, 17, 57, 13, tzinfo=timezone.utc)
    assert guided_tour._is_event_fresh({"event": "tapped", "ts": t}, t) is True
    older = t - timedelta(seconds=3)
    assert guided_tour._is_event_fresh({"event": "tapped", "ts": older}, t) is False


# --- deterministic tour-start detection (voice pre-model backstop) --------------


@pytest.mark.parametrize("phrase", [
    "start the guided tour",
    "Start the guided tour!",
    "can you start the tour for me",
    "please begin the guided tour",
    "launch the app tour",
    "restart the guided tour",
    "give me a tour",
    "show me around",
    "walk me through the app",
    "Can you walk me through the app?",
    "walk me around the app",
    "walk around the app",
    "Can you walk me around the app?",
    "open the guided tour",
    "show me the tour",
])
def test_detect_tour_command_matches_a_clear_start(phrase):
    assert guided_tour.detect_tour_command(phrase) == "start_guided_tour"


@pytest.mark.parametrize("phrase", [
    "stop the tour",                 # must reach stop_guided_tour, not start
    "quit the guided tour",
    "end the tour please",
    "cancel this tour",
    "what's next on the tour",       # spoken "next" never drives the tour
    "continue the tour",
    "tell me about the guided tour",  # a question, not a command
    "is there a tour of the app",
    "the tour was great",
    "open the models page",          # navigation, not the tour
    "switch my brain to gemini",     # stack switch, not the tour
    "",                              # empty
    "x" * 201,                       # over the length guard
])
def test_detect_tour_command_leaves_everything_else_alone(phrase):
    assert guided_tour.detect_tour_command(phrase) is None


def test_unacked_step_does_not_advance_and_reprompts(monkeypatch):
    """F1: A step the client never acks (timeout) must NOT auto-skip to the next
    step. It stays on current and re-prompts."""
    monkeypatch.setattr(guided_tour, "_SPOTLIGHT_ACK_TIMEOUT_SECONDS", 0.01)
    db = _Db(unacked={1})
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 0
    _tap(db, 0)
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    # State remains 0, did NOT advance to 1 or 2!
    assert db.store[_STATE]["index"] == 0
    assert "Still on step 1" in msg
    assert "waiting for" in msg


def test_start_guided_tour_while_active_continues_from_current():
    """F4: Calling start_guided_tour while a tour is active continues from the
    current step instead of restarting at step 0."""
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 0
    _tap(db, 0)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 1
    # Invoking start_guided_tour again: continues from step 1
    msg = _run(guided_tour._bind_start_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 1
    assert "step 2 of" in msg


def test_back_guided_tour():
    """F4: back_guided_tour moves back to previous step."""
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 0
    _tap(db, 0)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 1
    # Move back
    msg = _run(guided_tour._bind_back_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 0
    assert "step 1 of" in msg
    # At step 0, back stays at 0
    msg0 = _run(guided_tour._bind_back_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 0
    assert "step 1 of" in msg0


def test_consume_stop_if_pending():
    """F2: The server consumes an unconsumed stop event in text path."""
    db = _Db()
    now = datetime.now(timezone.utc)
    db.store[_STATE] = {"index": 2, "active": True, "updated_at": now}
    db.store[_EVENT] = {"index": 2, "event": "stop", "ts": now}
    consumed = _run(guided_tour.consume_stop_if_pending(db, "u1"))
    assert consumed is True
    assert db.store[_STATE]["active"] is False
    assert _EVENT not in db.store


def test_open_screen_blocked_during_active_tour():
    """F3: Mid-tour questions must not trigger navigation away from tour."""
    db = _Db()
    db.store[_STATE] = {"index": 1, "active": True, "updated_at": datetime.now(timezone.utc)}
    res = _run(skills.app_control._bind_open_screen(db, "u1")(screen="credits"))
    assert "The guided tour is currently active" in res
    assert _PENDING not in db.store



# --- rewire (founder 2026-11-07): look first, verify landing, voice control ---
#
# The new spec: (a) a stop whose target is not on the current screen
# produces NO highlight and triggers the get-there-first path; (b) the tour
# advances only when the post-tap screen read matches the expected landing
# — a wrong landing re-guides; (c) skip/next works without a tap, in voice
# and text; (d) the manifest is main-features-first.


def test_not_on_screen_step_navigates_before_any_highlight():
    db = _Db(off_screen_once={2})
    db.store.user_screen = "explore"  # the user wandered off the home tab
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    _tap(db, 0)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())  # -> step 1
    _tap(db, 1)
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())  # -> step 2
    assert db.store[_STATE]["index"] == 2
    assert _steps()[2]["say"] in msg
    cmds = db.store.commands
    step2 = [
        i
        for i, c in enumerate(cmds)
        if c.get("action") == "tour_step" and c.get("index") == 2
    ]
    navs = [i for i, c in enumerate(cmds) if c.get("action") == "navigate"]
    # The step was presented twice: once blind (refused), once after the
    # navigation landed — get there FIRST, then highlight.
    assert len(step2) == 2 and len(navs) == 1
    assert step2[0] < navs[0] < step2[1]
    assert cmds[navs[0]]["screen"] == _steps()[2]["screen"]


def test_failed_navigation_blocks_instead_of_skipping_or_advancing():
    # The Nov 5 failure, inverted: when the tour cannot get the user to
    # the step's screen, it STAYS on the current step — it never skips
    # ahead and never runs off the end of the tour.
    db = _Db(off_screen_once={1}, fail_navigate=True)
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    _tap(db, 0)
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 0
    assert db.store[_STATE]["active"] is True
    assert "Still on step 1" in msg


# --- action-driven, user-paced steps (founder, 2026-11-08) -----------------------


def test_step_payload_carries_the_command_ayma_performs():
    db = _Db()
    _start_on_explore_step(db)
    assert db.store[_PENDING]["command"] == {"action": "switch_tab", "tab": 1}


def test_look_step_payload_has_no_command():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    assert db.store[_PENDING]["command"] is None


def test_performed_step_stays_put_and_waits_for_the_go():
    # Founder decision: Ayma performs the step, then the user sets the pace.
    db = _Db()
    _start_on_explore_step(db)
    _outcome(db, 1)
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1", voice=True)())
    assert "NOT moved on" in msg
    assert "say next" in msg
    assert db.store[_STATE]["index"] == 1
    assert db.store[_STATE]["active"] is True
    assert db.store[_PENDING]["index"] == 1  # no next step was queued


def test_performed_directive_asks_for_next_on_the_text_surface():
    db = _Db()
    _start_on_explore_step(db)
    _outcome(db, 1)
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "tap Next" in msg


def test_a_performed_outcome_is_narrated_once():
    db = _Db()
    _start_on_explore_step(db)
    _outcome(db, 1)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "waiting for the user's go" in msg
    assert db.store[_STATE]["index"] == 1


def test_no_timed_advance_after_a_performed_step(monkeypatch):
    # However long the user looks, the wait lapsing never moves the tour.
    monkeypatch.setattr(guided_tour, "_GO_CHECK_SECONDS", 0.01)
    db = _Db()
    _start_on_explore_step(db)
    _outcome(db, 1)
    advance = guided_tour._bind_advance_guided_tour(db, "u1")
    for _ in range(3):
        _run(advance())
    assert db.store[_STATE]["index"] == 1
    assert db.store[_PENDING]["index"] == 1


def test_spoken_go_after_a_performed_step_advances():
    db = _Db()
    _start_on_explore_step(db)
    _outcome(db, 1)
    _run(guided_tour._bind_advance_guided_tour(db, "u1", voice=True)())
    msg = _run(guided_tour._bind_skip_guided_tour(db, "u1", voice=True)())
    assert db.store[_STATE]["index"] == 2
    assert _steps()[2]["say"] in msg


def test_next_after_a_performed_step_advances():
    db = _Db()
    _start_on_explore_step(db)
    _outcome(db, 1)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    _tap(db, 1, event="skip")
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 2
    assert _steps()[2]["say"] in msg


def test_reporting_an_outcome_keeps_the_presentation_timestamp():
    # updated_at is what the user's go is judged fresh against: bumping it
    # when the outcome is reported could reject a Next tapped just before.
    db = _Db()
    _start_on_explore_step(db)
    presented = time.time() - 60
    db.store[_STATE] = {**db.store[_STATE], "updated_at": presented}
    db.store[_EVENT] = {"index": 1, "event": "performed", "attempt": 1, "ts": presented + 5}
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["updated_at"] == presented
    assert db.store[_EVENT]["event"] == "performed"


def test_stale_performed_event_from_before_the_step_is_ignored():
    db = _Db()
    _start_on_explore_step(db)
    presented = time.time() - 60
    db.store[_STATE] = {**db.store[_STATE], "updated_at": presented}
    db.store[_EVENT] = {"index": 1, "event": "performed", "attempt": 1, "ts": presented - 30}
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "not tapped" in msg.lower()
    assert "performed" not in db.store[_STATE]


def test_failed_action_stays_on_the_step_and_says_so():
    db = _Db()
    _start_on_explore_step(db)
    _outcome(db, 1, event="action_failed")
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "did NOT open" in msg
    assert db.store[_STATE]["index"] == 1
    assert db.store[_PENDING]["index"] == 1
    assert db.store[_STATE]["performed"] is False


def test_retry_after_a_failure_is_a_new_outcome():
    db = _Db()
    _start_on_explore_step(db)
    _outcome(db, 1, event="action_failed", attempt=1)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    _outcome(db, 1, event="performed", attempt=2)
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert "is now open" in msg
    assert db.store[_STATE]["index"] == 1


def test_going_back_to_a_performed_step_starts_it_fresh():
    db = _Db()
    _start_on_explore_step(db)
    _outcome(db, 1)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    _run(guided_tour._bind_skip_guided_tour(db, "u1")())
    _run(guided_tour._bind_back_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 1
    assert "performed" not in db.store[_STATE]
    assert "reported_attempt" not in db.store[_STATE]


def test_plain_tap_on_an_action_step_from_an_older_client_still_advances():
    # An installed build that predates action steps sends 'tapped' after
    # pressing through; it must not strand on the step.
    db = _Db()
    _start_on_explore_step(db)
    _tap(db, 1)
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 2
    assert _steps()[2]["say"] in msg


def test_a_tap_on_a_step_never_triggers_a_screen_read():
    db = _Db()
    _start_on_explore_step(db)
    _tap(db, 1)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert {c["action"] for c in db.store.commands} == {"tour_step"}


def test_navigate_command_takes_the_resolved_path(monkeypatch):
    # The Appearance row opens the user's latest report when there is one.
    calls = []

    def _fake(db_, uid_, dest):
        calls.append(dest["key"])
        return "/appearance/current", "Appearance"

    monkeypatch.setattr(guided_tour, "_resolve_path", _fake)
    step = next(s for s in _steps() if s["anchor"] == "profile_appearance_row")
    assert guided_tour._step_command(_Db(), "u1", step) == {
        "action": "navigate",
        "screen": "my_appearance",
        "path": "/appearance/current",
    }
    assert calls == ["my_appearance"]


def test_manifest_commands_are_valid_and_cover_every_opening_step():
    destinations = {d["key"] for d in app_registry.destinations()}
    for s in _steps():
        assert "expect_screen" not in s and "expect_route" not in s
        command = s.get("command")
        if command is None:
            continue
        assert s["action"] == "tap"
        if command["action"] == "switch_tab":
            assert command["tab"] in (1, 2, 3)
        else:
            assert command["action"] == "navigate"
            assert command["screen"] in destinations
    by_anchor = {s["anchor"]: s for s in _steps()}
    assert by_anchor["explore_tab"]["command"]["tab"] == 1
    assert by_anchor["messages_tab"]["command"]["tab"] == 2
    assert by_anchor["profile_tab"]["command"]["tab"] == 3
    assert by_anchor["notifications_bell"]["command"]["screen"] == "notifications"


def test_steps_with_nothing_to_perform_have_no_command():
    by_anchor = {s["anchor"]: s for s in _steps()}
    assert "command" not in by_anchor["home_orb"]
    assert "command" not in by_anchor["home_composer"]
    assert "command" not in by_anchor["explore_search"]
    assert by_anchor["explore_search"]["action"] == "look"


def test_skip_tool_advances_without_any_tap():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    assert _EVENT not in db.store  # no tap ever happened
    msg = _run(guided_tour._bind_skip_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 1
    assert _steps()[1]["say"] in msg
    msg = _run(guided_tour._bind_skip_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 2
    assert _steps()[2]["say"] in msg


def test_skip_past_the_last_step_completes_the_tour():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    msg = ""
    for _ in range(len(_steps())):
        msg = _run(guided_tour._bind_skip_guided_tour(db, "u1")())
    assert "complete" in msg.lower()
    assert db.store[_STATE]["active"] is False
    assert db.store[_PENDING]["action"] == "tour_end"


def test_advance_consumes_a_card_skip_event():
    # The tour card's Next button writes a 'skip' event: advance moves on
    # without the step being performed.
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    _tap(db, 0, event="skip")
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 1
    assert _steps()[1]["say"] in msg


def test_advance_consumes_a_back_event():
    db = _Db()
    _run(guided_tour._bind_start_guided_tour(db, "u1")())
    _tap(db, 0)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    _tap(db, 1)
    _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 2
    _tap(db, 2, event="back")
    msg = _run(guided_tour._bind_advance_guided_tour(db, "u1")())
    assert db.store[_STATE]["index"] == 1
    assert _steps()[1]["say"] in msg


@pytest.mark.parametrize("phrase,expected", [
    ("next", "skip"),
    ("Next!", "skip"),
    ("skip", "skip"),
    ("skip this", "skip"),
    ("next one", "skip"),
    ("move on", "skip"),
    ("continue", "skip"),
    ("back", "back"),
    ("go back", "back"),
    ("previous", "back"),
    ("previous step", "back"),
    ("stop", "stop"),
    ("stop the tour", "stop"),
    ("end tour", "stop"),
    ("quit", "stop"),
])
def test_detect_tour_control_matches_bare_controls(phrase, expected):
    assert guided_tour.detect_tour_control(phrase) == expected


@pytest.mark.parametrize("phrase", [
    "what's next on the tour",
    "skip the line at the store",
    "go back to sleep",
    "next please tell me a joke",
    "stop by the store",
    "tell me about the tour",
    "",
])
def test_detect_tour_control_leaves_ordinary_speech_alone(phrase):
    assert guided_tour.detect_tour_control(phrase) is None


@pytest.mark.parametrize("phrase,expected", [
    ("next", "skip"),
    ("skip", "skip"),
    ("previous step", "back"),
    ("stop the tour", "stop"),
    ("end tour", "stop"),
    # Bare generic words are NOT claimed on the voice surface.
    ("stop", None),
    ("continue", None),
    ("back", None),
    ("go back", None),
    ("quit", None),
])
def test_detect_tour_control_voice_surface_is_restricted(phrase, expected):
    assert guided_tour.detect_tour_control(phrase, bare_ok=False) == expected


def test_deterministic_runners_drive_the_tour():
    # The text path's deterministic routing (main.py) speaks exactly the
    # presented step's line and moves the same state the tools move.
    db = _Db()
    reply = _run(guided_tour.run_start_tour_command(db, "u1"))
    assert reply == _steps()[0]["say"]
    reply = _run(guided_tour.run_tour_control_command(db, "u1", "skip"))
    assert reply == _steps()[1]["say"]
    assert db.store[_STATE]["index"] == 1
    reply = _run(guided_tour.run_tour_control_command(db, "u1", "back"))
    assert reply == _steps()[0]["say"]
    assert db.store[_STATE]["index"] == 0
    reply = _run(guided_tour.run_tour_control_command(db, "u1", "stop"))
    assert "ended" in reply.lower()
    assert db.store[_STATE]["active"] is False
    # No tour running: honest, no crash.
    reply = _run(guided_tour.run_tour_control_command(db, "u1", "skip"))
    assert "no tour running" in reply.lower()


def test_manifest_is_main_features_first_and_every_anchor_exists():
    steps = _steps()
    assert [s["anchor"] for s in steps[:5]] == [
        "home_orb",
        "explore_tab",
        "messages_tab",
        "profile_tab",
        "notifications_bell",
    ]
    assert len(steps) >= 15
    for s in steps:
        assert s.get("screen") and s.get("headline") and s.get("say")
        assert s.get("action") in ("tap", "look")
    from pathlib import Path

    anchors_src = (
        Path(__file__).resolve().parents[3]
        / "ayma_flutter"
        / "lib"
        / "services"
        / "tour_anchors.dart"
    ).read_text()
    for s in steps:
        assert s["anchor"] in anchors_src
