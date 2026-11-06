"""Inactivity watchdog for a voice session.

A LiveKit room bills participant-minutes for as long as anyone is connected,
so a call the user walked away from (phone left on a table, app forgotten with
the screen awake, Ayma muted by "shut up") must end on its own. The watchdog
holds a "last activity" timestamp that the agent bumps on every sign of life
and fires ``on_idle`` once the window passes with none.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Awaitable, Callable

logger = logging.getLogger(__name__)

# Agent states during which the call is plainly not idle (Ayma is mid-reply or
# working on one), however long that takes.
BUSY_AGENT_STATES = frozenset({"speaking", "thinking"})

_MAX_POLL_SECONDS = 5.0


class IdleWatchdog:
    def __init__(
        self,
        timeout_seconds: float,
        on_idle: Callable[[], Awaitable[None]],
        *,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._timeout = timeout_seconds
        self._on_idle = on_idle
        self._clock = clock
        self._last_activity = clock()
        self._busy = False
        self._task: asyncio.Task | None = None

    def touch(self) -> None:
        """Record activity: user speech, agent speech, a tool call, a data message."""
        self._last_activity = self._clock()

    def set_agent_state(self, state: str) -> None:
        """Feed the agent's state; speaking/thinking is activity, and the window
        restarts from the moment she stops."""
        self._busy = state in BUSY_AGENT_STATES
        self.touch()

    def seconds_until_idle(self) -> float:
        if self._busy:
            self.touch()
        return self._timeout - (self._clock() - self._last_activity)

    def is_idle(self) -> bool:
        return self.seconds_until_idle() <= 0

    async def run(self) -> None:
        """Wait until the window elapses with no activity, then fire ``on_idle`` once."""
        while True:
            remaining = self.seconds_until_idle()
            if remaining <= 0:
                break
            await asyncio.sleep(min(remaining, _MAX_POLL_SECONDS))
        fire_ts = self._clock()
        logger.info("idle watchdog FIRE: ts=%.3f last_activity_ts=%.3f elapsed=%.1fs", 
                    fire_ts, self._last_activity, fire_ts - self._last_activity)
        try:
            await self._on_idle()
        except Exception:  # noqa: BLE001 - never let the watchdog crash the job
            logger.exception("idle shutdown failed")

    def start(self) -> None:
        if self._task is None:
            # Re-baseline the window at start: the watchdog is constructed
            # before session setup and started only once the session is live,
            # so the construction-time stamp would fire the timer early (F1:
            # 19-23s after live instead of the 30s spec).
            self._last_activity = self._clock()
            arm_ts = self._last_activity
            logger.info("idle watchdog ARM: ts=%.3f timeout=%.1fs", arm_ts, self._timeout)
            self._task = asyncio.create_task(self.run())

    def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            self._task = None
