"""Sign in with ChatGPT — OIDC + PKCE, server-side (docs/chatgpt-provider.md).

Ships DARK: every entry point is a no-op unless ``CONFIG.chatgpt_signin_enabled``
(``CHATGPT_SIGNIN_ENABLED``) is on, and the OAuth path additionally needs an
OpenAI-issued client id (partner waitlist — none exists yet).

Flow (public client, PKCE, token-endpoint auth ``none`` — no client secret):

1. ``start`` — mints ``state`` + PKCE verifier + OIDC ``nonce``, stores them
   in ``openai_auth_sessions/{sha256(state)}`` (server-only) and returns the
   authorize URL. The app opens it in the system browser.
2. ``handle_callback`` — OpenAI redirects the browser to our HTTPS callback
   (OpenAI requires an exact, HTTPS-registered redirect URI, so a custom
   scheme is not an option). We exchange the code, verify the ID token
   (signature via JWKS, ``iss``, ``aud``, ``exp``, ``nonce``), store the
   tokens server-side and mark the session done.
3. ``complete`` — the app, which has been polling with its secret ``state``,
   collects the outcome exactly once: a Firebase custom token (sign-in intent)
   or a "connected" ack (link intent). No deep link / app-link needed.

Tokens NEVER reach the client, room metadata or logs. They live at
``users/{uid}/oauth_tokens/openai`` — a path no ``firestore.rules`` ``match``
names, so it falls through to default-deny; only the Admin SDK reads it. If
``OPENAI_TOKEN_ENCRYPTION_KEY`` is set they are additionally Fernet-encrypted.

``OPENAI_AUTH_MODE=api_key`` is a dev/test mode: there is no OAuth; the user
"connects" with one call and requests run on the operator's ``OPENAI_API_KEY``
(billed as real money, ``billing="api"``), which lets the whole provider path
be exercised end to end before OpenAI grants a client id.
"""

from __future__ import annotations

import base64
import hashlib
import logging
import os
import secrets
import urllib.parse
from datetime import datetime, timedelta, timezone

from config import CONFIG

logger = logging.getLogger("ayma.openai_auth")

SESSIONS = "openai_auth_sessions"
IDENTITIES = "openai_identities"
SESSION_TTL_SECONDS = 600
_REFRESH_SKEW_SECONDS = 60


class OpenAIAuthError(RuntimeError):
    """User-presentable failure in the ChatGPT connect flow."""


# --------------------------------------------------------------------- config
def enabled() -> bool:
    return bool(CONFIG.chatgpt_signin_enabled)


def mode() -> str:
    return "api_key" if CONFIG.openai_auth_mode == "api_key" else "oidc"


def _require_enabled() -> None:
    if not enabled():
        raise OpenAIAuthError("Sign in with ChatGPT is not available.")


def public_config() -> dict:
    """Non-secret client-facing switch — drives whether the app shows the
    button. ``available`` is False until an OIDC client id is configured."""
    m = mode()
    ready = m == "api_key" or bool(
        CONFIG.openai_siwc_client_id and CONFIG.openai_siwc_redirect_uri
    )
    return {"enabled": enabled() and ready, "mode": m}


# ---------------------------------------------------------------- token store
def _token_ref(db, uid: str):
    return (
        db.collection("users").document(uid)
        .collection("oauth_tokens").document("openai")
    )


def _fernet():
    key = CONFIG.openai_token_encryption_key
    if not key:
        return None
    from cryptography.fernet import Fernet

    return Fernet(key.encode())


def _seal(value: str) -> str:
    f = _fernet()
    return f.encrypt(value.encode()).decode() if f else value


def _open(value: str) -> str:
    f = _fernet()
    return f.decrypt(value.encode()).decode() if f else value


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _api_key() -> str:
    key = os.getenv("OPENAI_API_KEY", "")
    if not key:
        raise OpenAIAuthError("OPENAI_API_KEY is not configured.")
    return key


