"""The Ayma MCP server — a bring-your-own-agent interface.

An external MCP client (e.g. Claude) authorises as a specific Ayma user via the
OAuth 2.1 Device Authorization Grant (``mcp_oauth.py``), and from then on the
CLIENT'S OWN model does all the reasoning. This server exposes Ayma's SKILLS +
DATA as MCP tools (profile, matches, DMs, persona context) — the hands and
memory — while the client is the brain.

CORE PRINCIPLE — ZERO AYMA LLM SPEND. No exposed tool calls Ayma's chat /
reasoning model. Generation (story/bio text, a DM reply, a practice line) is
the client's job and arrives here as plain text to a validated write. See
``mcp_tools.py`` and ``docs/MCP_SERVER.md``.

Wiring (mounted at ``/mcp`` by ``main.py``):

* ``/mcp``                          — MCP streamable-HTTP endpoint (SDK), every
                                      request authenticated by an opaque per-user
                                      access token (the ``_McpAuthASGI`` wrapper).
* ``/mcp/oauth/device_authorization`` ``/mcp/oauth/token`` ``/mcp/oauth/revoke``
                                    — the device-grant OAuth endpoints (public).
* ``/mcp/connect`` + ``/mcp/connect/approve`` ``/pending`` ``/tokens`` …
                                    — the in-app "Connect an agent" approval +
                                      connected-agents management (Firebase-auth).
* ``/mcp/.well-known/oauth-*``      — discovery metadata.

The whole surface is behind the ``mcp_server`` feature flag (default OFF): when
off, the auth wrapper answers every MCP request with 503, so merging this code
exposes nothing until the founder flips the flag.
"""

from __future__ import annotations

import contextlib
import json
import logging
import time

import firebase_admin
from firebase_admin import auth as firebase_auth
from mcp.server.mcpserver import Context, MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, Response
from starlette.routing import Mount, Route

import feature_flags
import mcp_oauth
import mcp_tools
from config import CONFIG
from db import get_db
from mcp_tools import McpToolError

logger = logging.getLogger("ayma.mcp.server")

MOUNT_PATH = "/mcp"
FLAG_NAME = "mcp_server"

if not firebase_admin._apps:
    firebase_admin.initialize_app()

# ---- the MCP server + tools --------------------------------------------- #

_INSTRUCTIONS = (
    "Ayma is a dating app. These tools let YOUR model act on behalf of one "
    "Ayma user: read and update their profile, read their matches and the "
    "compatibility analysis Ayma computed, read and send their direct "
    "messages, and fetch the viewer-visible persona of a person so YOU can "
    "roleplay a practice conversation. Ayma never generates text for you: you "
    "compose any story/bio/message/practice line and pass it in. Every write "
    "is moderated and age-gated server-side."
)

server = MCPServer("Ayma", version=CONFIG.version, instructions=_INSTRUCTIONS)


def _principal(ctx: Context) -> mcp_oauth.Principal:
    """Resolve the authenticated user from the request's Bearer token. The ASGI
    wrapper already rejected unauthenticated requests, but tools re-resolve so
    they never trust anything but a freshly-validated token."""
    headers = ctx.headers or {}
    auth = headers.get("authorization") or headers.get("Authorization") or ""
    raw = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
    principal = mcp_oauth.resolve_token(get_db(), raw) if raw else None
    if principal is None:
        raise McpToolError("unauthorized", "Not authenticated.")
    return principal


def _run(fn, *args):
    try:
        return fn(*args)
    except McpToolError as exc:
        raise ValueError(f"{exc.code}: {exc.message}") from exc


@server.tool(description="Get the signed-in user's own profile (structured fields + their story narrative).")
def get_profile(ctx: Context) -> dict:
    return _run(mcp_tools.get_profile, get_db(), _principal(ctx))


@server.tool(description=(
    "Update the user's profile from text YOU composed. `fields` may contain any of: "
    "name, gender, interested_in, location, phone, birthdate (refused if under 18), "
    "and public_text (the public profile narrative; moderated + no contact info). "
    "Ayma does not write this text for you."
))
async def update_profile(ctx: Context, fields: dict) -> dict:
    principal = _principal(ctx)
    try:
        return await mcp_tools.update_profile(get_db(), principal, fields)
    except McpToolError as exc:
        raise ValueError(f"{exc.code}: {exc.message}") from exc


