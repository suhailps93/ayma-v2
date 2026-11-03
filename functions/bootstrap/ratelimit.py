"""Per-endpoint rate limiting (ARCHITECTURE.md §10.4, §10.6 steps 2–3).

A small in-process fixed-window limiter applied as ASGI middleware to every
route. Each ``RATE_*`` value in ``config.py`` is a ``"<n>/<window>"`` string
(``second`` / ``minute`` / ``hour``); a route not in the table falls back to
``CONFIG.rate_default`` — so nothing ships unlimited.

In-process means the window is per Cloud Run instance. At this scale that is
acceptable (§12.5) and matches the spec's intent without pulling in a shared
store the two-image split would complicate.
"""

from __future__ import annotations

import time
from threading import Lock

from starlette.requests import Request
from starlette.responses import JSONResponse

from config import CONFIG

_WINDOW_SECONDS = {"second": 1, "sec": 1, "minute": 60, "min": 60, "hour": 3600}

# Flipped off by the test suite (conftest) so repeated TestClient calls to one
# route don't trip the limiter. Always on in a real deployment.
ENABLED = True


def parse_rate(spec: str) -> tuple[int, int]:
    """``"20/minute"`` -> ``(20, 60)``. Unparseable -> a safe 60/minute."""
    try:
        count, _, window = spec.strip().partition("/")
        key = window.strip().lower().rstrip("s") or "minute"
        return int(count), _WINDOW_SECONDS[key]
    except Exception:  # noqa: BLE001
        return 60, 60


def _route_rates() -> dict[str, str]:
    c = CONFIG
    return {
        "/health": "600/minute",
        "/bootstrap": c.rate_bootstrap,
        # `/chat/history` must precede the `/chat` prefix conceptually — the
        # longest-prefix match in `_match_prefix` gives it its own bucket so a
        # transcript read never counts against the send-a-message limit.
        "/chat/history": c.rate_chat_history,
        "/chat": c.rate_chat_text,
        "/post-turn": c.rate_chat_text,
        "/media": c.rate_media,
        "/account": c.rate_account,
        "/run-matching": c.rate_matching,
        "/check-compatibility": c.rate_matching,
        "/match/": c.rate_matching,
        "/explore": c.rate_explore,
        "/block": c.rate_block,
        "/profile/share": c.rate_profile_share,
        "/dm/": c.rate_dm_send,
        "/share": c.rate_share,
        "/s/": c.rate_share_public,
        "/r/": c.rate_share_public,
        "/.well-known/": c.rate_share_public,
        "/instagram/": c.rate_instagram,
        "/google/": c.rate_google,
        "/notifications/": c.rate_notifications,
        "/voice/preview/": c.rate_voice_preview,
        "/voice/": c.rate_voice,
        "/wiki/reset": c.rate_wiki_reset,
        "/cron/lint": c.rate_cron_lint,
        "/cron/purge-deleted": c.rate_cron_purge,
        "/cron/match": c.rate_cron_match,
        "/cron/reengage": c.rate_cron_reengage,
        "/cron/ingest-backfill": c.rate_cron_ingest_backfill,
        "/cron/google-sync": c.rate_cron_google_sync,
        "/credits/topup": c.rate_credits_topup,
        "/mcp": c.rate_mcp,
        "/dev/verify": "10/minute",
        # Pre-sign-in existence oracle: generous for a human tapping sign-in,
        # tight against bulk address harvesting.
        "/auth/email-exists": "20/minute",
        "/webhooks/": c.rate_webhooks,
        # Covers both the conduct endpoint ``/feedback`` and the product
        # catcher ``/feedback/submit`` (longest-prefix match).
        "/feedback": c.rate_feedback,
    }


def _match_prefix(path: str) -> str:
    """Longest configured prefix that ``path`` falls under, or ``"*"``."""
    best = ""
    for prefix in _route_rates():
        if (path == prefix or path.startswith(prefix)) and len(prefix) > len(best):
            best = prefix
    return best or "*"


def rate_for(path: str) -> str:
    return _route_rates().get(_match_prefix(path), CONFIG.rate_default)


def _client_key(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for", "")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def trusted_client_ip(request: Request) -> str:
    """The caller's address for security lockouts. Behind Cloud Run the
    platform appends the real peer to ``X-Forwarded-For``, so the RIGHTMOST
    entry is trustworthy and the leftmost is client-controlled (spoofable);
    "" when unknown."""
    fwd = request.headers.get("x-forwarded-for", "")
    if fwd:
        return fwd.split(",")[-1].strip()
    return request.client.host if request.client else ""


class RateLimiter:
    """ASGI middleware: fixed-window count per ``(client, route-prefix, window)``."""

    def __init__(self, app):
        self.app = app
        self._buckets: dict[tuple, int] = {}
        self._lock = Lock()

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not ENABLED:
            await self.app(scope, receive, send)
            return

        request = Request(scope)
        path = request.url.path
        limit, window = parse_rate(rate_for(path))
        now = int(time.time())
        win_start = now - (now % window)
        key = (_client_key(request), _match_prefix(path), win_start)

        with self._lock:
            count = self._buckets.get(key, 0) + 1
            self._buckets[key] = count
            if len(self._buckets) > 5000:
                self._buckets = {
                    k: v for k, v in self._buckets.items() if k[2] >= win_start
                }

        if count > limit:
            resp = JSONResponse(
                {"detail": "Rate limit exceeded. Slow down."},
                status_code=429,
                headers={"Retry-After": str(window - (now % window))},
            )
            await resp(scope, receive, send)
            return
        await self.app(scope, receive, send)