# ------------------------------------------------------------------ transport
def _post_form(url: str, fields: dict) -> dict:
    import httpx

    resp = httpx.post(
        url,
        data=fields,
        headers={"Accept": "application/json"},
        timeout=CONFIG.openai_request_timeout_seconds,
    )
    try:
        body = resp.json()
    except ValueError:
        body = {}
    if resp.status_code >= 400:
        raise OpenAIAuthError(
            str(body.get("error_description") or body.get("error") or "")
            or f"OpenAI token endpoint returned {resp.status_code}."
        )
    return body


def _signing_key(id_token: str):
    import jwt

    return jwt.PyJWKClient(CONFIG.openai_siwc_jwks_url).get_signing_key_from_jwt(
        id_token
    ).key


def _verify_id_token(id_token: str, nonce: str) -> dict:
    import jwt

    try:
        claims = jwt.decode(
            id_token,
            _signing_key(id_token),
            algorithms=["RS256", "ES256"],
            audience=CONFIG.openai_siwc_client_id,
            issuer=CONFIG.openai_siwc_issuer,
            options={"require": ["exp", "iss", "aud", "sub"]},
        )
    except Exception as exc:  # noqa: BLE001 - any failure = reject
        raise OpenAIAuthError("Could not verify your ChatGPT sign-in.") from exc
    if claims.get("nonce") != nonce:
        raise OpenAIAuthError("Could not verify your ChatGPT sign-in.")
    return claims


# ------------------------------------------------------------------- PKCE
def _pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()
    return verifier, challenge


def _session_ref(db, state: str):
    return db.collection(SESSIONS).document(
        hashlib.sha256(state.encode()).hexdigest()
    )


# ---------------------------------------------------------------------- start
def start(db, uid: str | None) -> dict:
    """Begin a connect. ``uid`` set → LINK intent (an existing user attaches
    ChatGPT); ``None`` → SIGN-IN intent (ChatGPT is the identity).

    OIDC: ``{"mode": "oidc", "url", "state"}``. api_key (dev): connects
    immediately (needs a uid) and returns ``{"mode": "api_key",
    "connected": True}``."""
    _require_enabled()
    if mode() == "api_key":
        if not uid:
            raise OpenAIAuthError(
                "API-key mode can only be connected from a signed-in account."
            )
        _api_key()
        _token_ref(db, uid).set(
            {"mode": "api_key", "connected_at": _now(), "sub": "", "email": ""}
        )
        _invalidate(uid)
        return {"mode": "api_key", "connected": True}
    if not (CONFIG.openai_siwc_client_id and CONFIG.openai_siwc_redirect_uri):
        raise OpenAIAuthError("Sign in with ChatGPT is not configured yet.")
    state = secrets.token_urlsafe(32)
    nonce = secrets.token_urlsafe(16)
    verifier, challenge = _pkce_pair()
    _session_ref(db, state).set(
        {
            "uid": uid,
            "intent": "link" if uid else "signin",
            "verifier": verifier,
            "nonce": nonce,
            "status": "pending",
            "expires_at": _now() + timedelta(seconds=SESSION_TTL_SECONDS),
        }
    )
    query = urllib.parse.urlencode(
        {
            "response_type": "code",
            "client_id": CONFIG.openai_siwc_client_id,
            "redirect_uri": CONFIG.openai_siwc_redirect_uri,
            "scope": CONFIG.openai_siwc_scopes,
            "state": state,
            "nonce": nonce,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        }
    )
    return {
        "mode": "oidc",
        "state": state,
        "url": f"{CONFIG.openai_siwc_authorize_url}?{query}",
    }


# ------------------------------------------------------------------- callback
def _store_tokens(db, uid: str, tokens: dict, claims: dict) -> None:
    expires_in = int(tokens.get("expires_in") or 3600)
    doc = {
        "mode": "oidc",
        "access_token": _seal(tokens["access_token"]),
        "expires_at": _now() + timedelta(seconds=expires_in),
        "sub": str(claims.get("sub") or ""),
        "email": str(claims.get("email") or ""),
        "name": str(claims.get("name") or ""),
        "scope": str(tokens.get("scope") or CONFIG.openai_siwc_scopes),
        "connected_at": _now(),
    }
    if tokens.get("refresh_token"):
        doc["refresh_token"] = _seal(tokens["refresh_token"])
    _token_ref(db, uid).set(doc)


