"""Sign in with ChatGPT: OIDC + PKCE flow, token storage and refresh
(docs/chatgpt-provider.md). Real JWT signing/verification against a locally
generated RSA key; OpenAI's endpoints are faked."""

import base64
import dataclasses
import hashlib
import time
import urllib.parse
from datetime import datetime, timedelta, timezone

import jwt
import llm_provider
import openai_auth
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fake_firestore import FakeDb
from firebase_admin import auth as firebase_auth

CLIENT_ID = "app_test_client"
REDIRECT = "https://api.example.test/auth/chatgpt/callback"
ISSUER = "https://auth.openai.com"


@pytest.fixture(scope="module")
def rsa_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


@pytest.fixture
def cfg(monkeypatch):
    def _apply(**overrides):
        base = dict(
            chatgpt_signin_enabled=True,
            openai_auth_mode="oidc",
            openai_siwc_client_id=CLIENT_ID,
            openai_siwc_redirect_uri=REDIRECT,
            openai_token_encryption_key="",
        )
        base.update(overrides)
        monkeypatch.setattr(
            openai_auth, "CONFIG", dataclasses.replace(openai_auth.CONFIG, **base)
        )
        monkeypatch.setattr(
            llm_provider,
            "CONFIG",
            dataclasses.replace(llm_provider.CONFIG, **base),
        )

    _apply()
    llm_provider.invalidate()
    return _apply


@pytest.fixture
def oidc(monkeypatch, rsa_key, cfg):
    """Wire fake token endpoint + JWKS. ``state.id_claims`` / ``state.token_resp``
    can be tweaked per test."""

    class S:
        posts: list = []
        token_resp: dict | None = None
        id_claims: dict = {}

    def make_id_token(**over):
        claims = {
            "iss": ISSUER,
            "aud": CLIENT_ID,
            "sub": "chatgpt|abc",
            "email": "a@b.test",
            "name": "Ada",
            "exp": int(time.time()) + 600,
        }
        claims.update(over)
        return jwt.encode(claims, rsa_key, algorithm="RS256")

    S.make_id_token = staticmethod(make_id_token)
    S.posts = []

    def fake_post(url, fields):
        S.posts.append((url, dict(fields)))
        if S.token_resp is not None:
            return S.token_resp
        return {
            "access_token": "AT1",
            "refresh_token": "RT1",
            "expires_in": 3600,
            "id_token": make_id_token(**{"nonce": S.nonce, **S.id_claims}),
        }

    monkeypatch.setattr(openai_auth, "_post_form", fake_post)
    monkeypatch.setattr(openai_auth, "_signing_key", lambda t: rsa_key.public_key())
    S.id_claims = {}
    S.token_resp = None
    return S


@pytest.fixture
def firebase(monkeypatch):
    created = []

    class _U:
        def __init__(self, uid):
            self.uid = uid

    def create_user(**kw):
        uid = f"fb-{len(created) + 1}"
        created.append((uid, kw))
        return _U(uid)

    monkeypatch.setattr(firebase_auth, "create_user", create_user)
    monkeypatch.setattr(
        firebase_auth, "create_custom_token", lambda uid: f"custom-{uid}".encode()
    )
    return created


def _params(url):
    return dict(urllib.parse.parse_qsl(urllib.parse.urlparse(url).query))


def _begin(db, oidc, uid=None):
    out = openai_auth.start(db, uid)
    p = _params(out["url"])
    oidc.nonce = p["nonce"]
    return out, p


# ------------------------------------------------------------------ config
def test_disabled_by_default_and_everything_refuses():
    assert openai_auth.enabled() is False
    with pytest.raises(openai_auth.OpenAIAuthError):
        openai_auth.start(FakeDb(), None)
    assert openai_auth.public_config()["enabled"] is False


def test_public_config_needs_a_client_id(cfg):
    cfg(openai_siwc_client_id="")
    assert openai_auth.public_config() == {"enabled": False, "mode": "oidc"}
    cfg()
    assert openai_auth.public_config() == {"enabled": True, "mode": "oidc"}
    cfg(openai_auth_mode="api_key", openai_siwc_client_id="")
    assert openai_auth.public_config() == {"enabled": True, "mode": "api_key"}


