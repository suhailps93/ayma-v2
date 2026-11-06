"""Inactivity watchdog: ends a forgotten voice call (LiveKit billing guard)."""

import asyncio
import time

from idle_watchdog import IdleWatchdog


class _Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


def _watchdog(clock, timeout=180):
    fired = []

    async def _on_idle():
        fired.append(True)

    return IdleWatchdog(timeout, _on_idle, clock=clock), fired


def test_not_idle_before_window_and_idle_after():
    clock = _Clock()
    wd, _ = _watchdog(clock)
    clock.advance(179)
    assert not wd.is_idle()
    clock.advance(1)
    assert wd.is_idle()


def test_touch_resets_the_window():
    clock = _Clock()
    wd, _ = _watchdog(clock)
    clock.advance(170)
    wd.touch()
    clock.advance(170)
    assert not wd.is_idle()
    clock.advance(10)
    assert wd.is_idle()


def test_agent_speaking_or_thinking_is_never_idle_and_window_restarts_after():
    clock = _Clock()
    wd, _ = _watchdog(clock)
    wd.set_agent_state("speaking")
    clock.advance(600)
    assert not wd.is_idle()
    wd.set_agent_state("listening")
    clock.advance(179)
    assert not wd.is_idle()
    clock.advance(1)
    assert wd.is_idle()


def test_muted_session_still_goes_idle_without_user_activity():
    # "Shut up" mute only suppresses replies; nothing touches the watchdog, so
    # a muted forgotten call times out like any other.
    clock = _Clock()
    wd, _ = _watchdog(clock)
    wd.set_agent_state("listening")
    clock.advance(181)
    assert wd.is_idle()


def test_run_fires_on_idle_once_when_window_elapses():
    wd, fired = _watchdog(time.monotonic, timeout=0.05)
    asyncio.run(asyncio.wait_for(wd.run(), timeout=2))
    assert fired == [True]


def test_run_does_not_fire_while_activity_continues():
    wd, fired = _watchdog(time.monotonic, timeout=0.2)

    async def _scenario():
        wd.start()
        for _ in range(6):
            await asyncio.sleep(0.05)
            wd.touch()
        assert fired == []
        wd.stop()
        await asyncio.sleep(0.01)

    asyncio.run(_scenario())
    assert fired == []


def test_on_idle_failure_is_swallowed():
    async def _boom():
        raise RuntimeError("nope")

    wd = IdleWatchdog(0.01, _boom)
    asyncio.run(asyncio.wait_for(wd.run(), timeout=2))


def test_warm_call_second_idle_timeout_fires_at_spec():
    """Regression test for F1 (deltareview42 H1): a warm (repeat) voice call
    constructs its watchdog before session setup and only starts it once the
    session is live. The 30s window must be measured from start(), not from
    construction — otherwise the fire lands ~19-23s after the session goes
    live (seven on-device measurements on 2321).

    Simulates the production sequence with a fake clock: construct, advance
    10s (session setup), start, then check the window is baselined at start.
    Without the start() re-baseline this fails: 20s after start the watchdog
    already reads idle (30s after construction).
    """
    clock = _Clock()
    wd, fired = _watchdog(clock, timeout=30)
    clock.advance(10)  # session setup between construction and start

    async def _scenario():
        wd.start()
        try:
            # 20s after start: only 20s into the live window, must not be idle.
            clock.advance(20)
            assert not wd.is_idle()
            assert wd.seconds_until_idle() == 10
            assert fired == []
            # 30s after start: the window has elapsed.
            clock.advance(10)
            assert wd.is_idle()
            assert wd.seconds_until_idle() == 0
        finally:
            wd.stop()
            await asyncio.sleep(0.01)

    asyncio.run(_scenario())
