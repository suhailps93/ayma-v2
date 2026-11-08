"""Ayma-DRIVEN interactive tour (ARCHITECTURE.md §11.2b, rewired 2026-11-07).

A predefined, PRIORITIZED walkthrough Ayma narrates step by step — the main
features first, then each screen's own controls. The order and Ayma's per-step
lines live as DATA in ``app_registry.json`` (``guided_tour.steps``, read via
``app_registry.guided_tour_steps``), never inline here. Every step names its
screen, its target control (anchor), what Ayma says, and the expected action
(``tap`` the highlighted control, or just ``look``).

THE REWIRE (founder, 2026-11-07): the old tour trusted the client to put itself
on the right screen and SKIPPED any step whose anchor was absent — so a user
on the wrong screen watched the tour blind-skip through its steps straight to
the end (the Nov 5 failure). Now the tour LOOKS before it highlights:

* ``tour_step`` is acked ``ok=true`` ONLY when the client has verified the
  user is actually on the step's screen AND the anchor is mounted there —
  the spotlight is then drawn at the anchor's real measured rect. Nothing is
  ever highlighted blind.
* ``ok=false`` with ``reason='not_on_screen'`` (plus where the user actually
  is) makes the backend NAVIGATE to the step's screen through the shared
  app-command queue and retry the SAME step. A step is skipped only when the
  client confirms the user IS on its screen but the control is genuinely
  absent (``reason='anchor_absent'`` — a gated feature), or when the step
  can't be done in the current mode (``skip_in_voice``).

ACTION-DRIVEN STEPS (founder, 2026-11-08): nothing guesses where a tap landed
any more. A step with a ``command`` in the registry is performed by Ayma: the
client intercepts the tap on the highlight (it never reaches the real control),
runs that command through the app-command handlers and reports the confirmed
outcome on ``tour_event`` — ``performed``, or ``action_failed`` (the tour stays
on the step, says so plainly and the user can tap again). The tour is
USER-PACED: a performed step does NOT advance. It waits for the user's go (Next
on the card, or a spoken/typed "next"), with no timed advance anywhere. On a
live call the go is spoken only, so nothing ever needs a tap near the orb.

Turn-taking (why several tools, one step per call): Ayma must say each step's
line in her OWN voice between steps, in BOTH text and voice, so a single
blocking call that drove the whole tour could never narrate per step:

* ``start_guided_tour`` begins the tour, spotlights step 0 and returns its
  line for Ayma to speak;
* ``advance_guided_tour`` WAITS (bounded) for the user's response to the
  currently spotlighted step: a performed or failed action (reported once,
  the step stays), a tap on a step with nothing to perform (``tapped``), the
  card's Next (``skip``), a card/back signal (``back``) or ``stop``;
* ``skip_guided_tour`` moves past the current step (the user's spoken/typed
  "next" / "skip" — the go after a performed step, or a move on without it);
* ``back_guided_tour`` returns to the previous step;
* ``stop_guided_tour`` ends the tour on request (state inactive server-side).

Reuses the shared app-command loop (``_queue_command`` / ``_await_ack`` over
``users/{uid}/app_commands/{pending,ack}``); the user's response comes back
on a dedicated ``tour_event`` doc; the current step index is held on a
``tour_state`` doc so each tool call knows where we are.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from datetime import datetime, timezone
from typing import Callable

import app_registry

from ._base import Skill
from .app_control_navigation import _resolve_path
from .app_control_queue import (
    _await_ack,
    _prompt,
    _queue_command,
    _server_ts,
)

logger = logging.getLogger("ayma.guided_tour")

# How long to wait for the client to confirm a step is spotlighted (ok) or
# report where the user actually is (ok=false). A step can switch tab + pop a
# pushed sub-page before its anchor lays out, so this rides out more than a
# plain navigate; still bounded, so a dead client never hangs the turn.
_SPOTLIGHT_ACK_TIMEOUT_SECONDS = 10.0

# How many times one step presentation may navigate-and-retry after a
# 'not_on_screen' report before giving up honestly (never skipping).
_NAV_RETRIES = 1

# How long one ``advance`` waits for the user to respond to the spotlighted
# step before returning a gentle "still waiting" (the event persists, so the
# next advance picks it up — a timeout never loses progress).
_TAP_TIMEOUT_SECONDS = 110.0  # voice: the long quiet wait (no cap pressure)
# Text (/chat) binds this shorter bound instead (Antigravity review
# 2026-11-03): one turn must not hold its HTTP request open for ~2min. Still
# far under the 120s tool cap with headroom for the reply round-trip; a lapse
# reports honestly and the next advance resumes, so nothing is lost.
_TAP_TIMEOUT_SYNC_SECONDS = 25.0
_TAP_POLL_SECONDS = 0.4
# Once a step's action has been performed and reported, there is nothing left
# to wait on but the user's go, which reaches the backend on its own (the
# skip tool, or Next's event + kick). An ``advance`` then only checks briefly
# for a Next already on its way, instead of holding a turn open.
_GO_CHECK_SECONDS = 3.0

# The client's report of a step's command: consumed once per attempt, and the
# step stays where it is.
_OUTCOME_EVENTS = ("performed", "action_failed")

# How long a tour state counts as live. ``tour_state`` kept ``active:true``
# forever across app kills, so a later ``advance`` polled a dead overlay for
# the full tap wait (Antigravity review 2026-11-03) — state older than this is
# expired instead: the orphan is dismissed and cleared, honestly, without
# waiting. Only a provably old state expires (see ``_state_expired``).
_TOUR_STATE_TTL_SECONDS = 15 * 60


# --- firestore docs -----------------------------------------------------------


def _event_doc(db, uid: str):
    return (
        db.collection("users").document(uid)
        .collection("app_commands").document("tour_event")
    )


def _state_doc(db, uid: str):
    return (
        db.collection("users").document(uid)
        .collection("app_commands").document("tour_state")
    )


def _read_state(db, uid: str) -> dict:
    try:
        snap = _state_doc(db, uid).get()
        return snap.to_dict() or {} if getattr(snap, "exists", False) else {}
    except Exception:  # noqa: BLE001 - a missing/unreadable doc is "no tour"
        return {}


def _index_of(data: dict, default: int = -1) -> int:
    """A Firestore ``index`` that may be missing, explicitly null, or garbage —
    never raises. ``None`` needs an explicit check: ``or`` would also swallow
    the valid step ``0`` (Antigravity review 2026-11-03)."""
    value = data.get("index", default)
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _updated_epoch(value: object) -> float | None:
    """Epoch seconds for a Firestore ``updated_at``, or ``None`` when it can't
    be read (missing, an unresolved server-timestamp sentinel, or anything
    unexpected — treated as fresh: only a provably old state expires)."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, datetime):
        aware = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        return aware.timestamp()
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            dt = datetime.fromisoformat(value)
            aware = dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
            return aware.timestamp()
        except Exception:  # noqa: BLE001
            return None
    to_dt = getattr(value, "to_datetime", None)
    if callable(to_dt):
        try:
            return _updated_epoch(to_dt())
        except Exception:  # noqa: BLE001
            return None
    return None


