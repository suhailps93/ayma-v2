"""Ayma-DRIVEN interactive tour (ARCHITECTURE.md §11.2b).

A predefined, ordered walkthrough Ayma narrates step by step: for each step she
opens the page/tab, SPOTLIGHTS the step's control (reusing the client's
coach-mark engine + ``tour_anchors``) and WAITS for the user to actually tap it
before moving on. This is additive to — and never replaces — the passive
coach-mark tour (``ayma_flutter/lib/services/tour_content.dart``).

The predefined order and Ayma's per-step lines live as DATA in
``app_registry.json`` (``guided_tour.steps``, read via
``app_registry.guided_tour_steps``), never inline here — so the script is edited
without touching code and stays one source of truth with the anchor registry.

Turn-taking (why three tools, one step per call): Ayma must say each step's line
in her OWN voice between steps, in BOTH text and voice, so a single blocking
call that drove the whole tour could never narrate per step. Instead:

* ``start_guided_tour`` begins the tour, spotlights step 0 and returns its line
  for Ayma to speak;
* ``advance_guided_tour`` WAITS (bounded) for the user to tap the control that is
  currently spotlighted, then spotlights the next step and returns its line —
  Ayma speaks it, then calls advance again; it ends gracefully after the last
  step. It advances ONLY on the real tap — there is no "skip", and a spoken
  "next" / "what's next" never moves the tour (founder, 2026-11-03);
* ``stop_guided_tour`` ends the tour on request.

Reuses the shared app-command loop (``_queue_command`` / ``_await_ack`` over
``users/{uid}/app_commands/{pending,ack}``): a ``tour_step`` command spotlights a
step and the client acks ``ok=true`` once it's shown or ``ok=false`` when the
anchor isn't present (so the backend SKIPS it honestly, never hanging). The
user's tap (or "stop") comes back on a dedicated ``tour_event`` doc; the current
step index is held on a ``tour_state`` doc so each tool call knows where we are.
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
from .app_control_queue import (
    _await_ack,
    _prompt,
    _queue_command,
    _server_ts,
)

logger = logging.getLogger("ayma.guided_tour")

# How long to wait for the client to confirm a step is spotlighted (ok) or its
# anchor is absent (ok=false). A step can switch tab + pop a pushed sub-page +
# scroll the anchor into view before it lays out, so this rides out more than a
# plain navigate; still bounded, so a dead client never hangs the turn.
_SPOTLIGHT_ACK_TIMEOUT_SECONDS = 10.0

# How long one ``advance`` waits for the user to tap the spotlighted control
# before returning a gentle "still waiting" (the tap event persists, so the
# next advance picks it up — a timeout never loses progress).
_TAP_TIMEOUT_SECONDS = 110.0  # voice: the long quiet wait (no cap pressure)
# Text (/chat) binds this shorter bound instead (Antigravity review
# 2026-11-03): one turn must not hold its HTTP request open for ~2min. Still
# far under the 120s tool cap with headroom for the reply round-trip; a lapse
# reports honestly and the next advance resumes, so nothing is lost.
_TAP_TIMEOUT_SYNC_SECONDS = 25.0
_TAP_POLL_SECONDS = 0.4

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


def _write_state(db, uid: str, index: int, active: bool) -> None:
    _state_doc(db, uid).set(
        {"index": index, "active": active, "updated_at": _server_ts()}
    )


def _clear_event(db, uid: str) -> None:
    """Drop any stale tap/stop event so the next wait can only see the user's
    response to the step we're about to show."""
    try:
        _event_doc(db, uid).delete()
    except Exception:  # noqa: BLE001
        pass


_UNSET = object()


