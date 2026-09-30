"""Minimal async OpenAI HTTP client (Responses API) for the provider seam.

Raw ``httpx`` instead of the ``openai`` SDK: the backend image has no OpenAI
dependency today, the surface needed is one endpoint, and a fake transport
makes the whole provider testable offline (``_transport`` hook).

Error contract (what :mod:`gemini`'s dispatch relies on):

* :class:`ProviderUnavailable` — OpenAI refused *this user's credential* or
  the model/endpoint isn't available to their plan. The caller falls back to
  Gemini for the call. A 401 that survives a token refresh also drops the
  stored connection (revoked grant).
* :class:`token_ledger.ProviderLimitReached` (a ``TokenCapExceeded``) — the
  user's ChatGPT plan allowance (weekly cap) is exhausted. NOT silently
  rerouted to Gemini: the user chose their plan, and existing call sites
  already handle ``TokenCapExceeded``.
* :class:`OpenAIError` — anything else (after retries).
"""

from __future__ import annotations

import asyncio
import logging

import httpx

import llm_provider
import openai_auth
import token_ledger
from config import CONFIG

logger = logging.getLogger("ayma.openai")

_RETRIES = 2
_RETRY_BACKOFF = 0.6
_LIMIT_CODES = {
    "insufficient_quota",
    "usage_limit_reached",
    "plan_limit_reached",
    "billing_hard_limit_reached",
    "weekly_limit_reached",
}

# Test hook: an ``httpx.AsyncBaseTransport`` (e.g. ``httpx.MockTransport``).
_transport: httpx.AsyncBaseTransport | None = None


class OpenAIError(RuntimeError):
    pass


class ProviderUnavailable(OpenAIError):
    """Fall back to Gemini for this call."""


def _error_code(resp: httpx.Response) -> str:
    try:
        err = (resp.json() or {}).get("error") or {}
    except ValueError:
        return ""
    if isinstance(err, dict):
        return str(err.get("code") or err.get("type") or "")
    return ""


async def _bearer(route: llm_provider.Route, *, force_refresh: bool = False) -> str:
    """The user's bearer. A missing/expired/revoked connection (the auth layer
    has already dropped it) is "unavailable" -> Gemini, not a hard error."""
    try:
        return await llm_provider.access_token(route, force_refresh=force_refresh)
    except openai_auth.OpenAIAuthError as exc:
        raise ProviderUnavailable(str(exc)) from exc


async def post(route: llm_provider.Route, path: str, payload: dict) -> dict:
    """POST ``payload`` to ``{openai_base_url}{path}`` as ``route``'s user;
    returns the parsed JSON body."""
    token = await _bearer(route)
    refreshed = False
    attempt = 0
    while True:
        try:
            async with httpx.AsyncClient(
                base_url=CONFIG.openai_base_url,
                timeout=CONFIG.openai_request_timeout_seconds,
                transport=_transport,
            ) as client:
                resp = await client.post(
                    path,
                    json=payload,
                    headers={"Authorization": f"Bearer {token}"},
                )
        except httpx.TransportError as exc:
            if attempt >= _RETRIES:
                raise OpenAIError(f"OpenAI unreachable: {exc}") from exc
            attempt += 1
            await asyncio.sleep(_RETRY_BACKOFF * attempt)
            continue

        status = resp.status_code
        if status < 400:
            return resp.json()
        code = _error_code(resp)
        if status == 402 or (status == 429 and code in _LIMIT_CODES):
            raise token_ledger.ProviderLimitReached(
                f"ChatGPT plan limit reached (uid={route.uid})"
            )
        if status == 401:
            if not refreshed:
                refreshed = True
                token = await _bearer(route, force_refresh=True)
                continue
            if route.billing == token_ledger.BILLING_PLAN:
                llm_provider.drop_connection(route)
            raise ProviderUnavailable("OpenAI rejected the credential")
        if status in (403, 404):
            logger.warning(
                "openai %s -> %d (%s): not available to this credential; "
                "falling back", path, status, code,
            )
            raise ProviderUnavailable(f"OpenAI {status}: {code}")
        if status in (408, 409, 429) or status >= 500:
            if attempt >= _RETRIES:
                raise OpenAIError(f"OpenAI {status}: {code}")
            attempt += 1
            await asyncio.sleep(_RETRY_BACKOFF * attempt)
            continue
        raise OpenAIError(f"OpenAI {status}: {code or resp.text[:200]}")


async def responses(route: llm_provider.Route, payload: dict) -> dict:
    return await post(route, "/responses", payload)