def _is_event_fresh(event: dict, state_updated_at: object) -> bool:
    """Whether a ``tour_event`` is fresh relative to the tour state's
    ``updated_at`` (the step presentation timestamp).

    An unconsumed tap or stop event left behind by an earlier tour (or an
    earlier run of this step before a presentation race) has ``ts < updated_at``
    and must be ignored rather than auto-advancing the new tour. If the state
    timestamp cannot be resolved (e.g. an undated legacy state doc or an
    unresolved server-timestamp sentinel in a test), the event is treated as
    fresh to preserve backwards compatibility. If the state timestamp is
    resolved but the event has no timestamp, it is considered stale."""
    state_epoch = _updated_epoch(state_updated_at)
    if state_epoch is None:
        return True
    event_epoch = _updated_epoch(event.get("ts"))
    if event_epoch is None:
        return False
    return event_epoch >= state_epoch


def _state_expired(state: dict) -> bool:
    """Whether an ACTIVE tour state is older than the TTL — an orphan from an
    app killed mid-tour (or a user who walked away): the overlay it points at
    is long gone, so advancing must expire it, not poll it."""
    epoch = _updated_epoch(state.get("updated_at"))
    if epoch is None:
        return False
    return (time.time() - epoch) > _TOUR_STATE_TTL_SECONDS


def _write_state(
    db, uid: str, index: int, active: bool, step: dict | None = None
) -> None:
    doc = {"index": index, "active": active, "updated_at": _server_ts()}
    if step is not None:
        # The current stop's line, kept on the state so the deterministic
        # text runners can answer with it verbatim (no model in that loop).
        doc["headline"] = str(step.get("headline") or "")
        doc["say"] = str(step.get("say") or "")
        doc["screen"] = str(step.get("screen") or "")
    _state_doc(db, uid).set(doc)


def _clear_event(db, uid: str) -> None:
    """Drop any stale tour event so the next wait can only see the user's
    response to the step we're about to show."""
    try:
        _event_doc(db, uid).delete()
    except Exception:  # noqa: BLE001
        pass


def _outcome_reported(db, uid: str, event: dict) -> bool:
    """Whether this ``performed``/``action_failed`` attempt was already handed
    to Ayma. The event doc is left in place (deleting it could swallow a Next
    written in the same instant), so without this she would narrate it again
    on every ``advance``."""
    state = _read_state(db, uid)
    return (
        "reported_attempt" in state
        and event.get("attempt") == state.get("reported_attempt")
    )


