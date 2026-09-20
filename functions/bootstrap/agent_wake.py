""""Wake" ping for the scale-to-zero ``ayma-agent`` Cloud Run service.

Background (2026-09-19 founder decision to stop paying for ``ayma-agent``'s
24/7 idle compute — ``docs/deploy.md`` §12.2): Cloud Run only starts a new
instance in response to inbound HTTP traffic hitting the service's *own*
URL. Nothing in the voice-call flow ever does that — ``/bootstrap`` and
``/welcome/token`` talk directly to LiveKit Cloud (minting a token, creating
the room) and LiveKit's automatic agent dispatch is a *push* from LiveKit
Cloud to whichever workers are already registered over their own outbound
connection. So with ``min-instances=0`` and no wake mechanism, a scaled-down
``ayma-agent`` would never be started by a voice-call attempt at all — this
was the actual root cause the first time scale-to-zero was tried (see the
git history on ``docs/deploy.md`` / ``scripts/deploy-agent.sh``, Step 72),
not merely "cold start is too slow".

This module is the fix: fire an authenticated GET at ``ayma-agent``'s own
Cloud Run URL the moment a voice call starts, in parallel with (not
blocking) the LiveKit token mint + room creation, so Cloud Run begins
booting the container as early as possible — racing the client's own
connect + mic-publish steps instead of starting only after they finish.
LiveKit Cloud's automatic dispatch queues an unrouted job for a short window
rather than failing instantly (confirmed via LiveKit's own "non-production /
scale-to-zero agent" hosting tier, which relies on exactly this same
race — see PLAN.md notes from the 2026-09-19 investigation), so a worker
that finishes registering a few seconds after the room was created can still
receive the dispatch.
"""

from __future__ import annotations

import logging
import time
import urllib.error
import urllib.request

from google.auth.transport.requests import Request as GoogleAuthRequest
from google.oauth2 import id_token as google_id_token

from config import CONFIG

logger = logging.getLogger("ayma.agent_wake")

_TIMEOUT_SECONDS = 10


def wake_agent() -> None:
    """Best-effort, synchronous (blocking) wake ping — always call this via
    ``BackgroundTasks`` / ``asyncio.to_thread``, never awaited inline on the
    request path. Every failure is caught and logged, never raised: this is
    purely a latency optimization, and the client's own room-join /
    ``agentReady`` wait is what actually determines whether the call
    succeeds, wake ping or not.

    A no-op when ``AYMA_AGENT_URL`` is unset (local dev — nothing to wake).
    """
    if not CONFIG.agent_url:
        return
    started = time.monotonic()
    try:
        # `fetch_id_token` talks to the Cloud Run metadata server for the
        # runtime service identity; ayma-agent is `--no-allow-unauthenticated`
        # so a bare request would get a 403 before ever reaching the
        # container (no cold start triggered at all).
        token = google_id_token.fetch_id_token(
            GoogleAuthRequest(), CONFIG.agent_url
        )
        req = urllib.request.Request(
            CONFIG.agent_url, headers={"Authorization": f"Bearer {token}"}
        )
        with urllib.request.urlopen(req, timeout=_TIMEOUT_SECONDS) as resp:
            resp.read()
        logger.info(
            "agent wake ping ok in %.2fs", time.monotonic() - started
        )
    except urllib.error.HTTPError as exc:
        # Any HTTP response — even a 404 from the worker's bare health route
        # — proves Cloud Run already routed the request to a (newly started
        # or existing) container, which is all this ping needs to accomplish.
        logger.info(
            "agent wake ping got HTTP %s in %.2fs (still a successful wake)",
            exc.code, time.monotonic() - started,
        )
    except Exception:  # noqa: BLE001 - must never affect the caller's request
        logger.warning(
            "agent wake ping failed after %.2fs",
            time.monotonic() - started, exc_info=True,
        )
