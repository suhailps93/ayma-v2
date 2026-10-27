"""HTTP-layer security + OAuth routes of the MCP server (mcp_server.py).

The MCP JSON-RPC protocol itself (initialize / tools/list / tools/call) is
exercised end-to-end by ``scripts/mcp_demo.py`` against a live server; here we
assert the security gates that wrap it — the feature flag, bearer-token auth,
per-token rate limit — and the OAuth device-grant endpoints."""

from __future__ import annotations

import asyncio

import pytest
from starlette.testclient import TestClient

import feature_flags
import mcp_oauth
import mcp_server
import token_ledger
from firebase_admin import firestore
from tests.fake_firestore import SERVER_TIMESTAMP, FakeDb

UID = "user-1"


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setattr(firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP, raising=False)
    mcp_oauth.clear_cache()
    mcp_server._token_hits.clear()


@pytest.fixture
def fake_db(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(mcp_server, "get_db", lambda: db)
    return db


def _enable(monkeypatch):
    monkeypatch.setenv("FLAG_MCP_SERVER", "1")
    feature_flags.reset_cache()


# ---- the auth-enforcing ASGI wrapper ------------------------------------ #


def _drive(wrapped, headers=None):
    """Run one HTTP request through an ASGI app; return (status, body_bytes)."""
    scope = {
        "type": "http", "method": "POST", "path": "/",
        "headers": [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()],
    }
    sent = []

    async def receive():
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(msg):
        sent.append(msg)

    asyncio.run(wrapped(scope, receive, send))
    status = next(m["status"] for m in sent if m["type"] == "http.response.start")
    body = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    return status, body


def test_wrapper_returns_503_when_flag_off(fake_db):
    reached = []

    async def stub(scope, receive, send):
        reached.append(True)
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})

    wrapped = mcp_server._McpAuthASGI(stub)
    status, body = _drive(wrapped)
    assert status == 503 and b"mcp_disabled" in body
    assert reached == []  # never delegated to the MCP app


def test_wrapper_401_without_token(monkeypatch, fake_db):
    _enable(monkeypatch)
    wrapped = mcp_server._McpAuthASGI(lambda *a: None)
    status, body = _drive(wrapped)
    assert status == 401 and b"invalid_token" in body


def test_wrapper_401_with_bad_token(monkeypatch, fake_db):
    _enable(monkeypatch)
    wrapped = mcp_server._McpAuthASGI(lambda *a: None)
    status, _ = _drive(wrapped, {"authorization": "Bearer aymcp_nope"})
    assert status == 401


def test_wrapper_delegates_on_valid_token(monkeypatch, fake_db):
    _enable(monkeypatch)
    raw, _ = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    reached = []

    async def stub(scope, receive, send):
        reached.append(True)
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})

    wrapped = mcp_server._McpAuthASGI(stub)
    status, _ = _drive(wrapped, {"authorization": f"Bearer {raw}"})
    assert status == 200 and reached == [True]


def test_wrapper_rate_limits_per_token(monkeypatch, fake_db):
    _enable(monkeypatch)
    raw, _ = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )

    async def stub(scope, receive, send):
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})

    wrapped = mcp_server._McpAuthASGI(stub)
    hdr = {"authorization": f"Bearer {raw}"}
    statuses = [_drive(wrapped, hdr)[0] for _ in range(mcp_server._TOKEN_RATE_LIMIT + 5)]
    assert 429 in statuses
    assert statuses.count(200) <= mcp_server._TOKEN_RATE_LIMIT


# ---- OAuth / approval HTTP routes --------------------------------------- #


def test_oauth_endpoints_503_when_flag_off(fake_db):
    client = TestClient(mcp_server.asgi_app)
    r = client.post("/oauth/device_authorization", data={"client_id": "claude"})
    assert r.status_code == 503


