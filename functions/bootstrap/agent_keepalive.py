"""Per-call keep-alive for the scale-to-zero ``ayma-agent`` Cloud Run service.

Why: Cloud Run only counts in-flight HTTP requests as "busy". A LiveKit call
runs over the worker's own outbound connection, so with ``min-instances 0``
an instance carrying a live call looks idle and may be stopped mid-call
(founder call 2026-10-26 02:55 UTC: SIGTERM 15 s into the call). An instance
that is serving a request is never scaled down, so every active call holds
one long-lived request open against the service's own public URL for as long
as the call (and its end-of-call memory flush) lasts. Zero fixed cost: the
instance is billed while it runs either way; this only stops it being
killed while it is working.

Two halves:

- ``KeepAliveServer`` (worker main process) serves ``$PORT``: ``/`` (health
  and the wake ping from ``agent_wake.py``) and ``/keepalive``, a streaming
  response that writes a heartbeat line every ``HEARTBEAT_SECONDS`` and ends
  after ``MAX_HOLD_SECONDS`` (below the service's 3600 s request timeout) or
  when the caller goes away.
- ``CallKeepAlive`` (job process, one per call) opens that request through
  the load balancer. Cloud Run may route it to another instance, which would
  keep the wrong instance alive, so the request carries this instance's id
  (metadata server) and any other instance answers 409 at once; the client
  retries until it lands here, and reopens whenever a hold ends while the
  call is still active.

Off Cloud Run (no ``K_SERVICE``) or without ``AYMA_AGENT_URL`` the client is
a no-op: there is nothing to keep alive in local dev.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import Awaitable, Callable

import aiohttp
from aiohttp import web
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.oauth2 import id_token as google_id_token

from config import CONFIG

logger = logging.getLogger("ayma.agent_keepalive")

KEEPALIVE_PATH = "/keepalive"
HEARTBEAT_SECONDS = 20.0
MAX_HOLD_SECONDS = 3000.0
RETRY_STEP_SECONDS = 0.5
RETRY_MAX_SECONDS = 5.0
# A burst of 409s is normal while several instances are up; this many in a
# row means the call is not protected yet, which is worth a warning.
WARN_AFTER_FAILURES = 20

_METADATA_INSTANCE_ID_URL = (
    "http://metadata.google.internal/computeMetadata/v1/instance/id"
)


def on_cloud_run() -> bool:
    return bool(os.getenv("K_SERVICE"))


async def fetch_instance_id(http: aiohttp.ClientSession) -> str:
    """This Cloud Run instance's id, from the metadata server."""
    async with http.get(
        _METADATA_INSTANCE_ID_URL,
        headers={"Metadata-Flavor": "Google"},
        timeout=aiohttp.ClientTimeout(total=5),
    ) as resp:
        resp.raise_for_status()
        return (await resp.text()).strip()


def _fetch_id_token(audience: str) -> str:
    return google_id_token.fetch_id_token(GoogleAuthRequest(), audience)


class KeepAliveServer:
    """HTTP server on the Cloud Run port: health plus the keep-alive stream."""

    def __init__(
        self,
        host: str,
        port: int,
        *,
        instance_id: Callable[[], Awaitable[str]] | None = None,
        heartbeat_seconds: float = HEARTBEAT_SECONDS,
        max_hold_seconds: float = MAX_HOLD_SECONDS,
    ) -> None:
        self._host = host
        self._port = port
        self._instance_id_fn = instance_id or self._metadata_instance_id
        self._instance_id: str | None = None
        self._heartbeat = heartbeat_seconds
        self._max_hold = max_hold_seconds
        self._held: dict[int, str] = {}
        self._runner: web.AppRunner | None = None
        self.app = web.Application()
        self.app.add_routes(
            [web.get("/", self._health), web.get(KEEPALIVE_PATH, self._keepalive)]
        )

    @property
    def active_holds(self) -> int:
        return len(self._held)

    async def start(self) -> None:
        self._runner = web.AppRunner(self.app)
        await self._runner.setup()
        await web.TCPSite(self._runner, self._host, self._port).start()
        logger.info("keepalive server listening on %s:%s", self._host, self._port)

    async def aclose(self) -> None:
        if self._runner is not None:
            await self._runner.cleanup()
            self._runner = None

    @staticmethod
    async def _metadata_instance_id() -> str:
        if not on_cloud_run():
            return ""
        async with aiohttp.ClientSession() as http:
            return await fetch_instance_id(http)

    async def _own_instance_id(self) -> str:
        if self._instance_id is None:
            self._instance_id = await self._instance_id_fn()
        return self._instance_id

    async def _health(self, _request: web.Request) -> web.Response:
        return web.Response(text="OK")

    async def _keepalive(self, request: web.Request) -> web.StreamResponse:
        job = request.query.get("job", "?")
        try:
            own = await self._own_instance_id()
        except Exception:  # noqa: BLE001 - answer 503 so the caller retries
            logger.warning("keepalive instance id lookup failed", exc_info=True)
            return web.Response(status=503, text="instance id unavailable")
        if request.query.get("instance", "") != own:
            return web.Response(status=409, text="other instance")

        resp = web.StreamResponse(headers={"Content-Type": "text/plain"})
        await resp.prepare(request)
        key = id(request)
        self._held[key] = job
        started = time.monotonic()
        reason = "max_hold"
        logger.info(
            "keepalive hold start job=%s active_holds=%d", job, len(self._held)
        )
        try:
            while time.monotonic() - started < self._max_hold:
                await resp.write(b".\n")
                await asyncio.sleep(self._heartbeat)
            await resp.write_eof()
        except ConnectionResetError:
            reason = "caller_closed"
        except asyncio.CancelledError:
            reason = "server_closing"
            raise
        finally:
            self._held.pop(key, None)
            logger.info(
                "keepalive hold end job=%s reason=%s held_s=%.0f active_holds=%d",
                job, reason, time.monotonic() - started, len(self._held),
            )
        return resp


