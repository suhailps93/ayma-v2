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

    import main

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
            # The same SDK client on the exact URL the app shows (no trailing
            # slash), through the real app: the session manager only runs once
            # per process, so this shares the lifespan above.
            app_client = httpx.AsyncClient(
                transport=ASGITransport(app=main.app),
                base_url="http://test",
                headers={"Authorization": f"Bearer {raw}"},
            )
            async with streamable_http_client("http://test/mcp", http_client=app_client) as streams:
                async with ClientSession(streams[0], streams[1]) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    assert "get_profile" in {t.name for t in tools.tools}

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


# ---- OAuth revoke endpoint (RFC 7009) ------------------------------------ #


def test_revoke_valid_token(monkeypatch, fake_db):
    """RFC 7009 token revocation: valid token should return 200 and revoke."""
    raw, token_id = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    client = TestClient(mcp_server.asgi_app)
    r = client.post("/oauth/revoke", data={"token": raw})
    assert r.status_code == 200 and r.json()["ok"] is True
    mcp_oauth.clear_cache()
    assert mcp_oauth.resolve_token(fake_db, raw) is None


def test_revoke_invalid_token_still_200(monkeypatch, fake_db):
    """RFC 7009: invalid/unknown tokens still return 200 (client resilience)."""
    client = TestClient(mcp_server.asgi_app)
    r = client.post("/oauth/revoke", data={"token": "garbage"})
    assert r.status_code == 200 and r.json()["ok"] is True
    r = client.post("/oauth/revoke", data={"token": ""})
    assert r.status_code == 200 and r.json()["ok"] is True


def test_revoke_expired_token(monkeypatch, fake_db):
    """Revoking an expired token should still succeed."""
    from datetime import timedelta
    from timefmt import utcnow
    
    raw, token_id = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    # Manually expire the token in the DB
    key = (mcp_oauth.TOKENS_COLLECTION, token_id)
    fake_db.docs[key]["expires_at"] = utcnow() - timedelta(days=1)
    mcp_oauth.clear_cache()
    
    client = TestClient(mcp_server.asgi_app)
    r = client.post("/oauth/revoke", data={"token": raw})
    assert r.status_code == 200 and r.json()["ok"] is True


# ---- .well-known OAuth discovery endpoints ------------------------------ #


def test_oauth_authorization_server_metadata(fake_db):
    """Test /.well-known/oauth-authorization-server metadata endpoint."""
    client = TestClient(mcp_server.asgi_app)
    r = client.get("/.well-known/oauth-authorization-server")
    assert r.status_code == 200
    body = r.json()
    
    # Required fields per RFC 8414
    assert body["issuer"].endswith("/mcp")
    assert body["device_authorization_endpoint"].endswith("/mcp/oauth/device_authorization")
    assert body["token_endpoint"].endswith("/mcp/oauth/token")
    assert body["revocation_endpoint"].endswith("/mcp/oauth/revoke")
    assert mcp_oauth.DEVICE_GRANT_TYPE in body["grant_types_supported"]
    assert "none" in body["token_endpoint_auth_methods_supported"]
    assert set(body["scopes_supported"]) == set(mcp_oauth.ALL_SCOPES)
    
    # Should be cacheable (no-store means non-cacheable but we serve it anyway)
    assert "cache-control" in r.headers


def test_oauth_protected_resource_metadata(fake_db):
    """Test /.well-known/oauth-protected-resource metadata endpoint."""
    client = TestClient(mcp_server.asgi_app)
    r = client.get("/.well-known/oauth-protected-resource")
    assert r.status_code == 200
    body = r.json()
    
    assert "resource" in body
    assert body["resource"].endswith("/mcp")
    assert body["authorization_servers"][0].endswith("/mcp")
    assert set(body["scopes_supported"]) == set(mcp_oauth.ALL_SCOPES)
    assert "header" in body["bearer_methods_supported"]


def _advertised_urls(client, headers=None):
    """Every URL the discovery docs and the device flow hand to a client."""
    asm = client.get(
        "/.well-known/oauth-authorization-server", headers=headers
    ).json()
    prm = client.get(
        "/.well-known/oauth-protected-resource", headers=headers
    ).json()
    device = client.post(
        "/oauth/device_authorization",
        json={"client_id": "claude-code"},
        headers=headers,
    ).json()
    return [
        asm["issuer"],
        asm["device_authorization_endpoint"],
        asm["token_endpoint"],
        asm["revocation_endpoint"],
        prm["resource"],
        *prm["authorization_servers"],
        device["verification_uri"],
        device["verification_uri_complete"],
    ]


