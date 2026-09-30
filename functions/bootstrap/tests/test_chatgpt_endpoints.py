"""HTTP surface + wiring for Sign in with ChatGPT (docs/chatgpt-provider.md):
the /auth/chatgpt/* routes, the room-seed routing hint, account deletion,
rate limiting and config defaults."""

import dataclasses
import json

import account_ops
import config
import llm_provider
import livekit_token
import main
import openai_auth
import pytest
import ratelimit
from fake_firestore import FakeDb
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


@pytest.fixture
def db(monkeypatch):
    fake = FakeDb()
    import db as db_mod

    monkeypatch.setattr(main, "get_db", lambda: fake)
    monkeypatch.setattr(db_mod, "get_db", lambda: fake)
    llm_provider.invalidate()
    yield fake
    llm_provider.invalidate()


@pytest.fixture
def enable(monkeypatch):
    def _apply(**over):
        base = dict(
            chatgpt_signin_enabled=True,
            openai_auth_mode="oidc",
            openai_siwc_client_id="app_x",
            openai_siwc_redirect_uri="https://api.example.test/auth/chatgpt/callback",
        )
        base.update(over)
        for mod in (openai_auth, llm_provider):
            monkeypatch.setattr(mod, "CONFIG", dataclasses.replace(mod.CONFIG, **base))

    return _apply