# ------------------------------------------------------------------- start
def test_start_builds_a_pkce_authorize_url_and_stores_the_session(cfg, oidc):
    db = FakeDb()
    out, p = _begin(db, oidc)
    assert out["url"].startswith(openai_auth.CONFIG.openai_siwc_authorize_url + "?")
    assert p["response_type"] == "code"
    assert p["client_id"] == CLIENT_ID
    assert p["redirect_uri"] == REDIRECT
    assert p["scope"] == "openid profile email"
    assert p["code_challenge_method"] == "S256"
    assert p["state"] == out["state"]
    sess = db.collection(openai_auth.SESSIONS).document(
        hashlib.sha256(out["state"].encode()).hexdigest()
    ).get().to_dict()
    # The verifier is stored server-side only and matches the challenge.
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(sess["verifier"].encode()).digest()
    ).rstrip(b"=").decode()
    assert challenge == p["code_challenge"]
    assert sess["intent"] == "signin" and sess["status"] == "pending"
    assert sess["verifier"] not in out["url"]


def test_start_with_uid_is_a_link_intent(cfg, oidc):
    db = FakeDb()
    out, _ = _begin(db, oidc, uid="u1")
    sess = db.collection(openai_auth.SESSIONS).document(
        hashlib.sha256(out["state"].encode()).hexdigest()
    ).get().to_dict()
    assert sess["intent"] == "link" and sess["uid"] == "u1"


def test_start_without_client_id_says_not_configured(cfg):
    cfg(openai_siwc_client_id="")
    with pytest.raises(openai_auth.OpenAIAuthError, match="not configured"):
        openai_auth.start(FakeDb(), None)


# --------------------------------------------------- full sign-in round trip
def test_signin_round_trip_creates_a_user_stores_tokens_and_mints_a_token(
    cfg, oidc, firebase
):
    db = FakeDb()
    out, _ = _begin(db, oidc)
    state = out["state"]

    assert openai_auth.complete(db, state, None) == {"status": "pending"}

    uid = openai_auth.handle_callback(db, state, "the-code", None)
    assert uid == "fb-1"
    assert firebase == [("fb-1", {"display_name": "Ada"})]

    # Token exchange used PKCE, no client secret.
    url, fields = oidc.posts[0]
    assert url == openai_auth.CONFIG.openai_siwc_token_url
    assert fields["grant_type"] == "authorization_code"
    assert fields["code"] == "the-code"
    assert fields["redirect_uri"] == REDIRECT
    assert fields["code_verifier"]
    assert "client_secret" not in fields

    conn = openai_auth.connection(db, uid)
    assert conn["access_token"] == "AT1" and conn["refresh_token"] == "RT1"
    assert conn["sub"] == "chatgpt|abc" and conn["email"] == "a@b.test"

    done = openai_auth.complete(db, state, None)
    assert done == {
        "status": "done",
        "connected": True,
        "customToken": "custom-fb-1",
        "isNewUser": True,
    }
    # Consumed exactly once.
    assert openai_auth.complete(db, state, None)["status"] == "error"


def test_second_signin_reuses_the_mapped_uid(cfg, oidc, firebase):
    db = FakeDb()
    out, _ = _begin(db, oidc)
    first = openai_auth.handle_callback(db, out["state"], "c", None)
    out2, _ = _begin(db, oidc)
    second = openai_auth.handle_callback(db, out2["state"], "c", None)
    assert first == second == "fb-1"
    assert len(firebase) == 1
    assert openai_auth.complete(db, out2["state"], None)["isNewUser"] is False


# ------------------------------------------------------------------- link
def test_link_intent_attaches_to_the_caller_and_returns_no_custom_token(
    cfg, oidc, firebase
):
    db = FakeDb()
    out, _ = _begin(db, oidc, uid="u1")
    assert openai_auth.handle_callback(db, out["state"], "c", None) == "u1"
    assert firebase == []  # no new Firebase user
    assert openai_auth.connection(db, "u1")["access_token"] == "AT1"
    # Only the same signed-in user may collect it.
    assert openai_auth.complete(db, out["state"], "someone-else")["status"] == "error"