def test_advertised_urls_use_https_behind_tls_front_end(monkeypatch, fake_db):
    """Cloud Run ends TLS and sends X-Forwarded-Proto: https; every advertised
    URL must be https or clients are told to downgrade (prod bug, 2026-11-09)."""
    _enable(monkeypatch)
    client = TestClient(mcp_server.asgi_app)
    urls = _advertised_urls(client, {"x-forwarded-proto": "https"})
    assert all(u.startswith("https://testserver") for u in urls), urls


def test_advertised_urls_use_first_forwarded_proto_value(monkeypatch, fake_db):
    _enable(monkeypatch)
    client = TestClient(mcp_server.asgi_app)
    urls = _advertised_urls(client, {"x-forwarded-proto": "https, http"})
    assert all(u.startswith("https://testserver") for u in urls), urls


def test_advertised_urls_stay_http_without_forwarded_proto(monkeypatch, fake_db):
    """Local dev has no TLS front end, so plain http must keep working."""
    _enable(monkeypatch)
    client = TestClient(mcp_server.asgi_app)
    urls = _advertised_urls(client)
    assert all(u.startswith("http://testserver") for u in urls), urls


def test_forwarded_proto_http_never_produces_https(monkeypatch, fake_db):
    _enable(monkeypatch)
    client = TestClient(mcp_server.asgi_app)
    urls = _advertised_urls(client, {"x-forwarded-proto": "http"})
    assert all(u.startswith("http://testserver") for u in urls), urls


def test_forwarded_proto_never_downgrades_https(monkeypatch, fake_db):
    _enable(monkeypatch)
    client = TestClient(mcp_server.asgi_app, base_url="https://testserver")
    urls = _advertised_urls(client, {"x-forwarded-proto": "http"})
    assert all(u.startswith("https://testserver") for u in urls), urls


def test_metadata_endpoints_include_all_scopes(fake_db):
    """Both metadata endpoints should list all supported scopes."""
    client = TestClient(mcp_server.asgi_app)
    asm = client.get("/.well-known/oauth-authorization-server").json()
    prm = client.get("/.well-known/oauth-protected-resource").json()
    
    expected = set(mcp_oauth.ALL_SCOPES)
    assert set(asm["scopes_supported"]) == expected
    assert set(prm["scopes_supported"]) == expected


# ---- /connect/pending endpoint (approval flow) -------------------------- #


def test_pending_unknown_code_returns_404(monkeypatch, fake_db):
    """Pending details for a non-existent code should return 404."""
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    client = TestClient(mcp_server.asgi_app)
    r = client.get(
        "/connect/pending?user_code=NOPE-NOPE",
        headers={"authorization": "Bearer token"}
    )
    assert r.status_code == 404 and r.json()["error"] == "not_found"


def test_pending_expired_code_returns_404(monkeypatch, fake_db):
    """Pending details for an expired code should return 404."""
    from datetime import timedelta
    from timefmt import utcnow
    
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    da = mcp_oauth.create_device_code(fake_db, "claude", "profile:read")
    device_code = da["device_code"]
    
    # Manually expire the device code
    key = (mcp_oauth.DEVICE_CODES_COLLECTION, device_code)
    fake_db.docs[key]["expires_at"] = utcnow() - timedelta(seconds=1)
    
    client = TestClient(mcp_server.asgi_app)
    r = client.get(
        "/connect/pending?user_code=" + da["user_code"],
        headers={"authorization": "Bearer token"}
    )
    assert r.status_code == 404


def test_pending_returns_device_details(monkeypatch, fake_db):
    """Pending endpoint should return client_id, scope, and expires_at."""
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    da = mcp_oauth.create_device_code(fake_db, "test-client", "profile:read dm:send")
    client = TestClient(mcp_server.asgi_app)
    r = client.get(
        "/connect/pending?user_code=" + da["user_code"],
        headers={"authorization": "Bearer firebase-token"}
    )
    
    assert r.status_code == 200
    body = r.json()
    assert body["client_id"] == "test-client"
    assert set(body["scope"]) == {"profile:read", "dm:send"}
    assert body["expires_at"] is not None


def test_pending_requires_firebase_auth(fake_db):
    """Pending endpoint requires a valid Firebase ID token."""
    da = mcp_oauth.create_device_code(fake_db, "claude", "profile:read")
    client = TestClient(mcp_server.asgi_app)
    # No auth header
    r = client.get("/connect/pending?user_code=" + da["user_code"])
    assert r.status_code == 401


# ---- /connect/approve endpoint (already partially tested above) --------- #