def _mark_outcome_reported(db, uid: str, event: dict) -> None:
    """Record the attempt on the state, leaving ``updated_at`` alone: that is
    the presentation timestamp ``_is_event_fresh`` compares the user's go
    against, and the TTL's clock."""
    _state_doc(db, uid).set(
        {
            "reported_attempt": event.get("attempt"),
            "performed": event.get("event") == "performed",
        },
        merge=True,
    )


_UNSET = object()


async def _await_tour_event(
    db, uid: str, index: int, timeout: float, state_updated_at: object = _UNSET
) -> dict | None:
    """Poll the ``tour_event`` doc until the client reports the user's
    response to THIS ``index`` — ``performed`` / ``action_failed`` (the step's
    command ran, or didn't; each attempt counts once), ``tapped`` (a step with
    nothing to perform), ``skip`` (the card's Next), ``back`` or ``stop`` — or
    the bounded wait runs out.
    Returns the event dict or ``None`` on timeout. Reads run off the event
    loop so live audio is never blocked.

    The event's timestamp must be fresh relative to ``state_updated_at``
    (the step presentation timestamp) — an unconsumed event left behind by
    a prior tour at the same index is ignored rather than moving the new
    tour prematurely."""
    if state_updated_at is _UNSET:
        state = await asyncio.to_thread(_read_state, db, uid)
        state_updated_at = state.get("updated_at")
    deadline = time.monotonic() + timeout
    while True:
        try:
            snap = await asyncio.to_thread(_event_doc(db, uid).get)
            data = snap.to_dict() if getattr(snap, "exists", False) else None
        except Exception:  # noqa: BLE001
            data = None
        if (
            data
            and _index_of(data) == index
            and data.get("event")
            and _is_event_fresh(data, state_updated_at)
            and not (
                data.get("event") in _OUTCOME_EVENTS
                and await asyncio.to_thread(_outcome_reported, db, uid, data)
            )
        ):
            return data
        if time.monotonic() >= deadline:
            return None
        await asyncio.sleep(_TAP_POLL_SECONDS)


# --- the manifest ---------------------------------------------------------------


def _steps() -> list[dict]:
    return app_registry.guided_tour_steps()


def _step_payload(
    index: int, total: int, step: dict, command: dict | None = None
) -> dict:
    return {
        "action": "tour_step",
        "index": index,
        "total": total,
        "anchor": step.get("anchor"),
        "tab": step.get("tab"),
        "route": step.get("route"),
        "screen": step.get("screen"),
        "headline": str(step.get("headline") or ""),
        "say": str(step.get("say") or ""),
        "command": command,
    }


def _destination(key: str) -> dict | None:
    for dest in app_registry.destinations():
        if str(dest.get("key") or "") == key:
            return dest
    return None


def _step_command(db, uid: str, step: dict) -> dict | None:
    """The app command Ayma performs for this step, or ``None`` when there is
    nothing to perform. A ``navigate`` names a destination key and takes its
    path from the same resolver ``open_screen`` uses, so the rows that open
    the user's latest report land exactly where the real row would."""
    command = step.get("command")
    if not isinstance(command, dict):
        return None
    if command.get("action") != "navigate":
        return dict(command)
    dest = _destination(str(command.get("screen") or ""))
    if dest is None:
        return None
    path, _ = _resolve_path(db, uid, dest)
    return {"action": "navigate", "screen": dest["key"], "path": path}


# --- screen reads + navigation (the look before the highlight) ------------------


async def _spotlight(
    db, uid: str, index: int, total: int, step: dict
) -> dict | None:
    """Queue one ``tour_step`` command and wait for its ack. The ack is the
    client's LOOK at the user's real screen: ``ok=true`` only when the user
    is on the step's screen and the anchor is mounted there (the spotlight
    is then up, at the anchor's measured rect); ``ok=false`` carries
    ``reason`` ('not_on_screen' / 'anchor_absent') plus where the user
    actually is. Returns ``None`` when the client never acked (timeout)."""
    command = await asyncio.to_thread(_step_command, db, uid, step)
    cmd_id = _queue_command(db, uid, _step_payload(index, total, step, command))
    return await _await_ack(
        db, uid, cmd_id, timeout=_SPOTLIGHT_ACK_TIMEOUT_SECONDS
    )


async def _navigate_to_step_screen(db, uid: str, step: dict) -> bool:
    """Get the user to the screen a step lives on, through the same
    ack-gated navigation command the open_screen tools use (the client acks
    only once the destination is actually visible)."""
    key = str(step.get("screen") or "")
    dest = _destination(key) if key else None
    if dest is None:
        return False
    path = str(step.get("route") or dest.get("path") or "")
    cmd_id = _queue_command(
        db, uid, {"action": "navigate", "screen": dest["key"], "path": path}
    )
    ack = await _await_ack(db, uid, cmd_id)
    return bool(ack and ack.get("ok"))