async def _await_tour_event(
    db, uid: str, index: int, timeout: float, state_updated_at: object = _UNSET
) -> dict | None:
    """Poll the ``tour_event`` doc until the client reports the user tapped the
    spotlighted control (``event='tapped'``) or ended it (``event='stop'``) for
    THIS ``index``, or the bounded wait runs out. Returns the event dict or
    ``None`` on timeout. Reads run off the event loop so live audio is never
    blocked.

    The event's timestamp must be fresh relative to ``state_updated_at`` (the
    step presentation timestamp) — an unconsumed tap or stop event left behind
    by a prior tour at the same index is ignored rather than advancing the new
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
        ):
            return data
        if time.monotonic() >= deadline:
            return None
        await asyncio.sleep(_TAP_POLL_SECONDS)


# --- step presentation --------------------------------------------------------


def _steps() -> list[dict]:
    return app_registry.guided_tour_steps()


def _step_payload(index: int, total: int, step: dict) -> dict:
    return {
        "action": "tour_step",
        "index": index,
        "total": total,
        "anchor": step.get("anchor"),
        "tab": step.get("tab"),
        "headline": str(step.get("headline") or ""),
        "say": str(step.get("say") or ""),
    }


async def _spotlight(db, uid: str, index: int, total: int, step: dict) -> bool | None:
    """Queue one ``tour_step`` command and wait for the client to confirm the
    spotlight is up (``True``) or report the anchor absent (``False``).
    Returns ``None`` when the client never acked (timeout)."""
    cmd_id = _queue_command(db, uid, _step_payload(index, total, step))
    ack = await _await_ack(db, uid, cmd_id, timeout=_SPOTLIGHT_ACK_TIMEOUT_SECONDS)
    if ack is None:
        return None
    return bool(ack.get("ok"))


def _skip_in_voice(step: dict, voice: bool) -> bool:
    """True when this step can't be completed in the current mode. In a VOICE
    session the chat composer is the call bar (mute / status / Stop), not a text
    box, so a "tap the message box to type" step is both wrong and destructive —
    it is marked ``skip_in_voice`` in the registry and dropped here (founder,
    2026-11-03: the composer step hung / mis-fired when the tour ran during a
    voice call). The nav-bar tabs/bell/orb and Profile rows are tappable in both
    modes, so only the composer step carries the flag."""
    return bool(voice and step.get("skip_in_voice"))


async def _present_from(
    db, uid: str, start: int, voice: bool = False
) -> tuple[int, dict | None]:
    """Spotlight the first presentable step at or after ``start`` — skipping any
    whose anchor the client reports absent, and any that can't be done in the
    current mode (``skip_in_voice`` during a voice session). Returns
    ``(index, step)`` on success, ``(-2, None)`` when an attempted step timed out
    un-acked (so caller does not advance without ack), or ``(-1, None)`` when no
    further step can be shown. Clears the tap event and records the shown index
    on the state doc."""
    steps = _steps()
    total = len(steps)
    i = start
    while 0 <= i < total:
        if _skip_in_voice(steps[i], voice):
            logger.info("guided tour: step %d not available in voice — skipping", i)
            i += 1
            continue
        await asyncio.to_thread(_clear_event, db, uid)
        # Record the step's presentation timestamp BEFORE the spotlight is shown,
        # so it is earlier than any tap the user can make: otherwise a fast
        # tapper's tour_event.ts lands before state.updated_at and _is_event_fresh
        # wrongly rejects a real tap (founder/Scout, 2026-11-03). On an absent
        # anchor the next iteration overwrites this with the step actually shown.
        await asyncio.to_thread(_write_state, db, uid, i, True)
        res = await _spotlight(db, uid, i, total, steps[i])
        if res is True:
            return i, steps[i]
        elif res is False:
            logger.info("guided tour: step %d anchor absent — skipping", i)
            i += 1
            continue
        else:
            # Client never acked: F1 — a step must NOT advance without its ack!
            logger.warning("guided tour: step %d spotlight un-acked — not advancing", i)
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


def _say_directive(index: int, total: int, step: dict) -> str:
    """The tool result handed back to the model: the script line to speak (in
    her own voice) plus what to do next. Operational directive, not script copy
    — the copy itself comes from the registry (``step['say']``)."""
    return (
        f"Guided tour — step {index + 1} of {total} is now spotlighted with its callout card. "
        f"Say ONLY this to the user, warmly and in your own voice, about THIS "
        f"highlighted control (don't mention any other feature yet): "
        f"\"{step['say']}\" Then call advance_guided_tour — it waits until they "
        "actually TAP the highlighted control (or Next on the card) and moves on ONLY then. "
        "If they say 'next' or 'continue', continue the tour from this step. "
        "If they say 'back' or 'previous', call back_guided_tour to return to the previous step. "
        "Only call stop_guided_tour if they ask to stop or quit."
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
        # Advancement is gated STRICTLY on the user's real tap of the currently
        # spotlighted control (or tapping Next on the card) — never on the
        # model's own choice to call this tool. There is deliberately no skip
        # parameter: this tool returns the next step ONLY after the client reports
        # the tap event for the current step; otherwise it returns an honest "still waiting".
        steps = _steps()
        total = len(steps)
        state = await asyncio.to_thread(_read_state, db, uid)
        if not state.get("active"):
            return _NO_TOUR
        if _state_expired(state):
            await _end(db, uid)
            return _EXPIRED
        current = _index_of(state)
        if current < 0 or current >= total:
            await _end(db, uid)
            return _NO_TOUR
        wait = _TAP_TIMEOUT_SECONDS if tap_timeout is None else tap_timeout
        event = await _await_tour_event(
            db, uid, current, wait, state_updated_at=state.get("updated_at")
        )
        if event is None:
            step = steps[current] if 0 <= current < total else {}
            control = str(step.get("headline") or "the highlighted control")
            return (
                f"Still on step {current + 1} — the user has NOT tapped "
                f"{control!r} yet, so the tour has NOT moved. Gently tell them to "
                "tap the highlighted control (or Next on the card) to continue, "
                "or that they can say stop to end the tour. Do not "
                "claim they moved on."
            )
        if str(event.get("event")) == "stop":
            await _end(db, uid)
            return (
                "The user ended the guided tour. Acknowledge warmly and let "
                "them know they can ask for it again anytime."
            )
        index, step = await _present_from(db, uid, current + 1, voice)
        if index == -2:
            # F1: Step was un-acked — do NOT advance! Stay on current step and re-prompt.
            await asyncio.to_thread(_write_state, db, uid, current, True)
            cur_step = steps[current] if 0 <= current < total else {}
            control = str(cur_step.get("headline") or "the highlighted control")
            return (
                f"Still on step {current + 1} — waiting for {control!r}. "
                "Gently tell them to tap the highlighted control to continue, "
                "or say stop to end the tour."
            )
        if step is None:
            await _end(db, uid)
            return (
                "That was the last step — the guided tour is complete. Wrap up "
                "warmly and invite them to ask you anything."
            )
        return _say_directive(index, total, step)

    return advance_guided_tour


# --- back ---------------------------------------------------------------------


def _bind_back_guided_tour(
    db, uid: str, voice: bool = False
) -> Callable[..., object]:
    async def back_guided_tour() -> str:
        steps = _steps()
        total = len(steps)
        state = await asyncio.to_thread(_read_state, db, uid)
        if not state.get("active"):
            return _NO_TOUR
        if _state_expired(state):
            await _end(db, uid)
            return _EXPIRED
        current = _index_of(state)
        if current < 0:
            return _NO_TOUR
        prev_index = max(0, current - 1)
        index, step = await _present_from(db, uid, prev_index, voice)
        if index == -2 or step is None:
            await asyncio.to_thread(_write_state, db, uid, current, True)
            return (
                f"Still on step {current + 1} — could not move to the previous step. "
                "Gently tell the user to continue from the current step."
            )
        return _say_directive(index, total, step)

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
        # No parameters by design: there is no "skip" — the tour advances ONLY
        # when the user taps the spotlighted control or Next on the card.
        "parameters": {"type": "object", "properties": {}},
    },
    bind=_bind_advance_guided_tour,
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
    BACK_GUIDED_TOUR,
    STOP_GUIDED_TOUR,
]
