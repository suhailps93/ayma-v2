"""OAuth 2.1 Device Authorization Grant for the MCP server (mcp_oauth.py)."""

from __future__ import annotations

from datetime import timedelta

from timefmt import utcnow
import pytest

import mcp_oauth
from firebase_admin import firestore
from tests.fake_firestore import DELETE_FIELD, SERVER_TIMESTAMP, FakeDb


@pytest.fixture(autouse=True)
def _sentinels(monkeypatch):
    monkeypatch.setattr(firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP, raising=False)
    mcp_oauth.clear_cache()


def test_full_device_flow_mints_a_scoped_per_user_token():
    db = FakeDb()
    da = mcp_oauth.create_device_code(db, "claude", "profile:read dm:send")
    assert da["interval"] == mcp_oauth.POLL_INTERVAL_SECONDS
    assert "-" in da["user_code"]

    # Polling before approval is authorization_pending.
    with pytest.raises(mcp_oauth.OAuthError) as e:
        mcp_oauth.redeem(db, da["device_code"], "claude", 30)
    assert e.value.code == "authorization_pending"

    # The in-app approval binds the code to a uid.
    res = mcp_oauth.approve(db, "user-1", da["user_code"], None)
    assert res["scope"] == ["profile:read", "dm:send"]

    tok = mcp_oauth.redeem(db, da["device_code"], "claude", 30)
    assert tok["token_type"] == "Bearer"
    raw = tok["access_token"]
    assert raw.startswith(mcp_oauth.TOKEN_PREFIX)

    p = mcp_oauth.resolve_token(db, raw)
    assert p is not None and p.uid == "user-1"
    assert p.scopes == frozenset({"profile:read", "dm:send"})
    # The raw token is never stored — only its hash is the doc id.
    assert raw not in db.docs.get((mcp_oauth.TOKENS_COLLECTION, p.token_id), {})


def test_device_code_is_single_use():
    db = FakeDb()
    da = mcp_oauth.create_device_code(db, "claude", None)
    mcp_oauth.approve(db, "user-1", da["user_code"], None)
    mcp_oauth.redeem(db, da["device_code"], "claude", 30)
    with pytest.raises(mcp_oauth.OAuthError) as e:
        mcp_oauth.redeem(db, da["device_code"], "claude", 30)
    assert e.value.code == "invalid_grant"


def test_denied_code_returns_access_denied():
    db = FakeDb()
    da = mcp_oauth.create_device_code(db, "claude", None)
    mcp_oauth.deny(db, "user-1", da["user_code"])
    with pytest.raises(mcp_oauth.OAuthError) as e:
        mcp_oauth.redeem(db, da["device_code"], "claude", 30)
    assert e.value.code == "access_denied"


def test_client_id_mismatch_is_rejected():
    db = FakeDb()
    da = mcp_oauth.create_device_code(db, "claude", None)
    mcp_oauth.approve(db, "user-1", da["user_code"], None)
    with pytest.raises(mcp_oauth.OAuthError) as e:
        mcp_oauth.redeem(db, da["device_code"], "someone-else", 30)
    assert e.value.code == "invalid_client"


def test_approve_can_only_narrow_scopes_never_widen():
    db = FakeDb()
    da = mcp_oauth.create_device_code(db, "claude", "profile:read matches:read dm:send")
    # The user narrows to a subset; an extra requested scope is ignored.
    res = mcp_oauth.approve(
        db, "user-1", da["user_code"], ["profile:read", "persona:read"]
    )
    assert res["scope"] == ["profile:read"]


def test_revoked_token_stops_resolving():
    db = FakeDb()
    raw, token_id = mcp_oauth.issue_token(
        db, uid="user-1", client_id="claude",
        scopes=["profile:read"], token_ttl_days=30,
    )
    assert mcp_oauth.resolve_token(db, raw) is not None
    mcp_oauth.clear_cache()
    assert mcp_oauth.revoke_token(db, "user-1", token_id) is True
    assert mcp_oauth.resolve_token(db, raw) is None


def test_revoke_only_affects_the_owner():
    db = FakeDb()
    raw, token_id = mcp_oauth.issue_token(
        db, uid="user-1", client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    # A different user cannot revoke someone else's token.
    assert mcp_oauth.revoke_token(db, "attacker", token_id) is False
    mcp_oauth.clear_cache()
    assert mcp_oauth.resolve_token(db, raw) is not None


def test_expired_token_does_not_resolve():
    db = FakeDb()
    raw, token_id = mcp_oauth.issue_token(
        db, uid="user-1", client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    # Force expiry in the stored doc.
    key = (mcp_oauth.TOKENS_COLLECTION, token_id)
    db.docs[key]["expires_at"] = utcnow() - timedelta(days=1)
    mcp_oauth.clear_cache()
    assert mcp_oauth.resolve_token(db, raw) is None


def test_list_tokens_excludes_revoked_and_never_leaks_raw():
    db = FakeDb()
    raw, token_id = mcp_oauth.issue_token(
        db, uid="user-1", client_id="claude", scopes=["profile:read"], token_ttl_days=30
    )
    rows = mcp_oauth.list_tokens(db, "user-1")
    assert len(rows) == 1
    assert rows[0]["token_id"] == token_id
    assert "access_token" not in rows[0] and raw not in str(rows[0])
    mcp_oauth.revoke_token(db, "user-1", token_id)
    assert mcp_oauth.list_tokens(db, "user-1") == []


def test_unknown_or_malformed_tokens_resolve_to_none():
    db = FakeDb()
    assert mcp_oauth.resolve_token(db, "") is None
    assert mcp_oauth.resolve_token(db, "not-a-mcp-token") is None
    assert mcp_oauth.resolve_token(db, mcp_oauth.TOKEN_PREFIX + "bogus") is None


def test_user_code_normalization():
    # Uses only the unambiguous alphabet (no 0/1/I/L/O).
    assert mcp_oauth.normalize_user_code("abcd2345") == "ABCD-2345"
    assert mcp_oauth.normalize_user_code("ABCD 2345") == "ABCD-2345"
    assert mcp_oauth.normalize_user_code("abcd-2345") == "ABCD-2345"