def test_link_refuses_a_chatgpt_account_owned_by_another_user(cfg, oidc, firebase):
    db = FakeDb()
    out, _ = _begin(db, oidc, uid="u1")
    openai_auth.handle_callback(db, out["state"], "c", None)
    out2, _ = _begin(db, oidc, uid="u2")
    with pytest.raises(openai_auth.OpenAIAuthError, match="already linked"):
        openai_auth.handle_callback(db, out2["state"], "c", None)
    assert openai_auth.connection(db, "u2") is None
    assert openai_auth.complete(db, out2["state"], "u2")["status"] == "error"


# ------------------------------------------------------- callback rejections
def test_callback_rejects_unknown_reused_and_cancelled(cfg, oidc, firebase):
    db = FakeDb()
    with pytest.raises(openai_auth.OpenAIAuthError):
        openai_auth.handle_callback(db, "nope", "c", None)
    with pytest.raises(openai_auth.OpenAIAuthError):
        openai_auth.handle_callback(db, "", "c", None)

    out, _ = _begin(db, oidc)
    with pytest.raises(openai_auth.OpenAIAuthError, match="cancelled"):
        openai_auth.handle_callback(db, out["state"], None, "access_denied")
    assert openai_auth.complete(db, out["state"], None)["status"] == "error"

    out, _ = _begin(db, oidc)
    openai_auth.handle_callback(db, out["state"], "c", None)
    with pytest.raises(openai_auth.OpenAIAuthError, match="invalid or already used"):
        openai_auth.handle_callback(db, out["state"], "c", None)


@pytest.mark.parametrize(
    "override",
    [
        {"aud": "someone-else"},
        {"iss": "https://evil.example"},
        {"exp": 1},
        {"nonce": "wrong"},
    ],
)
def test_callback_rejects_a_bad_id_token(cfg, oidc, firebase, override):
    db = FakeDb()
    out, _ = _begin(db, oidc)
    oidc.id_claims = override
    with pytest.raises(openai_auth.OpenAIAuthError, match="verify"):
        openai_auth.handle_callback(db, out["state"], "c", None)
    assert firebase == []
    assert openai_auth.complete(db, out["state"], None)["status"] == "error"


def test_callback_rejects_an_id_token_signed_by_another_key(
    cfg, oidc, firebase, monkeypatch
):
    other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    monkeypatch.setattr(openai_auth, "_signing_key", lambda t: other.public_key())
    db = FakeDb()
    out, _ = _begin(db, oidc)
    with pytest.raises(openai_auth.OpenAIAuthError, match="verify"):
        openai_auth.handle_callback(db, out["state"], "c", None)


def test_callback_rejects_an_expired_session(cfg, oidc):
    db = FakeDb()
    out, _ = _begin(db, oidc)
    ref = db.collection(openai_auth.SESSIONS).document(
        hashlib.sha256(out["state"].encode()).hexdigest()
    )
    ref.update({"expires_at": datetime.now(timezone.utc) - timedelta(seconds=1)})
    with pytest.raises(openai_auth.OpenAIAuthError, match="expired"):
        openai_auth.handle_callback(db, out["state"], "c", None)


def test_flow_is_inert_when_disabled(cfg, oidc):
    cfg(chatgpt_signin_enabled=False)
    with pytest.raises(openai_auth.OpenAIAuthError):
        openai_auth.handle_callback(FakeDb(), "s", "c", None)
    with pytest.raises(openai_auth.OpenAIAuthError):
        openai_auth.complete(FakeDb(), "s", None)


# ----------------------------------------------------- storage + status
def test_tokens_are_encrypted_at_rest_when_a_key_is_configured(cfg, oidc, firebase):
    from cryptography.fernet import Fernet

    cfg(openai_token_encryption_key=Fernet.generate_key().decode())
    db = FakeDb()
    out, _ = _begin(db, oidc)
    uid = openai_auth.handle_callback(db, out["state"], "c", None)
    raw = openai_auth.connection(db, uid)
    assert raw["access_token"] != "AT1" and raw["refresh_token"] != "RT1"
    assert openai_auth.access_token(db, uid) == "AT1"