def _skip_in_voice(step: dict, voice: bool) -> bool:
    """True when this step can't be completed in the current mode. In a VOICE
    session the chat composer is the call bar (mute / status / Stop), not a text
    box, so a "tap the message box to type" step is both wrong and destructive —
    it is marked ``skip_in_voice`` in the registry and dropped here (founder,
    2026-11-03). The nav-bar tabs/bell/orb and Profile rows are tappable in both
    modes, so only the composer step carries the flag."""
    return bool(voice and step.get("skip_in_voice"))


async def _present_step(
    db, uid: str, index: int, voice: bool = False
) -> tuple[str, dict | None]:
    """Present exactly ONE step, looking before highlighting:

    * ``("shown", step)`` — the client confirmed the user is on the step's
      screen, the anchor is mounted there, and the spotlight is up;
    * ``("absent", None)`` — the client confirmed the user IS on the step's
      screen but the control is genuinely not there (a gated feature): the
      ONLY case a step may be skipped;
    * ``("blocked", None)`` — the step could not be shown and must NOT be
      skipped past: the client never acked, or it reported the user on a
      different screen and the get-there navigation did not land.
    """
    steps = _steps()
    total = len(steps)
    step = steps[index]
    for attempt in range(_NAV_RETRIES + 1):
        await asyncio.to_thread(_clear_event, db, uid)
        # Record the step's presentation timestamp BEFORE the spotlight is
        # shown, so it is earlier than any response the user can make:
        # otherwise a fast tapper's tour_event.ts lands before
        # state.updated_at and _is_event_fresh wrongly rejects it
        # (founder/Scout, 2026-11-03). On a get-there retry the next
        # iteration overwrites this with the step actually shown.
        await asyncio.to_thread(_write_state, db, uid, index, True, step)
        ack = await _spotlight(db, uid, index, total, step)
        if ack is None:
            # Client never acked: a step must NOT advance without its ack.
            logger.warning(
                "guided tour: step %d spotlight un-acked — not advancing", index
            )
            return "blocked", None
        if ack.get("ok"):
            return "shown", step
        reason = str(ack.get("reason") or "")
        if reason == "not_on_screen":
            # The user is somewhere else. NEVER skip: get them to the
            # step's screen first, then look again.
            logger.info(
                "guided tour: step %d — user on %r/%r, not %r; navigating first",
                index,
                ack.get("screen"),
                ack.get("route"),
                step.get("screen"),
            )
            if attempt < _NAV_RETRIES and await _navigate_to_step_screen(
                db, uid, step
            ):
                continue
            logger.warning(
                "guided tour: step %d get-there navigation did not land", index
            )
            return "blocked", None
        # ok=false without 'not_on_screen': the client verified the user is
        # on the step's screen but the anchor is absent there (older clients
        # only ever reported false for exactly this). The one honest skip.
        logger.info(
            "guided tour: step %d anchor absent on its own screen — skipping",
            index,
        )
        return "absent", None
    return "blocked", None


async def _present_from(
    db, uid: str, start: int, voice: bool = False
) -> tuple[int, dict | None]:
    """Present the first showable step at or after ``start`` — skipping only
    steps that can't be done in the current mode (``skip_in_voice``) or whose
    anchor is confirmed absent ON its own screen. Returns ``(index, step)``
    on success, ``(-2, None)`` when a step was blocked (un-acked or the
    get-there navigation failed — the caller must not move past it), or
    ``(-1, None)`` when no further step can be shown."""
    steps = _steps()
    total = len(steps)
    i = start
    while 0 <= i < total:
        if _skip_in_voice(steps[i], voice):
            logger.info("guided tour: step %d not available in voice — skipping", i)
            i += 1
            continue
        status, step = await _present_step(db, uid, i, voice)
        if status == "shown":
            return i, step
        if status == "absent":
            i += 1
            continue
        return -2, None
    return -1, None


async def _end(db, uid: str) -> None:
    """Dismiss the client overlay and mark the tour inactive."""
    _queue_command(db, uid, {"action": "tour_end"})
    await asyncio.to_thread(_write_state, db, uid, -1, False)
    await asyncio.to_thread(_clear_event, db, uid)


async def consume_stop_if_pending(db, uid: str) -> bool:
    """Consume an unconsumed 'stop' tour_event in text chat if present (F2).
    If the client wrote a stop event while a tour was active, end the tour
    server-side so tour_state doesn't linger active:true. Returns True if
    a stop event was consumed."""
    try:
        snap = await asyncio.to_thread(_event_doc(db, uid).get)
        data = snap.to_dict() if getattr(snap, "exists", False) else None
        if data and str(data.get("event")) == "stop":
            await _end(db, uid)
            return True
    except Exception:  # noqa: BLE001
        pass
    return False


