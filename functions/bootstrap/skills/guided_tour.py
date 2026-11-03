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
import time
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
_SPOTLIGHT_ACK_TIMEOUT_SECONDS = 8.0

# How long one ``advance`` waits for the user to tap the spotlighted control
# before returning a gentle "still waiting" (the tap event persists, so the
# next advance picks it up — a timeout never loses progress). Under the text
# tool-call cap (gemini.py ``_TOOL_TIMEOUT_SECONDS`` = 120s) so it returns
# honestly in /chat too; voice has no such cap.
_TAP_TIMEOUT_SECONDS = 110.0
_TAP_POLL_SECONDS = 0.4


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


async def _await_tour_event(db, uid: str, index: int, timeout: float) -> dict | None:
    """Poll the ``tour_event`` doc until the client reports the user tapped the
    spotlighted control (``event='tapped'``) or ended it (``event='stop'``) for
    THIS ``index``, or the bounded wait runs out. Returns the event dict or
    ``None`` on timeout. Reads run off the event loop so live audio is never
    blocked."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            snap = await asyncio.to_thread(_event_doc(db, uid).get)
            data = snap.to_dict() if getattr(snap, "exists", False) else None
        except Exception:  # noqa: BLE001
            data = None
        if data and int(data.get("index", -1)) == index and data.get("event"):
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


async def _spotlight(db, uid: str, index: int, total: int, step: dict) -> bool:
    """Queue one ``tour_step`` command and wait for the client to confirm the
    spotlight is up (``True``) or report the anchor absent / no ack
    (``False`` → caller skips the step honestly)."""
    cmd_id = _queue_command(db, uid, _step_payload(index, total, step))
    ack = await _await_ack(db, uid, cmd_id, timeout=_SPOTLIGHT_ACK_TIMEOUT_SECONDS)
    return bool(ack and ack.get("ok"))


async def _present_from(db, uid: str, start: int) -> tuple[int, dict | None]:
    """Spotlight the first presentable step at or after ``start`` (skipping any
    whose anchor the client reports absent). Returns ``(index, step)`` on
    success, or ``(-1, None)`` when no further step can be shown. Clears the tap
    event and records the shown index on the state doc."""
    steps = _steps()
    total = len(steps)
    i = start
    while 0 <= i < total:
        await asyncio.to_thread(_clear_event, db, uid)
        if await _spotlight(db, uid, i, total, steps[i]):
            await asyncio.to_thread(_write_state, db, uid, i, True)
            return i, steps[i]
        logger.info("guided tour: step %d anchor absent — skipping", i)
        i += 1
    return -1, None


async def _end(db, uid: str) -> None:
    """Dismiss the client overlay and mark the tour inactive."""
    _queue_command(db, uid, {"action": "tour_end"})
    await asyncio.to_thread(_write_state, db, uid, -1, False)
    await asyncio.to_thread(_clear_event, db, uid)


def _say_directive(index: int, total: int, step: dict) -> str:
    """The tool result handed back to the model: the script line to speak (in
    her own voice) plus what to do next. Operational directive, not script copy
    — the copy itself comes from the registry (``step['say']``)."""
    return (
        f"Guided tour — step {index + 1} of {total} is now spotlighted. "
        f"Say ONLY this to the user, warmly and in your own voice, about THIS "
        f"highlighted control (don't mention any other feature yet): "
        f"\"{step['say']}\" Then call advance_guided_tour — it waits until they "
        "actually TAP the highlighted control and moves on ONLY then. Do NOT "
        "advance on a spoken 'next' / 'what's next' / 'okay' — those do not move "
        "the tour; if they say that, gently tell them to tap the highlighted "
        "control. Only call stop_guided_tour if they ask to stop or quit."
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


# --- start --------------------------------------------------------------------


def _bind_start_guided_tour(db, uid: str) -> Callable[..., object]:
    async def start_guided_tour() -> str:
        steps = _steps()
        if not steps:
            return _NO_STEPS
        index, step = await _present_from(db, uid, 0)
        if step is None:
            await _end(db, uid)
            return _NOT_SHOWN
        return _say_directive(index, len(steps), step)

    return start_guided_tour


# --- advance ------------------------------------------------------------------


def _bind_advance_guided_tour(db, uid: str) -> Callable[..., object]:
    async def advance_guided_tour() -> str:
        # Advancement is gated STRICTLY on the user's real tap of the currently
        # spotlighted control — never on a spoken/typed "next" and never on the
        # model's own choice to call this tool (founder, 2026-11-03: "it is
        # moving to the next step even without the user acknowledging that he
        # did that"). There is deliberately no skip parameter: this tool returns
        # the next step ONLY after the client reports the tap event for the
        # current step; otherwise it returns an honest "still waiting" and the
        # tour stays put.
        steps = _steps()
        total = len(steps)
        state = await asyncio.to_thread(_read_state, db, uid)
        if not state.get("active"):
            return _NO_TOUR
        current = int(state.get("index", -1))
        event = await _await_tour_event(db, uid, current, _TAP_TIMEOUT_SECONDS)
        if event is None:
            step = steps[current] if 0 <= current < total else {}
            control = str(step.get("headline") or "the highlighted control")
            return (
                f"Still on step {current + 1} — the user has NOT tapped "
                f"{control!r} yet, so the tour has NOT moved. Gently tell them to "
                "tap the highlighted control to continue (a spoken 'next' does not "
                "advance it), or that they can say stop to end the tour. Do not "
                "claim they moved on."
            )
        if str(event.get("event")) == "stop":
            await _end(db, uid)
            return (
                "The user ended the guided tour. Acknowledge warmly and let "
                "them know they can ask for it again anytime."
            )
        index, step = await _present_from(db, uid, current + 1)
        if step is None:
            await _end(db, uid)
            return (
                "That was the last step — the guided tour is complete. Wrap up "
                "warmly and invite them to ask you anything."
            )
        return _say_directive(index, total, step)

    return advance_guided_tour


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
        # when the user taps the spotlighted control.
        "parameters": {"type": "object", "properties": {}},
    },
    bind=_bind_advance_guided_tour,
)

STOP_GUIDED_TOUR = Skill(
    declaration={
        "name": "stop_guided_tour",
        "description": _prompt("stop_guided_tour"),
        "parameters": {"type": "object", "properties": {}},
    },
    bind=_bind_stop_guided_tour,
)

SKILLS: list[Skill] = [START_GUIDED_TOUR, ADVANCE_GUIDED_TOUR, STOP_GUIDED_TOUR]