def handle_callback(db, state: str, code: str | None, error: str | None) -> str:
    """Process OpenAI's redirect. Returns the uid the tokens were stored for;
    raises :class:`OpenAIAuthError` (session marked ``error``) on any failure.
    The browser only ever sees a generic success/failure page."""
    _require_enabled()
    ref = _session_ref(db, state) if state else None
    snap = ref.get() if ref is not None else None
    sess = (snap.to_dict() or {}) if snap is not None and snap.exists else None
    if not sess or sess.get("status") != "pending":
        raise OpenAIAuthError("This sign-in link is invalid or already used.")
    expires_at = sess.get("expires_at")
    if isinstance(expires_at, datetime) and expires_at < _now():
        ref.delete()
        raise OpenAIAuthError("This sign-in link expired. Try again from Ayma.")
    try:
        if error or not code:
            raise OpenAIAuthError("ChatGPT sign-in was cancelled.")
        tokens = _post_form(
            CONFIG.openai_siwc_token_url,
            {
                "grant_type": "authorization_code",
                "client_id": CONFIG.openai_siwc_client_id,
                "code": code,
                "redirect_uri": CONFIG.openai_siwc_redirect_uri,
                "code_verifier": sess["verifier"],
            },
        )
        if not tokens.get("access_token") or not tokens.get("id_token"):
            raise OpenAIAuthError("OpenAI did not return the expected tokens.")
        claims = _verify_id_token(tokens["id_token"], sess["nonce"])
        sub = str(claims["sub"])
        uid, is_new = _resolve_identity(db, sub, claims, sess.get("uid"))
        _store_tokens(db, uid, tokens, claims)
    except OpenAIAuthError as exc:
        ref.update({"status": "error", "detail": str(exc)})
        raise
    except Exception as exc:  # noqa: BLE001
        logger.exception("chatgpt callback failed")
        ref.update({"status": "error", "detail": "Sign-in failed. Try again."})
        raise OpenAIAuthError("Sign-in failed. Try again.") from exc
    ref.update({"status": "done", "uid": uid, "is_new": is_new})
    _invalidate(uid)
    return uid


def _resolve_identity(db, sub: str, claims: dict, link_uid: str | None):
    """Map the ChatGPT ``sub`` to an Ayma uid. Link intent: the identity must
    be unclaimed or already this user's. Sign-in: reuse the mapped uid, else
    create a Firebase user (same shape as ``instagram.signin``)."""
    ident_ref = db.collection(IDENTITIES).document(sub)
    snap = ident_ref.get()
    mapped = (snap.to_dict() or {}).get("uid") if snap.exists else None
    if link_uid:
        if mapped and mapped != link_uid:
            raise OpenAIAuthError(
                "That ChatGPT account is already linked to another Ayma account."
            )
        if not mapped:
            ident_ref.set(
                {"uid": link_uid, "email": str(claims.get("email") or ""),
                 "created_at": _now()}
            )
        return link_uid, False
    if mapped:
        return mapped, False
    from firebase_admin import auth as firebase_auth

    kwargs = {}
    name = str(claims.get("name") or "").strip()
    if name:
        kwargs["display_name"] = name
    uid = firebase_auth.create_user(**kwargs).uid
    ident_ref.set(
        {"uid": uid, "email": str(claims.get("email") or ""),
         "created_at": _now()}
    )
    return uid, True


# ------------------------------------------------------------------- complete
def complete(db, state: str, caller_uid: str | None) -> dict:
    """Poll target for the app. ``{"status": "pending"}`` until the callback
    lands, then — exactly once — ``{"status": "done", "connected": True}`` plus
    ``customToken``/``isNewUser`` for a sign-in intent. ``{"status": "error",
    "detail"}`` on failure. The session is consumed on any terminal state."""
    _require_enabled()
    ref = _session_ref(db, state)
    snap = ref.get()
    if not snap.exists:
        return {"status": "error", "detail": "Unknown or expired sign-in."}
    sess = snap.to_dict() or {}
    status = sess.get("status")
    if status == "pending":
        expires_at = sess.get("expires_at")
        if isinstance(expires_at, datetime) and expires_at < _now():
            ref.delete()
            return {"status": "error", "detail": "Sign-in expired. Try again."}
        return {"status": "pending"}
    ref.delete()
    if status == "error":
        return {"status": "error", "detail": str(sess.get("detail") or "Failed.")}
    uid = sess["uid"]
    if sess.get("intent") == "link":
        if caller_uid != uid:
            return {"status": "error", "detail": "Unknown or expired sign-in."}
        return {"status": "done", "connected": True}
    from firebase_admin import auth as firebase_auth

    token = firebase_auth.create_custom_token(uid)
    if isinstance(token, bytes):
        token = token.decode()
    return {
        "status": "done",
        "connected": True,
        "customToken": token,
        "isNewUser": bool(sess.get("is_new")),
    }