def test_approve_with_scope_narrowing(monkeypatch, fake_db):
    """Approve can narrow the requested scopes."""
    _enable(monkeypatch)
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    da = mcp_oauth.create_device_code(
        fake_db, "claude", "profile:read profile:write dm:send"
    )
    client = TestClient(mcp_server.asgi_app)
    hdr = {"authorization": "Bearer firebase-id-token"}
    
    # Approve with narrowed scopes
    r = client.post("/connect/approve", headers=hdr, json={
        "user_code": da["user_code"],
        "scopes": ["profile:read"]
    })
    assert r.status_code == 200
    assert r.json()["approved"] is True
    
    # Token should only have the narrowed scope
    tok = client.post("/oauth/token", data={
        "grant_type": mcp_oauth.DEVICE_GRANT_TYPE,
        "device_code": da["device_code"],
        "client_id": "claude",
    })
    assert set(tok.json()["scope"].split()) == {"profile:read"}


def test_approve_with_invalid_narrowing_uses_all(monkeypatch, fake_db):
    """If approved scopes don't match requested, use all requested."""
    _enable(monkeypatch)
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    da = mcp_oauth.create_device_code(fake_db, "claude", "profile:read dm:send")
    client = TestClient(mcp_server.asgi_app)
    hdr = {"authorization": "Bearer firebase-id-token"}
    
    # Try to approve with scopes not in the request
    r = client.post("/connect/approve", headers=hdr, json={
        "user_code": da["user_code"],
        "scopes": ["persona:read"]  # not requested
    })
    assert r.status_code == 200
    # Should fall back to original request
    body = r.json()
    assert "scope" in body


def test_approve_fails_without_firebase_auth(monkeypatch, fake_db):
    """Approve requires a valid Firebase ID token."""
    _enable(monkeypatch)
    
    da = mcp_oauth.create_device_code(fake_db, "claude", "profile:read")
    client = TestClient(mcp_server.asgi_app)
    
    # No auth
    r = client.post("/connect/approve", json={"user_code": da["user_code"]})
    assert r.status_code == 401
    
    # Bad token
    r = client.post(
        "/connect/approve",
        headers={"authorization": "Bearer invalid"},
        json={"user_code": da["user_code"]}
    )
    assert r.status_code == 401


def test_approve_when_flag_disabled(fake_db):
    """Approve returns 503 when flag is off."""
    client = TestClient(mcp_server.asgi_app)
    r = client.post("/connect/approve", json={"user_code": "ABCD-1234"})
    assert r.status_code == 503


def test_deny_via_approve_endpoint(monkeypatch, fake_db):
    """Posting with approve=false should deny the code."""
    _enable(monkeypatch)
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    da = mcp_oauth.create_device_code(fake_db, "claude", "profile:read")
    client = TestClient(mcp_server.asgi_app)
    hdr = {"authorization": "Bearer firebase-id-token"}
    
    # Deny
    r = client.post("/connect/approve", headers=hdr, json={
        "user_code": da["user_code"],
        "approve": False,
    })
    assert r.status_code == 200 and r.json()["approved"] is False
    
    # Polling should get access_denied
    poll = client.post("/oauth/token", data={
        "grant_type": mcp_oauth.DEVICE_GRANT_TYPE,
        "device_code": da["device_code"],
        "client_id": "claude",
    })
    assert poll.status_code == 400 and poll.json()["error"] == "access_denied"


# ---- /connect/tokens endpoint (list connected agents) ------------------- #


def test_tokens_requires_firebase_auth(fake_db):
    """Tokens endpoint requires a valid Firebase ID token."""
    client = TestClient(mcp_server.asgi_app)
    r = client.get("/connect/tokens")
    assert r.status_code == 401


def test_tokens_lists_user_connections(monkeypatch, fake_db):
    """Tokens endpoint lists all non-revoked, non-expired tokens for the user."""
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    # Issue multiple tokens for the same user
    raw1, id1 = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    raw2, id2 = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="cursor", scopes=["dm:read"], token_ttl_days=30
    )
    # Issue one for a different user (should not appear)
    raw3, id3 = mcp_oauth.issue_token(
        fake_db, uid="other-user", client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    
    client = TestClient(mcp_server.asgi_app)
    r = client.get("/connect/tokens", headers={"authorization": "Bearer token"})
    assert r.status_code == 200
    body = r.json()
    assert len(body["connections"]) == 2
    token_ids = [c["token_id"] for c in body["connections"]]
    assert id1 in token_ids and id2 in token_ids
    assert id3 not in token_ids


def test_tokens_excludes_revoked(monkeypatch, fake_db):
    """Tokens endpoint should not list revoked tokens."""
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    raw, token_id = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    mcp_oauth.revoke_token(fake_db, UID, token_id)
    
    client = TestClient(mcp_server.asgi_app)
    r = client.get("/connect/tokens", headers={"authorization": "Bearer token"})
    assert r.status_code == 200
    assert len(r.json()["connections"]) == 0


def test_tokens_excludes_expired(monkeypatch, fake_db):
    """Tokens endpoint should not list expired tokens."""
    from datetime import timedelta
    from timefmt import utcnow
    
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    raw, token_id = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    # Expire it
    key = (mcp_oauth.TOKENS_COLLECTION, token_id)
    fake_db.docs[key]["expires_at"] = utcnow() - timedelta(days=1)
    
    client = TestClient(mcp_server.asgi_app)
    r = client.get("/connect/tokens", headers={"authorization": "Bearer token"})
    assert r.status_code == 200
    assert len(r.json()["connections"]) == 0


def test_tokens_contains_metadata_not_secret(monkeypatch, fake_db):
    """Tokens should never include raw token or secret values."""
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    raw, token_id = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read", "dm:send"], token_ttl_days=30
    )
    
    client = TestClient(mcp_server.asgi_app)
    r = client.get("/connect/tokens", headers={"authorization": "Bearer token"})
    body = r.json()
    
    # Check structure
    assert len(body["connections"]) == 1
    conn = body["connections"][0]
    assert conn["token_id"] == token_id
    assert conn["client_id"] == "claude"
    assert set(conn["scope"]) == {"profile:read", "dm:send"}
    assert "created_at" in conn and conn["created_at"] is not None
    assert "expires_at" in conn and conn["expires_at"] is not None
    
    # No raw token
    assert raw not in str(body)
    assert "access_token" not in conn