class CallKeepAlive:
    """Holds one keep-alive request open for a single call (job)."""

    def __init__(
        self,
        job_id: str,
        *,
        service_url: str,
        enabled: bool,
        token_fn: Callable[[str], str] = _fetch_id_token,
        instance_id_fn: Callable[[aiohttp.ClientSession], Awaitable[str]] = fetch_instance_id,
        heartbeat_seconds: float = HEARTBEAT_SECONDS,
        retry_step_seconds: float = RETRY_STEP_SECONDS,
        retry_max_seconds: float = RETRY_MAX_SECONDS,
    ) -> None:
        self.job_id = job_id
        self._url = service_url.rstrip("/")
        self._enabled = enabled and bool(self._url)
        self._token_fn = token_fn
        self._instance_id_fn = instance_id_fn
        self._read_timeout = heartbeat_seconds * 3
        self._retry_step = retry_step_seconds
        self._retry_max = retry_max_seconds
        self._task: asyncio.Task[None] | None = None
        self._holds: list[Callable[[], Awaitable[None]]] = []
        self._started_at = 0.0
        self.holds_opened = 0

    @classmethod
    def for_job(cls, job_id: str) -> CallKeepAlive:
        return cls(job_id, service_url=CONFIG.agent_url, enabled=on_cloud_run())

    def start(self) -> None:
        if not self._enabled:
            logger.info("keepalive disabled job=%s (not on Cloud Run)", self.job_id)
            return
        if self._task is None:
            self._started_at = time.monotonic()
            self._task = asyncio.create_task(self._run(), name="call_keepalive")

    def hold_for(self, work: Callable[[], Awaitable[None]]) -> None:
        """Keep the instance busy until ``work`` (e.g. the end-of-call memory
        flush) has finished, not only until the call itself ends."""
        self._holds.append(work)

    async def release(self) -> None:
        """Job shutdown callback: wait for the held work, then let go."""
        results = await asyncio.gather(
            *(work() for work in self._holds), return_exceptions=True
        )
        for result in results:
            if isinstance(result, Exception):
                logger.warning(
                    "keepalive held work failed job=%s", self.job_id,
                    exc_info=result,
                )
        await self.stop()

    async def stop(self) -> None:
        task, self._task = self._task, None
        if task is None:
            return
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        logger.info(
            "keepalive released job=%s after %.0fs holds_opened=%d",
            self.job_id, time.monotonic() - self._started_at, self.holds_opened,
        )

    async def _run(self) -> None:
        failures = 0
        async with aiohttp.ClientSession() as http:
            instance: str | None = None
            while True:
                try:
                    if instance is None:
                        instance = await self._instance_id_fn(http)
                    outcome = await self._hold_once(http, instance)
                except asyncio.CancelledError:
                    raise
                except Exception:  # noqa: BLE001 - retried below; must never end the call
                    logger.warning(
                        "keepalive attempt failed job=%s", self.job_id, exc_info=True
                    )
                    outcome = "error"
                if outcome == "held":
                    failures = 0
                    continue
                failures += 1
                if failures == WARN_AFTER_FAILURES:
                    logger.warning(
                        "keepalive not held yet job=%s after %d attempts (last=%s)",
                        self.job_id, failures, outcome,
                    )
                await asyncio.sleep(
                    min(self._retry_max, self._retry_step * failures)
                )

    async def _hold_once(self, http: aiohttp.ClientSession, instance: str) -> str:
        token = await asyncio.to_thread(self._token_fn, self._url)
        async with http.get(
            f"{self._url}{KEEPALIVE_PATH}",
            params={"job": self.job_id, "instance": instance},
            headers={"Authorization": f"Bearer {token}"},
            timeout=aiohttp.ClientTimeout(
                total=None, sock_connect=10, sock_read=self._read_timeout
            ),
        ) as resp:
            if resp.status == 409:
                return "wrong_instance"
            if resp.status != 200:
                logger.warning(
                    "keepalive job=%s got HTTP %s", self.job_id, resp.status
                )
                return "error"
            self.holds_opened += 1
            logger.info(
                "keepalive held job=%s hold=%d", self.job_id, self.holds_opened
            )
            heartbeats = 0
            async for _chunk in resp.content.iter_any():
                heartbeats += 1
        # An empty 200 is not a hold; back off instead of reopening in a loop.
        return "held" if heartbeats else "error"