# --- model-facing directives ----------------------------------------------------

def _say_directive(index: int, total: int, step: dict) -> str:
    """The tool result handed back to the model: the script line to speak (in
    her own voice) plus what to do next. Operational directive, not script copy
    — the copy itself comes from the registry (``step['say']``)."""
    return (
        f"Guided tour — step {index + 1} of {total} is now spotlighted with its callout card. "
        f"Say ONLY this to the user, warmly and in your own voice, about THIS "
        f"highlighted control (don't mention any other feature yet): "
        f"\"{step['say']}\" Then call advance_guided_tour — it waits for them "
        "and tells you what happened. "
        "If they say 'next' or 'skip', call skip_guided_tour to move on. "
        "If they say 'back' or 'previous', call back_guided_tour to return to "
        "the previous step. "
        "Only call stop_guided_tour if they ask to stop or quit."
    )


def _go_prompt(voice: bool) -> str:
    return "say next" if voice else "tap Next"


def _performed_directive(index: int, total: int, step: dict, voice: bool) -> str:
    """The step's command ran and is confirmed. The tour stays here until the
    user's go — it never moves on by itself."""
    headline = str(step.get("headline") or "that")
    return (
        f"Guided tour — step {index + 1} of {total}: {headline!r} is now open, "
        "confirmed by the app. The tour has NOT moved on. In one short line, "
        f"invite them to have a look and to {_go_prompt(voice)} when they're "
        "ready. Do NOT call advance_guided_tour now — wait for them. When they "
        "say 'next' or 'skip', call skip_guided_tour."
    )


def _action_failed_directive(index: int, step: dict, voice: bool) -> str:
    """The step's command did not run: stay, and say so plainly."""
    headline = str(step.get("headline") or "that")
    return (
        f"Guided tour — step {index + 1}: {headline!r} did NOT open; the app "
        "reported the action failed. The tour has NOT moved on and the "
        "highlight is still up. Tell them plainly it didn't open, do not "
        "guess why, and invite them to tap the highlight to try again or "
        f"to {_go_prompt(voice)} to move on. Do NOT call advance_guided_tour "
        "now — wait for them."
    )


def _waiting_for_go(index: int) -> str:
    """Nothing new since the performed step was reported."""
    return (
        f"Still on step {index + 1} — it is open and the tour is waiting for "
        "the user's go. Do not repeat yourself; say nothing unless they speak. "
        "Do not call advance_guided_tour again. When they say 'next' or "
        "'skip', call skip_guided_tour."
    )


_NO_STEPS = (
    "The guided tour has no steps configured right now — tell the user it isn't "
    "available and offer to point things out yourself instead."
)
_NOT_SHOWN = (
    "The app didn't show the tour — tell the user it didn't start and offer to "
    "walk them through it in words instead."
)
_NO_TOUR = (
    "There's no guided tour running — call start_guided_tour first if the user "
    "wants the walkthrough."
)
_EXPIRED = (
    "That guided tour went quiet a while ago, so it has ended — tell the user "
    "it timed out and offer to start it over if they still want the walkthrough."
)
_COMPLETE = (
    "That was the last step — the guided tour is complete. Wrap up "
    "warmly and invite them to ask you anything."
)


def _still_waiting(current: int, steps: list[dict]) -> str:
    step = steps[current] if 0 <= current < len(steps) else {}
    control = str(step.get("headline") or "the highlighted control")
    return (
        f"Still on step {current + 1} — waiting for {control!r}. "
        "Gently tell them to tap the highlighted control to continue, "
        "or that they can say next / skip to move on, back for the previous "
        "step, or stop to end the tour."
    )


# --- state gate shared by advance / skip / back -----------------------------------


async def _gate(db, uid: str) -> tuple[dict, int, str | None]:
    """Validate the tour state for a move: returns ``(state, current,
    error)`` — ``error`` is a ready model directive when the move can't
    happen (no tour / expired / bad index)."""
    steps = _steps()
    state = await asyncio.to_thread(_read_state, db, uid)
    if not state.get("active"):
        return state, -1, _NO_TOUR
    if _state_expired(state):
        await _end(db, uid)
        return state, -1, _EXPIRED
    current = _index_of(state)
    if current < 0 or current >= len(steps):
        await _end(db, uid)
        return state, -1, _NO_TOUR
    return state, current, None