# --------------------------------------------------------------------- status
def connection(db, uid: str) -> dict | None:
    """The stored connection doc for ``uid`` (or None). Internal — includes
    (sealed) tokens; never return it to a client."""
    snap = _token_ref(db, uid).get()
    return (snap.to_dict() or {}) if snap.exists else None


def status(db, uid: str) -> dict:
    conn = connection(db, uid) if enabled() else None
    connected = bool(conn)
    connected_at = (conn or {}).get("connected_at")
    return {
        "enabled": public_config()["enabled"],
        "connected": connected,
        "mode": (conn or {}).get("mode") or mode(),
        "email": (conn or {}).get("email") or "",
        "connected_at": (
            connected_at.isoformat() if hasattr(connected_at, "isoformat") else None
        ),
        "provider": "openai" if connected else "gemini",
    }


def disconnect(db, uid: str) -> None:
    """Forget the tokens. The identity mapping stays so signing in with the
    same ChatGPT account later resolves to the same Ayma user."""
    _token_ref(db, uid).delete()
    _invalidate(uid)


# ---------------------------------------------------------------- access token
def _invalidate(uid: str) -> None:
    import llm_provider

    llm_provider.invalidate(uid)


def access_token(db, uid: str, *, force_refresh: bool = False) -> str:
    """A valid bearer for OpenAI calls on behalf of ``uid``. api_key mode →
    the operator's key. OIDC → the stored access token, refreshed first when
    it is within ``_REFRESH_SKEW_SECONDS`` of expiry (or ``force_refresh``).
    A refresh that OpenAI rejects means the grant was revoked: the connection
    is dropped and :class:`OpenAIAuthError` raised, so callers fall back to
    Gemini and the app shows "Reconnect ChatGPT"."""
    conn = connection(db, uid)
    if not conn:
        raise OpenAIAuthError("ChatGPT is not connected.")
    if conn.get("mode") == "api_key":
        return _api_key()
    expires_at = conn.get("expires_at")
    fresh = (
        isinstance(expires_at, datetime)
        and expires_at - _now() > timedelta(seconds=_REFRESH_SKEW_SECONDS)
    )
    if fresh and not force_refresh and conn.get("access_token"):
        return _open(conn["access_token"])
    refresh = conn.get("refresh_token")
    if not refresh:
        if fresh and conn.get("access_token"):
            return _open(conn["access_token"])
        disconnect(db, uid)
        raise OpenAIAuthError("ChatGPT session expired. Reconnect ChatGPT.")
    try:
        tokens = _post_form(
            CONFIG.openai_siwc_token_url,
            {
                "grant_type": "refresh_token",
                "client_id": CONFIG.openai_siwc_client_id,
                "refresh_token": _open(refresh),
            },
        )
        if not tokens.get("access_token"):
            raise OpenAIAuthError("no access token")
    except OpenAIAuthError as exc:
        logger.warning("chatgpt refresh rejected uid=%s: %s", uid, exc)
        disconnect(db, uid)
        raise OpenAIAuthError("ChatGPT session expired. Reconnect ChatGPT.") from exc
    update = {
        "access_token": _seal(tokens["access_token"]),
        "expires_at": _now() + timedelta(seconds=int(tokens.get("expires_in") or 3600)),
    }
    if tokens.get("refresh_token"):
        update["refresh_token"] = _seal(tokens["refresh_token"])
    _token_ref(db, uid).update(update)
    return tokens["access_token"]