# ---- /connect/tokens/revoke endpoint ------------------------------------ #


def test_revoke_connection_requires_firebase_auth(fake_db):
    """Token revoke endpoint requires Firebase auth."""
    client = TestClient(mcp_server.asgi_app)
    r = client.post("/connect/tokens/revoke", json={"token_id": "nope"})
    assert r.status_code == 401


def test_revoke_connection_unknown_token(monkeypatch, fake_db):
    """Revoking a non-existent token_id returns 404."""
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    client = TestClient(mcp_server.asgi_app)
    r = client.post(
        "/connect/tokens/revoke",
        headers={"authorization": "Bearer token"},
        json={"token_id": "unknown-id"}
    )
    assert r.status_code == 404


def test_revoke_connection_wrong_owner(monkeypatch, fake_db):
    """User cannot revoke another user's token."""
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": "hacker"}
    )
    raw, token_id = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    
    client = TestClient(mcp_server.asgi_app)
    r = client.post(
        "/connect/tokens/revoke",
        headers={"authorization": "Bearer token"},
        json={"token_id": token_id}
    )
    assert r.status_code == 404


def test_revoke_connection_succeeds_for_owner(monkeypatch, fake_db):
    """User can revoke their own token."""
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    raw, token_id = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    
    client = TestClient(mcp_server.asgi_app)
    r = client.post(
        "/connect/tokens/revoke",
        headers={"authorization": "Bearer token"},
        json={"token_id": token_id}
    )
    assert r.status_code == 200 and r.json()["ok"] is True
    
    # Token should no longer resolve
    mcp_oauth.clear_cache()
    assert mcp_oauth.resolve_token(fake_db, raw) is None


def test_revoke_connection_idempotent(monkeypatch, fake_db):
    """Revoking a token is idempotent: calling twice returns 200 both times."""
    monkeypatch.setattr(
        mcp_server.firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    raw, token_id = mcp_oauth.issue_token(
        fake_db, uid=UID, client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    
    client = TestClient(mcp_server.asgi_app)
    # First revoke
    r1 = client.post(
        "/connect/tokens/revoke",
        headers={"authorization": "Bearer token"},
        json={"token_id": token_id}
    )
    assert r1.status_code == 200 and r1.json()["ok"] is True
    
    # Second revoke (already revoked) - still succeeds because the token doc exists
    # and still belongs to the user (it just has revoked=True)
    r2 = client.post(
        "/connect/tokens/revoke",
        headers={"authorization": "Bearer token"},
        json={"token_id": token_id}
    )
    assert r2.status_code == 200 and r2.json()["ok"] is True


# ---- the bare /mcp URL the app shows (no trailing-slash redirect) -------- #


def test_bare_mcp_url_flag_off_503_no_redirect(fake_db):
    import main

    client = TestClient(main.app, follow_redirects=False)
    r = client.post("/mcp", json={})
    assert r.status_code == 503 and r.json()["error"] == "mcp_disabled"


def test_bare_mcp_url_requires_token_no_redirect(monkeypatch, fake_db):
    import main

    _enable(monkeypatch)
    client = TestClient(main.app, follow_redirects=False)
    r = client.post("/mcp", json={})
    assert r.status_code == 401 and r.json()["error"] == "invalid_token"
    # The exact route must not shadow the mounted sub-routes.
    assert client.get("/mcp/connect").status_code == 200
    assert client.post("/mcp/", json={}).status_code == 401