async def _present_next(db, uid: str, current: int, voice: bool) -> str:
    """Present the step after ``current`` (shared by advance and skip):
    completes the tour after the last showable step, stays put when a step
    is blocked, otherwise returns the next step's say directive."""
    steps = _steps()
    index, step = await _present_from(db, uid, current + 1, voice)
    if index == -2:
        # A step was blocked — do NOT move past it; stay on the current step.
        await asyncio.to_thread(
            _write_state, db, uid, current, True, steps[current]
        )
        return _still_waiting(current, steps)
    if step is None:
        await _end(db, uid)
        return _COMPLETE
    return _say_directive(index, len(steps), step)


# --- start --------------------------------------------------------------------


def _bind_start_guided_tour(db, uid: str, voice: bool = False) -> Callable[..., object]:
    async def start_guided_tour() -> str:
        steps = _steps()
        if not steps:
            return _NO_STEPS
        state = await asyncio.to_thread(_read_state, db, uid)
        # F4: If a tour is already active, "next" / calling start continues from
        # the current step rather than restarting at step 0.
        if state.get("active") and not _state_expired(state):
            current = _index_of(state)
            if 0 <= current < len(steps):
                index, step = await _present_from(db, uid, current, voice)
                if index == -2:
                    # The failed attempt overwrote the state with the step it
                    # tried to show — put the recorded position back.
                    await asyncio.to_thread(
                        _write_state, db, uid, current, True, steps[current]
                    )
                    return (
                        f"Still on step {current + 1} — waiting for the app to show the highlight. "
                        "Gently tell the user to continue or say stop to end the tour."
                    )
                if step is not None:
                    return _say_directive(index, len(steps), step)
        index, step = await _present_from(db, uid, 0, voice)
        if index == -2 or step is None:
            await _end(db, uid)
            return _NOT_SHOWN
        return _say_directive(index, len(steps), step)

    return start_guided_tour


# --- advance ------------------------------------------------------------------


def _bind_advance_guided_tour(
    db, uid: str, voice: bool = False, tap_timeout: float | None = None
) -> Callable[..., object]:
    async def advance_guided_tour() -> str:
        # Waits for the user's response to the CURRENT step. A step's command
        # being performed (or failing) is reported to Ayma but never moves the
        # tour: only the user's go does — Next ('skip'), a tap on a step with
        # nothing to perform ('tapped'), or the spoken go via skip_guided_tour.
        steps = _steps()
        state, current, error = await _gate(db, uid)
        if error is not None:
            return error
        wait = _TAP_TIMEOUT_SECONDS if tap_timeout is None else tap_timeout
        performed = bool(state.get("performed"))
        if performed:
            wait = min(wait, _GO_CHECK_SECONDS)
        event = await _await_tour_event(
            db, uid, current, wait, state_updated_at=state.get("updated_at")
        )
        if event is None:
            if performed:
                return _waiting_for_go(current)
            step = steps[current]
            control = str(step.get("headline") or "the highlighted control")
            return (
                f"Still on step {current + 1} — the user has NOT tapped "
                f"{control!r} yet, so the tour has NOT moved. Gently tell them to "
                "tap the highlighted control (or Next on the card) to continue, "
                "or that they can say next / skip to move on, or stop to end "
                "the tour. Do not claim they moved on."
            )
        kind = str(event.get("event"))
        if kind == "stop":
            await _end(db, uid)
            return (
                "The user ended the guided tour. Acknowledge warmly and let "
                "them know they can ask for it again anytime."
            )
        if kind == "back":
            return await _present_previous(db, uid, current, voice)
        if kind == "skip":
            return await _present_next(db, uid, current, voice)
        if kind in _OUTCOME_EVENTS:
            await asyncio.to_thread(_mark_outcome_reported, db, uid, event)
            if kind == "performed":
                return _performed_directive(
                    current, len(steps), steps[current], voice
                )
            return _action_failed_directive(current, steps[current], voice)
        # 'tapped': a step with nothing to perform completes on the tap. An
        # older client still sends it for a step it pressed through to, so the
        # tour moves on, claiming nothing about where the user landed.
        return await _present_next(db, uid, current, voice)

    return advance_guided_tour


# --- skip ---------------------------------------------------------------------


def _bind_skip_guided_tour(
    db, uid: str, voice: bool = False
) -> Callable[..., object]:
    async def skip_guided_tour() -> str:
        # The user's "next" / "skip": move past the current step, whether or
        # not its action was performed (founder, 2026-11-07 — supersedes the
        # 2026-11-03 no-skip rule).
        state, current, error = await _gate(db, uid)
        if error is not None:
            return error
        return await _present_next(db, uid, current, voice)

    return skip_guided_tour


# --- back ---------------------------------------------------------------------