def _as(monkeypatch, uid="u1"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


# ------------------------------------------------------------- default: dark
def test_the_feature_is_dark_by_default(db, monkeypatch):
    assert client.get("/auth/chatgpt/config").json() == {
        "enabled": False, "mode": "oidc"}
    assert client.post("/auth/chatgpt/start").status_code == 404
    assert client.post(
        "/auth/chatgpt/return", json={"state": "x" * 16}).status_code == 404
    assert client.get(
        "/auth/chatgpt/status", headers=_as(monkeypatch)).json()["connected"] is False


def test_config_shows_the_button_only_when_a_client_id_exists(db, enable):
    enable(openai_siwc_client_id="")
    assert client.get("/auth/chatgpt/config").json()["enabled"] is False
    enable()
    assert client.get("/auth/chatgpt/config").json() == {
        "enabled": True, "mode": "oidc"}


# ------------------------------------------------------------------- start
def test_start_is_open_to_anonymous_callers_for_signin(db, enable):
    enable()
    body = client.post("/auth/chatgpt/start").json()
    assert body["mode"] == "oidc" and body["state"]
    assert body["url"].startswith("https://auth.openai.com/api/accounts/authorize?")
    (sess,) = [v for k, v in db.docs.items() if k[0] == "openai_auth_sessions"]
    assert sess["intent"] == "signin" and sess["uid"] is None


def test_start_with_a_bearer_is_a_link(db, enable, monkeypatch):
    enable()
    client.post("/auth/chatgpt/start", headers=_as(monkeypatch, "u7"))
    (sess,) = [v for k, v in db.docs.items() if k[0] == "openai_auth_sessions"]
    assert sess["intent"] == "link" and sess["uid"] == "u7"


def test_start_unconfigured_is_a_400_not_a_crash(db, enable):
    enable(openai_siwc_client_id="")
    assert client.post("/auth/chatgpt/start").status_code == 400


# --------------------------------------------------------- callback + return
def test_callback_page_escapes_the_provider_error(db, enable):
    enable()
    r = client.get(
        "/auth/chatgpt/callback",
        params={"state": "s", "error": "<script>alert(1)</script>"},
    )
    assert r.status_code == 400
    assert "<script>" not in r.text
    assert "text/html" in r.headers["content-type"]


def test_callback_with_an_unknown_state_is_a_generic_400(db, enable):
    enable()
    r = client.get("/auth/chatgpt/callback", params={"state": "nope", "code": "c"})
    assert r.status_code == 400


def test_return_polls_pending_then_reports_errors(db, enable):
    enable()
    state = client.post("/auth/chatgpt/start").json()["state"]
    assert client.post("/auth/chatgpt/return", json={"state": state}).json() == {
        "status": "pending"}
    unknown = client.post("/auth/chatgpt/return", json={"state": "z" * 20}).json()
    assert unknown["status"] == "error"


def test_return_rejects_a_short_state(db, enable):
    enable()
    assert client.post("/auth/chatgpt/return", json={"state": "x"}).status_code == 422


# --------------------------------------------------- status + disconnect
def test_status_and_disconnect_require_auth(db, enable):
    enable()
    assert client.get("/auth/chatgpt/status").status_code in (401, 403)
    assert client.post("/auth/chatgpt/disconnect").status_code in (401, 403)


def test_connected_user_status_then_disconnect_returns_to_gemini(
    db, enable, monkeypatch
):
    enable()
    hdr = _as(monkeypatch, "u1")
    openai_auth._token_ref(db, "u1").set(
        {"mode": "oidc", "email": "a@b.test", "access_token": "SECRET",
         "refresh_token": "SECRET2"}
    )
    raw = client.get("/auth/chatgpt/status", headers=hdr)
    st = raw.json()
    assert st["connected"] is True and st["provider"] == "openai"
    assert st["email"] == "a@b.test"
    assert "SECRET" not in raw.text  # tokens never leave the server
    assert llm_provider.provider_for("u1") == "openai"

    assert client.post("/auth/chatgpt/disconnect", headers=hdr).json() == {"ok": True}
    assert client.get("/auth/chatgpt/status", headers=hdr).json()["provider"] == "gemini"
    assert llm_provider.provider_for("u1") == "gemini"


# --------------------------------------------------------------- room seed
def test_room_seed_defaults_to_gemini_and_carries_the_hint():
    plain = json.loads(livekit_token.build_room_seed("sys", [], "u1", "s1"))
    assert plain["llm_provider"] == "gemini"
    routed = json.loads(
        livekit_token.build_room_seed("sys", [], "u1", "s1", llm_provider="openai")
    )
    assert routed["llm_provider"] == "openai"
    assert "token" not in json.dumps(routed).lower()


# ------------------------------------------------------------ account ops
def test_account_delete_archives_and_severs_chatgpt_identities(monkeypatch):
    monkeypatch.setattr(
        account_ops.firestore, "SERVER_TIMESTAMP", "TS", raising=False)
    from fake_firestore import DELETE_FIELD, SERVER_TIMESTAMP

    monkeypatch.setattr(account_ops.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
    monkeypatch.setattr(account_ops.firestore, "DELETE_FIELD", DELETE_FIELD)
    db = FakeDb()
    db.docs[("users", "u1")] = {"created_at": 1}
    db.docs[("openai_identities", "sub-1")] = {"uid": "u1", "email": "a@b.test"}
    db.docs[("openai_identities", "sub-2")] = {"uid": "other"}
    account_ops.soft_delete(db, None, "u1")
    assert ("openai_identities", "sub-1") not in db.docs
    assert ("openai_identities", "sub-2") in db.docs
    archived = db.docs[("deleted_accounts", "u1", "identity_mappings", "openai_sub-1")]
    assert archived["provider"] == "openai"


# ------------------------------------------------------ ratelimit + config
def test_chatgpt_auth_has_its_own_rate_bucket():
    assert ratelimit._match_prefix("/auth/chatgpt/start") == "/auth/chatgpt/"
    assert ratelimit._route_rates()["/auth/chatgpt/"] == config.CONFIG.rate_chatgpt_auth


def test_defaults_keep_gemini_locked_and_the_feature_off(monkeypatch):
    for k in ("CHATGPT_SIGNIN_ENABLED", "OPENAI_AUTH_MODE", "GEMINI_MODEL"):
        monkeypatch.delenv(k, raising=False)
    cfg = config._load()
    assert cfg.chatgpt_signin_enabled is False
    assert cfg.openai_auth_mode == "oidc"
    assert cfg.openai_siwc_issuer == "https://auth.openai.com"
    assert cfg.openai_siwc_authorize_url.endswith("/api/accounts/authorize")
    assert cfg.openai_siwc_token_url.endswith("/api/accounts/oauth/token")
    assert cfg.openai_siwc_scopes == "openid profile email"
    assert cfg.openai_model == "gpt-6.1-sol"
    assert cfg.openai_realtime_model == "gpt-realtime-2.1"
    # Gemini defaults are locked.
    assert cfg.gemini_model == "gemini-3.7-flash"
    assert cfg.gemini_live_dev_model == "gemini-3.8-live"
    assert cfg.gemini_image_edit_model == "gemini-2.5-flash-image"


def test_openai_models_are_env_overridable(monkeypatch):
    monkeypatch.setenv("OPENAI_MODEL", "gpt-6-luna")
    monkeypatch.setenv("CHATGPT_SIGNIN_ENABLED", "true")
    cfg = config._load()
    assert cfg.openai_model == "gpt-6-luna"
    assert cfg.chatgpt_signin_enabled is True