@server.tool(description="List the user's scored matches with compatibility scores and the user-facing explanation.")
def list_matches(ctx: Context) -> dict:
    return _run(mcp_tools.list_matches, get_db(), _principal(ctx))


@server.tool(description=(
    "Get one match's compatibility detail (score, dimensions, shared values, tensions) as grounding. "
    "Reads an already-scored match only — it never triggers scoring (that would spend Ayma's AI budget)."
))
def get_match(ctx: Context, other_uid: str) -> dict:
    return _run(mcp_tools.get_match, get_db(), _principal(ctx), other_uid)


@server.tool(description="List the user's direct-message threads (who, last message time, unread count).")
def list_threads(ctx: Context) -> dict:
    return _run(mcp_tools.list_threads, get_db(), _principal(ctx))


@server.tool(description="Read recent messages in the user's thread with one person (their own conversation only).")
def get_thread(ctx: Context, other_uid: str, limit: int = 30) -> dict:
    return _run(mcp_tools.get_thread, get_db(), _principal(ctx), other_uid, limit)


@server.tool(description=(
    "Send a direct message YOU composed to one person. Fails closed: contact info (email/phone) "
    "and content flagged by moderation are refused, not sent. Blocked recipients are refused."
))
async def send_message(ctx: Context, other_uid: str, text: str) -> dict:
    principal = _principal(ctx)
    try:
        return await mcp_tools.send_message(get_db(), principal, other_uid, text)
    except McpToolError as exc:
        raise ValueError(f"{exc.code}: {exc.message}") from exc


@server.tool(description=(
    "Get the viewer-visible persona context for a person so YOU can roleplay a practice conversation. "
    "Built only from what the user can already see; the persona's replies are NOT generated by Ayma."
))
def get_persona_context(ctx: Context, other_uid: str) -> dict:
    return _run(mcp_tools.get_persona_context, get_db(), _principal(ctx), other_uid)


# The streamable-HTTP ASGI app. Stateless + JSON responses keep it simple and
# compatible with Cloud Run scale-to-zero and the local test script.
_http = server.streamable_http_app(
    streamable_http_path="/",
    stateless_http=True,
    json_response=True,
    # The real access control is the per-user Bearer token below; behind Cloud
    # Run the Host header is the (arbitrary) service URL, so DNS-rebinding host
    # pinning is turned off deliberately (documented in docs/MCP_SERVER.md).
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)


# ---- per-token in-process rate limit ------------------------------------- #

_TOKEN_RATE_LIMIT = 120  # requests
_TOKEN_RATE_WINDOW = 60  # seconds
_token_hits: dict[tuple[str, int], int] = {}


def _rate_limited(token_id: str) -> bool:
    now = int(time.time())
    win = now - (now % _TOKEN_RATE_WINDOW)
    key = (token_id, win)
    count = _token_hits.get(key, 0) + 1
    _token_hits[key] = count
    if len(_token_hits) > 10000:
        for k in [k for k in _token_hits if k[1] < win]:
            _token_hits.pop(k, None)
    return count > _TOKEN_RATE_LIMIT


# ---- the auth-enforcing ASGI wrapper around the MCP endpoint ------------- #


async def _send_json(send, status: int, body: dict, extra_headers=None) -> None:
    payload = json.dumps(body).encode()
    headers = [(b"content-type", b"application/json")]
    for k, v in (extra_headers or []):
        headers.append((k.encode(), v.encode()))
    await send({"type": "http.response.start", "status": status, "headers": headers})
    await send({"type": "http.response.body", "body": payload})