async def _present_previous(db, uid: str, current: int, voice: bool) -> str:
    """Present the step before ``current`` (exactly that step — a blocked or
    absent previous step never jumps forward past the current one)."""
    steps = _steps()
    if current <= 0:
        status, step = await _present_step(db, uid, 0, voice)
        if status == "shown" and step is not None:
            return _say_directive(0, len(steps), step)
        return _still_waiting(current, steps)
    prev = current - 1
    while prev > 0 and _skip_in_voice(steps[prev], voice):
        prev -= 1
    status, step = await _present_step(db, uid, prev, voice)
    if status == "shown" and step is not None:
        return _say_directive(prev, len(steps), step)
    # Couldn't show the previous step — the recorded position stays put.
    await asyncio.to_thread(
        _write_state, db, uid, current, True, steps[current]
    )
    return _still_waiting(current, steps)


def _bind_back_guided_tour(
    db, uid: str, voice: bool = False
) -> Callable[..., object]:
    async def back_guided_tour() -> str:
        state, current, error = await _gate(db, uid)
        if error is not None:
            return error
        return await _present_previous(db, uid, current, voice)

    return back_guided_tour


# --- stop ---------------------------------------------------------------------


def _bind_stop_guided_tour(db, uid: str) -> Callable[..., object]:
    async def stop_guided_tour() -> str:
        state = await asyncio.to_thread(_read_state, db, uid)
        await _end(db, uid)
        if not state.get("active"):
            return "There was no tour running — nothing to stop."
        return (
            "Ended the guided tour. Acknowledge briefly and warmly; they can ask "
            "for it again anytime."
        )

    return stop_guided_tour


# --- deterministic text runners (no model in the loop) -------------------------
#
# The /chat handler runs clear tour intents BEFORE the model (like the other
# deterministic app commands), so "walk me through the app" can never be
# answered with help prose instead of the tour itself (founder, 2026-11-07).
# The runners reuse the same bound tools; a say directive is translated to
# the presented step's own line (kept on tour_state by _present_step).


def _directive_reply(result: str, state: dict) -> str:
    """Translate a bound tool's model directive into the user-facing reply
    for a deterministic text turn."""
    if result.startswith("Guided tour — step"):
        say = str(state.get("say") or "").strip()
        if say:
            return say
    if "last step" in result and "complete" in result:
        return (
            "That's the whole tour — you have seen the main things. "
            "Ask me anything whenever you like."
        )
    if result.startswith("Still on step"):
        say = str(state.get("say") or "").strip()
        headline = str(state.get("headline") or "this step")
        if say:
            return f"Still on {headline} — {say}"
        return "Still on the current tour step — tap the highlighted control to continue."
    if "no guided tour running" in result or "no tour running" in result:
        return (
            "There's no tour running right now — say \"walk me through the "
            "app\" and I'll start one."
        )
    if "went quiet" in result:
        return (
            "That tour went quiet a while ago, so it ended. Say \"walk me "
            "through the app\" if you'd like to start it again."
        )
    if "didn't show" in result or "didn't start" in result:
        return (
            "I couldn't start the tour just now — the app didn't show the "
            "highlight. Try again in a moment."
        )
    if "no steps configured" in result:
        return "The guided tour isn't available right now."
    return result


async def run_start_tour_command(db, uid: str, voice: bool = False) -> str:
    """Deterministic text-path start: begin (or continue) the tour and
    answer with the first step's own line."""
    result = await _bind_start_guided_tour(db, uid, voice)()
    state = await asyncio.to_thread(_read_state, db, uid)
    return _directive_reply(str(result), state)


async def run_tour_control_command(db, uid: str, control: str) -> str:
    """Deterministic text-path tour control while a tour is active:
    ``skip`` / ``back`` / ``stop`` (see :func:`detect_tour_control`)."""
    if control == "stop":
        await _bind_stop_guided_tour(db, uid)()
        return "Ended the guided tour. Ask me anytime and I'll run it again."
    if control == "back":
        result = await _bind_back_guided_tour(db, uid)()
    else:
        result = await _bind_skip_guided_tour(db, uid)()
    state = await asyncio.to_thread(_read_state, db, uid)
    return _directive_reply(str(result), state)


# --- deterministic pre-model tour command matching ---------------------------

_TOUR_START_VERB = re.compile(
    r"\b(?:"
    r"start|begin|launch|restart|redo|kick\s+off|give\s+me|"
    r"open(?:\s+up)?|show(?:\s+me)?|go\s+to|take\s+me\s+to|"
    r"bring\s+(?:me\s+)?(?:up|to)|walk\s+me\s+through"
    r")\b",
    re.IGNORECASE,
)
_TOUR_STOP_VERB = re.compile(
    r"\b(?:stop|quit|end|exit|cancel|pause)\b", re.IGNORECASE
)


