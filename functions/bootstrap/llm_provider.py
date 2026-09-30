"""Per-user LLM provider routing (docs/chatgpt-provider.md).

Gemini is the locked default for every user. A user is routed to OpenAI only
when ``CHATGPT_SIGNIN_ENABLED`` is on AND they have a stored ChatGPT
connection (``users/{uid}/oauth_tokens/openai``). ``route_for`` is the single
question every seam asks; ``None`` means "Gemini, exactly as before".

Routing decisions are cached in-process for a short TTL so a chat turn that
fans out into many ``gemini.*`` calls costs one Firestore read, not one per
call. Connect/disconnect invalidate the local entry; other Cloud Run
instances converge within ``_TTL_SECONDS``.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass

import token_ledger
from config import CONFIG

logger = logging.getLogger("ayma.llm_provider")

PROVIDER_GEMINI = "gemini"
PROVIDER_OPENAI = "openai"

_TTL_SECONDS = 30.0
_cache: dict[str, tuple[float, "Route | None"]] = {}


@dataclass(frozen=True)
class Route:
    """An OpenAI route for one user. ``billing`` is ``plan`` (the user's own
    ChatGPT plan — no Ayma credits, no real-money cost) or ``api`` (dev mode:
    the operator's API key, billed like Gemini)."""

    uid: str
    billing: str
    provider: str = PROVIDER_OPENAI


def invalidate(uid: str | None = None) -> None:
    if uid is None:
        _cache.clear()
    else:
        _cache.pop(uid, None)


def _lookup(uid: str) -> "Route | None":
    from db import get_db
    import openai_auth

    conn = openai_auth.connection(get_db(), uid)
    if not conn:
        return None
    billing = (
        token_ledger.BILLING_API
        if conn.get("mode") == "api_key"
        else token_ledger.BILLING_PLAN
    )
    return Route(uid=uid, billing=billing)


def route_for(uid: str | None) -> "Route | None":
    """The OpenAI :class:`Route` for ``uid``, or ``None`` for Gemini. Never
    raises — any lookup failure degrades to Gemini."""
    if not uid or not CONFIG.chatgpt_signin_enabled:
        return None
    now = time.monotonic()
    hit = _cache.get(uid)
    if hit and now - hit[0] < _TTL_SECONDS:
        return hit[1]
    try:
        route = _lookup(uid)
    except Exception:  # noqa: BLE001 - routing must never break a request
        logger.warning("provider lookup failed for %s; using gemini", uid,
                       exc_info=True)
        return None
    _cache[uid] = (now, route)
    return route


def provider_for(uid: str | None) -> str:
    return PROVIDER_OPENAI if route_for(uid) else PROVIDER_GEMINI


async def access_token(route: Route, *, force_refresh: bool = False) -> str:
    """Bearer for ``route`` (refreshing an expiring plan token)."""
    from db import get_db
    import openai_auth

    return await asyncio.to_thread(
        openai_auth.access_token, get_db(), route.uid,
        force_refresh=force_refresh,
    )


def drop_connection(route: Route) -> None:
    """Forget a connection OpenAI rejected, so the next call is Gemini."""
    from db import get_db
    import openai_auth

    try:
        openai_auth.disconnect(get_db(), route.uid)
    finally:
        invalidate(route.uid)