class _McpAuthASGI:
    """Gate every MCP request: feature-flag (503 when off), opaque-token auth
    (401 otherwise, with a WWW-Authenticate hint), and a per-token rate limit
    (429). On success the request reaches the SDK app; the tools re-validate the
    token independently (defense in depth)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        if not feature_flags.enabled(FLAG_NAME):
            await _send_json(
                send, 503,
                {"error": "mcp_disabled",
                 "error_description": "The Ayma MCP server is currently disabled."},
            )
            return
        headers = {k.decode().lower(): v.decode() for k, v in scope.get("headers") or []}
        auth = headers.get("authorization", "")
        raw = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
        principal = mcp_oauth.resolve_token(get_db(), raw) if raw else None
        if principal is None:
            await _send_json(
                send, 401,
                {"error": "invalid_token",
                 "error_description": "A valid Ayma MCP access token is required."},
                extra_headers=[("www-authenticate", 'Bearer realm="ayma-mcp", error="invalid_token"')],
            )
            return
        if _rate_limited(principal.token_id):
            await _send_json(
                send, 429,
                {"error": "rate_limited", "error_description": "Too many requests."},
                extra_headers=[("retry-after", str(_TOKEN_RATE_WINDOW))],
            )
            return
        mcp_oauth.touch_token(get_db(), principal.token_id)
        await self.app(scope, receive, send)


# ---- OAuth / approval HTTP handlers (Starlette) -------------------------- #


async def _body_params(request: Request) -> dict:
    """Form or JSON body as a flat dict (OAuth uses form; our app uses JSON)."""
    ctype = request.headers.get("content-type", "")
    if "application/json" in ctype:
        try:
            data = await request.json()
            return data if isinstance(data, dict) else {}
        except Exception:  # noqa: BLE001
            return {}
    form = await request.form()
    return {k: v for k, v in form.items()}


def _firebase_uid(request: Request) -> str | None:
    """Verify the caller's Firebase ID token (the in-app surfaces send it).
    ``None`` on any failure — the handler then returns 401."""
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        return None
    try:
        decoded = firebase_auth.verify_id_token(auth[7:].strip())
        return decoded.get("uid")
    except Exception:  # noqa: BLE001
        return None


def _disabled_response() -> Response:
    return JSONResponse(
        {"error": "mcp_disabled",
         "error_description": "The Ayma MCP server is currently disabled."},
        status_code=503,
    )


async def device_authorization(request: Request) -> Response:
    if not feature_flags.enabled(FLAG_NAME):
        return _disabled_response()
    params = await _body_params(request)
    result = mcp_oauth.create_device_code(
        get_db(), str(params.get("client_id") or "mcp-client"),
        params.get("scope"),
    )
    base = str(request.base_url).rstrip("/")
    verify = f"{base}{MOUNT_PATH}/connect"
    result["verification_uri"] = verify
    result["verification_uri_complete"] = f"{verify}?user_code={result['user_code']}"
    return JSONResponse(result, headers={"cache-control": "no-store"})


async def token_endpoint(request: Request) -> Response:
    if not feature_flags.enabled(FLAG_NAME):
        return _disabled_response()
    params = await _body_params(request)
    grant = str(params.get("grant_type") or "")
    if grant != mcp_oauth.DEVICE_GRANT_TYPE:
        return JSONResponse(
            {"error": "unsupported_grant_type",
             "error_description": f"Use {mcp_oauth.DEVICE_GRANT_TYPE}."},
            status_code=400, headers={"cache-control": "no-store"},
        )
    try:
        result = mcp_oauth.redeem(
            get_db(), str(params.get("device_code") or ""),
            str(params.get("client_id") or "mcp-client"),
            CONFIG.mcp_token_ttl_days,
        )
    except mcp_oauth.OAuthError as exc:
        return JSONResponse(
            {"error": exc.code, "error_description": exc.description},
            status_code=exc.status, headers={"cache-control": "no-store"},
        )
    return JSONResponse(result, headers={"cache-control": "no-store"})


async def revoke_endpoint(request: Request) -> Response:
    params = await _body_params(request)
    mcp_oauth.revoke_raw_token(get_db(), str(params.get("token") or ""))
    return JSONResponse({"ok": True})  # RFC 7009: always 200


async def connect_page(request: Request) -> Response:
    code = request.query_params.get("user_code", "")
    return HTMLResponse(
        "<!doctype html><meta charset=utf-8>"
        "<meta name=viewport content='width=device-width,initial-scale=1'>"
        "<title>Connect an agent to Ayma</title>"
        "<body style='font-family:system-ui;max-width:28rem;margin:3rem auto;"
        "padding:0 1rem;line-height:1.5'>"
        "<h1>Connect an agent</h1>"
        "<p>Open the <b>Ayma</b> app, go to <b>Profile &rarr; Connect an "
        "agent</b>, and enter this code to approve:</p>"
        f"<p style='font-size:2rem;font-weight:700;letter-spacing:.1em'>{code or '— — — —'}</p>"
        "<p>Only approve a code you started yourself.</p></body>"
    )


async def approve_endpoint(request: Request) -> Response:
    if not feature_flags.enabled(FLAG_NAME):
        return _disabled_response()
    uid = _firebase_uid(request)
    if not uid:
        return JSONResponse({"error": "unauthorized"}, status_code=401)
    params = await _body_params(request)
    user_code = str(params.get("user_code") or "")
    approve = params.get("approve", True)
    approve = approve not in (False, "false", "False", 0, "0")
    scopes = params.get("scopes")
    if isinstance(scopes, str):
        scopes = scopes.replace(",", " ").split()
    try:
        if approve:
            result = mcp_oauth.approve(get_db(), uid, user_code, scopes)
        else:
            result = mcp_oauth.deny(get_db(), uid, user_code)
    except mcp_oauth.OAuthError as exc:
        return JSONResponse(
            {"error": exc.code, "error_description": exc.description},
            status_code=exc.status,
        )
    return JSONResponse({"ok": True, "approved": approve, **result})


async def pending_endpoint(request: Request) -> Response:
    uid = _firebase_uid(request)
    if not uid:
        return JSONResponse({"error": "unauthorized"}, status_code=401)
    details = mcp_oauth.pending_details(get_db(), request.query_params.get("user_code", ""))
    if details is None:
        return JSONResponse({"error": "not_found"}, status_code=404)
    return JSONResponse(details)


async def tokens_endpoint(request: Request) -> Response:
    uid = _firebase_uid(request)
    if not uid:
        return JSONResponse({"error": "unauthorized"}, status_code=401)
    return JSONResponse({"connections": mcp_oauth.list_tokens(get_db(), uid)})


async def revoke_connection_endpoint(request: Request) -> Response:
    uid = _firebase_uid(request)
    if not uid:
        return JSONResponse({"error": "unauthorized"}, status_code=401)
    params = await _body_params(request)
    ok = mcp_oauth.revoke_token(get_db(), uid, str(params.get("token_id") or ""))
    return JSONResponse({"ok": ok}, status_code=200 if ok else 404)


async def as_metadata(request: Request) -> Response:
    base = str(request.base_url).rstrip("/") + MOUNT_PATH
    return JSONResponse({
        "issuer": base,
        "device_authorization_endpoint": f"{base}/oauth/device_authorization",
        "token_endpoint": f"{base}/oauth/token",
        "revocation_endpoint": f"{base}/oauth/revoke",
        "grant_types_supported": [mcp_oauth.DEVICE_GRANT_TYPE],
        "token_endpoint_auth_methods_supported": ["none"],
        "scopes_supported": list(mcp_oauth.ALL_SCOPES),
    }, headers={"cache-control": "no-store"})


async def prm_metadata(request: Request) -> Response:
    base = str(request.base_url).rstrip("/") + MOUNT_PATH
    return JSONResponse({
        "resource": base,
        "authorization_servers": [base],
        "scopes_supported": list(mcp_oauth.ALL_SCOPES),
        "bearer_methods_supported": ["header"],
    }, headers={"cache-control": "no-store"})


# ---- the composed ASGI app mounted at /mcp ------------------------------- #

asgi_app = Starlette(routes=[
    Route("/oauth/device_authorization", device_authorization, methods=["POST"]),
    Route("/oauth/token", token_endpoint, methods=["POST"]),
    Route("/oauth/revoke", revoke_endpoint, methods=["POST"]),
    Route("/.well-known/oauth-authorization-server", as_metadata, methods=["GET"]),
    Route("/.well-known/oauth-protected-resource", prm_metadata, methods=["GET"]),
    Route("/connect", connect_page, methods=["GET"]),
    Route("/connect/approve", approve_endpoint, methods=["POST"]),
    Route("/connect/pending", pending_endpoint, methods=["GET"]),
    Route("/connect/tokens", tokens_endpoint, methods=["GET"]),
    Route("/connect/tokens/revoke", revoke_connection_endpoint, methods=["POST"]),
    # Catch-all last: the SDK MCP endpoint (auth-wrapped) at the mount root.
    Mount("/", app=_McpAuthASGI(_http)),
])


@contextlib.asynccontextmanager
async def lifespan():
    """Run the SDK's streamable-HTTP session manager for the app's lifetime.
    ``main.py`` enters this in its startup event (a mounted sub-app's lifespan
    is not run automatically by the parent)."""
    async with _http.router.lifespan_context(_http):
        yield