def test_device_flow_over_http(monkeypatch, fake_db):
    _enable(monkeypatch)
    client = TestClient(mcp_server.asgi_app)

    r = client.post(
        "/oauth/device_authorization",
        data={"client_id": "claude", "scope": "profile:read dm:send"},
    )
    assert r.status_code == 200
    body = r.json()
    user_code = body["user_code"]
    assert body["verification_uri"].endswith("/mcp/connect")

    # Poll before approval.
    poll = client.post("/oauth/token", data={
        "grant_type": mcp_oauth.DEVICE_GRANT_TYPE,
        "device_code": body["device_code"], "client_id": "claude",
    })
    assert poll.status_code == 400 and poll.json()["error"] == "authorization_pending"

    # Approve in-app (Firebase-authenticated).
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    appr = client.post(
        "/connect/approve",
        headers={"authorization": "Bearer firebase-id-token"},
        json={"user_code": user_code},
    )
    assert appr.status_code == 200 and appr.json()["approved"] is True

    # Poll again -> token.
    tok = client.post("/oauth/token", data={
        "grant_type": mcp_oauth.DEVICE_GRANT_TYPE,
        "device_code": body["device_code"], "client_id": "claude",
    })
    assert tok.status_code == 200
    raw = tok.json()["access_token"]
    assert mcp_oauth.resolve_token(fake_db, raw).uid == UID


def test_approve_requires_firebase_auth(monkeypatch, fake_db):
    _enable(monkeypatch)
    client = TestClient(mcp_server.asgi_app)
    r = client.post("/connect/approve", json={"user_code": "ABCD-1234"})
    assert r.status_code == 401


def test_token_endpoint_rejects_wrong_grant(monkeypatch, fake_db):
    _enable(monkeypatch)
    client = TestClient(mcp_server.asgi_app)
    r = client.post("/oauth/token", data={"grant_type": "authorization_code"})
    assert r.status_code == 400 and r.json()["error"] == "unsupported_grant_type"


def test_metadata_endpoints(fake_db):
    client = TestClient(mcp_server.asgi_app)
    asm = client.get("/.well-known/oauth-authorization-server").json()
    assert asm["grant_types_supported"] == [mcp_oauth.DEVICE_GRANT_TYPE]
    assert asm["token_endpoint"].endswith("/mcp/oauth/token")
    prm = client.get("/.well-known/oauth-protected-resource").json()
    assert set(prm["scopes_supported"]) == set(mcp_oauth.ALL_SCOPES)


def test_mcp_protocol_end_to_end(monkeypatch, fake_db):
    """Real MCP JSON-RPC over the mounted streamable-HTTP app, driven by the
    official SDK client (what Claude does): initialize -> tools/list ->
    tools/call, authenticated by a minted token, routed through the mount + the
    auth wrapper + the session-manager lifespan."""
    import httpx
    from httpx import ASGITransport
    from mcp.client.session import ClientSession
    from mcp.client.streamable_http import streamable_http_client

    _enable(monkeypatch)
    monkeypatch.setattr(token_ledger, "get_db", lambda: fake_db)
    fake_db.docs[("users", UID, "profile", "main")] = {
        "name": "Alex", "birthdate": "1990-01-01", "interested_in": ["Men"],
    }
    raw, _ = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude",
        scopes=list(mcp_oauth.ALL_SCOPES), token_ttl_days=30,
    )

    async def _run():
        async with mcp_server.lifespan():
            client = httpx.AsyncClient(
                transport=ASGITransport(app=mcp_server.asgi_app),
                base_url="http://test",
                headers={"Authorization": f"Bearer {raw}"},
            )
            async with streamable_http_client("http://test/", http_client=client) as streams:
                read, write = streams[0], streams[1]
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    names = {t.name for t in tools.tools}
                    assert names == {
                        "get_profile", "update_profile", "list_matches", "get_match",
                        "list_threads", "get_thread", "send_message", "get_persona_context",
                    }
                    res = await session.call_tool("get_profile", {})
                    assert getattr(res, "isError", False) in (False, None)
                    blob = str(getattr(res, "structuredContent", None)) + " ".join(
                        getattr(c, "text", "") or "" for c in (getattr(res, "content", []) or [])
                    )
                    assert "Alex" in blob

    import asyncio

    asyncio.run(_run())


def test_connected_agents_list_and_revoke(monkeypatch, fake_db):
    _enable(monkeypatch)
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    raw, token_id = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    client = TestClient(mcp_server.asgi_app)
    hdr = {"authorization": "Bearer firebase-id-token"}
    listed = client.get("/connect/tokens", headers=hdr).json()
    assert len(listed["connections"]) == 1
    rev = client.post("/connect/tokens/revoke", headers=hdr, json={"token_id": token_id})
    assert rev.status_code == 200 and rev.json()["ok"] is True
    mcp_oauth.clear_cache()
    assert mcp_oauth.resolve_token(fake_db, raw) is None