def test_status_never_contains_a_token(cfg, oidc, firebase):
    db = FakeDb()
    out, _ = _begin(db, oidc, uid="u1")
    openai_auth.handle_callback(db, out["state"], "c", None)
    st = openai_auth.status(db, "u1")
    assert st["connected"] is True and st["provider"] == "openai"
    assert st["email"] == "a@b.test"
    assert "AT1" not in repr(st) and "RT1" not in repr(st)
    assert openai_auth.status(db, "nobody")["provider"] == "gemini"


def test_disconnect_forgets_tokens_but_keeps_the_identity_mapping(
    cfg, oidc, firebase
):
    db = FakeDb()
    out, _ = _begin(db, oidc)
    uid = openai_auth.handle_callback(db, out["state"], "c", None)
    openai_auth.disconnect(db, uid)
    assert openai_auth.connection(db, uid) is None
    assert (
        db.collection(openai_auth.IDENTITIES).document("chatgpt|abc").get().exists
    )


# ---------------------------------------------------------- access token
def _connected(db, oidc, firebase):
    out, _ = _begin(db, oidc, uid="u1")
    openai_auth.handle_callback(db, out["state"], "c", None)
    oidc.posts.clear()


def test_access_token_returns_the_stored_token_while_fresh(cfg, oidc, firebase):
    db = FakeDb()
    _connected(db, oidc, firebase)
    assert openai_auth.access_token(db, "u1") == "AT1"
    assert oidc.posts == []


def test_access_token_refreshes_near_expiry_and_rotates(cfg, oidc, firebase):
    db = FakeDb()
    _connected(db, oidc, firebase)
    openai_auth._token_ref(db, "u1").update(
        {"expires_at": datetime.now(timezone.utc) + timedelta(seconds=5)}
    )
    oidc.token_resp = {
        "access_token": "AT2", "refresh_token": "RT2", "expires_in": 3600
    }
    assert openai_auth.access_token(db, "u1") == "AT2"
    (url, fields) = oidc.posts[0]
    assert fields == {
        "grant_type": "refresh_token",
        "client_id": CLIENT_ID,
        "refresh_token": "RT1",
    }
    conn = openai_auth.connection(db, "u1")
    assert conn["access_token"] == "AT2" and conn["refresh_token"] == "RT2"


def test_force_refresh_refreshes_a_fresh_token(cfg, oidc, firebase):
    db = FakeDb()
    _connected(db, oidc, firebase)
    oidc.token_resp = {"access_token": "AT3", "expires_in": 3600}
    assert openai_auth.access_token(db, "u1", force_refresh=True) == "AT3"
    # No new refresh token issued -> the old one is kept.
    assert openai_auth.connection(db, "u1")["refresh_token"] == "RT1"


def test_a_rejected_refresh_drops_the_connection(cfg, oidc, firebase, monkeypatch):
    db = FakeDb()
    _connected(db, oidc, firebase)
    openai_auth._token_ref(db, "u1").update(
        {"expires_at": datetime.now(timezone.utc) - timedelta(seconds=5)}
    )

    def _reject(url, fields):
        raise openai_auth.OpenAIAuthError("invalid_grant")

    monkeypatch.setattr(openai_auth, "_post_form", _reject)
    with pytest.raises(openai_auth.OpenAIAuthError, match="Reconnect"):
        openai_auth.access_token(db, "u1")
    assert openai_auth.connection(db, "u1") is None


def test_access_token_without_a_connection_raises(cfg):
    with pytest.raises(openai_auth.OpenAIAuthError):
        openai_auth.access_token(FakeDb(), "u1")


# ----------------------------------------------------------- api_key mode
def test_api_key_mode_connects_immediately_and_uses_the_operator_key(
    cfg, monkeypatch
):
    cfg(openai_auth_mode="api_key", openai_siwc_client_id="")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-operator")
    db = FakeDb()
    assert openai_auth.start(db, "u1") == {"mode": "api_key", "connected": True}
    assert openai_auth.access_token(db, "u1") == "sk-operator"
    assert openai_auth.connection(db, "u1")["mode"] == "api_key"
    with pytest.raises(openai_auth.OpenAIAuthError):
        openai_auth.start(db, None)


def test_api_key_mode_needs_the_env_key(cfg, monkeypatch):
    cfg(openai_auth_mode="api_key")
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    with pytest.raises(openai_auth.OpenAIAuthError, match="OPENAI_API_KEY"):
        openai_auth.start(FakeDb(), "u1")