def detect_tour_command(message: str) -> str | None:
    """A clear, unambiguous "start the guided tour" command → the
    ``"start_guided_tour"`` tool name to run, else ``None``.

    Strict by design (so ordinary chat is never hijacked): requires a
    start/open verb AND a tour reference that resolves in ``app_registry``.
    "Open / show me the tour" starts it too — the tour is overlay-only, so an
    open is a start (the same redirect ``open_screen`` hands the model)."""
    m = (message or "").strip()
    if not m or len(m) > 200:
        return None
    if not _TOUR_START_VERB.search(m):
        return None
    if _TOUR_STOP_VERB.search(m):
        return None
    if app_registry.find_guided_tour(m) is None:
        return None
    return "start_guided_tour"


_TOUR_SKIP_WORDS = {
    "next", "skip", "next one", "skip this", "skip it", "continue",
    "go on", "move on", "next step",
}
_TOUR_BACK_WORDS = {
    "back", "go back", "previous", "previous step", "back one", "go back one",
}
_TOUR_STOP_WORDS = {
    "stop", "stop tour", "stop the tour", "end tour", "end the tour",
    "quit", "quit tour", "exit tour", "cancel tour", "pause tour",
}


# Voice-surface subsets: the voice dispatcher sees EVERY utterance, tour
# or not, so bare generic words ("stop", "continue", "back") must not be
# claimed there — "back" belongs to go_back (which runs earlier and is
# tour-aware) and "stop"/"continue" are ordinary speech outside a tour.
# The text path only consults the detector while a tour is active, so it
# may use the full sets.
_TOUR_SKIP_WORDS_VOICE = {
    "next", "skip", "next one", "skip this", "skip it", "next step",
}
_TOUR_BACK_WORDS_VOICE = {
    "previous", "previous step", "back one", "go back one",
}
_TOUR_STOP_WORDS_VOICE = {
    "stop tour", "stop the tour", "end tour", "end the tour",
    "quit tour", "exit tour", "cancel tour", "pause tour",
}


def detect_tour_control(message: str, *, bare_ok: bool = True) -> str | None:
    """A bare tour-control utterance → ``"skip"`` / ``"back"`` / ``"stop"``,
    else ``None``. Whole-utterance matching ONLY (a short message that is
    just the control word), so ordinary sentences containing "next" or
    "back" are never hijacked. Callers gate this on a tour being active
    (text) or use bare_ok=False (voice dispatch, which cannot check tour
    state first and so only claims tour-specific phrasings)."""
    m = re.sub(r"[\s.!?,]+$", "", (message or "").strip().lower())
    m = re.sub(r"\s+", " ", m)
    if not m or len(m) > 24:
        return None
    if bare_ok:
        skip, back, stop = _TOUR_SKIP_WORDS, _TOUR_BACK_WORDS, _TOUR_STOP_WORDS
    else:
        skip, back, stop = (
            _TOUR_SKIP_WORDS_VOICE,
            _TOUR_BACK_WORDS_VOICE,
            _TOUR_STOP_WORDS_VOICE,
        )
    if m in skip:
        return "skip"
    if m in back:
        return "back"
    if m in stop:
        return "stop"
    return None


# --- declarations -------------------------------------------------------------

START_GUIDED_TOUR = Skill(
    declaration={
        "name": "start_guided_tour",
        "description": _prompt("start_guided_tour"),
        "parameters": {"type": "object", "properties": {}},
    },
    bind=_bind_start_guided_tour,
)

ADVANCE_GUIDED_TOUR = Skill(
    declaration={
        "name": "advance_guided_tour",
        "description": _prompt("advance_guided_tour"),
        # No parameters by design: the tour advances ONLY when the user
        # responds to the current step (tap / card Next / back / stop) —
        # moving past a step without any tap is skip_guided_tour's job, and
        # it takes the user's own "next"/"skip" to call it.
        "parameters": {"type": "object", "properties": {}},
    },
    bind=_bind_advance_guided_tour,
)

SKIP_GUIDED_TOUR = Skill(
    declaration={
        "name": "skip_guided_tour",
        "description": _prompt("skip_guided_tour"),
        "parameters": {"type": "object", "properties": {}},
    },
    bind=_bind_skip_guided_tour,
)

BACK_GUIDED_TOUR = Skill(
    declaration={
        "name": "back_guided_tour",
        "description": _prompt("back_guided_tour"),
        "parameters": {"type": "object", "properties": {}},
    },
    bind=_bind_back_guided_tour,
)

STOP_GUIDED_TOUR = Skill(
    declaration={
        "name": "stop_guided_tour",
        "description": _prompt("stop_guided_tour"),
        "parameters": {"type": "object", "properties": {}},
    },
    bind=_bind_stop_guided_tour,
)

SKILLS: list[Skill] = [
    START_GUIDED_TOUR,
    ADVANCE_GUIDED_TOUR,
    SKIP_GUIDED_TOUR,
    BACK_GUIDED_TOUR,
    STOP_GUIDED_TOUR,
]
