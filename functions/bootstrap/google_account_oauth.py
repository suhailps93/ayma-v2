"""Google account OAuth 2.0 / OpenID Connect authentication and token lifecycle.

Handles OAuth URL generation, token authorization code exchange, token refresh,
token revocation, userinfo email lookup, Firestore token document management,
and account connection status.

Split out of ``google_account.py`` (Tier-2 sweep item #16).
"""

from __future__ import annotations

import json
import logging
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

from firebase_admin import firestore
from timefmt import iso_or_str

from config import CONFIG
import config as _base_config

logger = logging.getLogger("ayma.google_account.oauth")

_AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
_REVOKE_ENDPOINT = "https://oauth2.googleapis.com/revoke"
_USERINFO_ENDPOINT = "https://openidconnect.googleapis.com/v1/userinfo"

# Minimum-necessary, read-only scopes (§ the task's own instruction). Every
# one of these is an official Google-documented OAuth scope granted only with
# the user's explicit consent. (No Photos scope — see module docstring:
# photoslibrary.readonly no longer grants access to a user's existing
# library, so Google Photos was dropped from this feature entirely.)
_SCOPES = " ".join(
    [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/userinfo.email",
    ]
)

_TOKEN_COLLECTION = "oauth_tokens"
_TOKEN_DOC = "google"


class GoogleAccountError(RuntimeError):
    pass


def _get_config():
    if CONFIG is not _base_config.CONFIG:
        return CONFIG
    mod = sys.modules.get("google_account")
    if mod and hasattr(mod, "CONFIG"):
        return mod.CONFIG
    return CONFIG


def _client_secret() -> str:
    cfg = _get_config()
    secret = os.getenv("GOOGLE_IMPORT_CLIENT_SECRET", "")
    if not (cfg.google_import_client_id and secret and cfg.google_import_redirect_uri):
        raise GoogleAccountError("Google account import is not configured.")
    return secret


def auth_url(state: str) -> str:
    cfg = _get_config()
    mod = sys.modules.get("google_account")
    client_secret_fn = getattr(mod, "_client_secret", _client_secret)
    client_secret_fn()  # validate config
    scopes = getattr(mod, "_SCOPES", _SCOPES)
    params = urllib.parse.urlencode(
        {
            "client_id": cfg.google_import_client_id,
            "redirect_uri": cfg.google_import_redirect_uri,
            "response_type": "code",
            "scope": scopes,
            "state": state,
            # Force a refresh token on every connect (not just the first
            # ever consent) and a real offline (server-side) token.
            "access_type": "offline",
            "prompt": "consent",
        }
    )
    return f"{_AUTH_ENDPOINT}?{params}"


def _post_form(url: str, fields: dict) -> dict:
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read())


def _get_json_auth(url: str, token: str) -> dict:
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {token}"}
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read())


def _exchange_code(code: str) -> dict:
    """Returns the raw token response (``access_token``, ``refresh_token``,
    ``expires_in``, ``scope``)."""
    cfg = _get_config()
    mod = sys.modules.get("google_account")
    client_secret_fn = getattr(mod, "_client_secret", _client_secret)
    post_form_fn = getattr(mod, "_post_form", _post_form)
    payload = post_form_fn(
        _TOKEN_ENDPOINT,
        {
            "client_id": cfg.google_import_client_id,
            "client_secret": client_secret_fn(),
            "grant_type": "authorization_code",
            "redirect_uri": cfg.google_import_redirect_uri,
            "code": code,
        },
    )
    if not payload.get("access_token"):
        raise GoogleAccountError("Google did not return an access token.")
    return payload


def _refresh_access_token(refresh_token: str) -> str:
    cfg = _get_config()
    mod = sys.modules.get("google_account")
    client_secret_fn = getattr(mod, "_client_secret", _client_secret)
    post_form_fn = getattr(mod, "_post_form", _post_form)
    payload = post_form_fn(
        _TOKEN_ENDPOINT,
        {
            "client_id": cfg.google_import_client_id,
            "client_secret": client_secret_fn(),
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        },
    )
    token = payload.get("access_token")
    if not token:
        raise GoogleAccountError("Google refresh-token exchange failed.")
    return token


def _revoke(token: str) -> None:
    try:
        req = urllib.request.Request(
            f"{_REVOKE_ENDPOINT}?{urllib.parse.urlencode({'token': token})}",
            data=b"",
            method="POST",
        )
        urllib.request.urlopen(req, timeout=20).read()
    except Exception:  # noqa: BLE001
        logger.exception("Google token revoke failed")


def _fetch_email(access_token: str) -> str:
    mod = sys.modules.get("google_account")
    get_json_fn = getattr(mod, "_get_json_auth", _get_json_auth)
    try:
        info = get_json_fn(_USERINFO_ENDPOINT, access_token)
        return str(info.get("email", "")).strip()
    except Exception:  # noqa: BLE001
        logger.warning("Google userinfo fetch failed", exc_info=True)
        return ""


def _token_doc(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection(_TOKEN_COLLECTION)
        .document(_TOKEN_DOC)
    )


def connect(db, uid: str, code: str) -> dict:
    """Exchange ``code``, store the refresh token, kick off a bounded sync.
    Synchronous — the caller runs it off the event loop (mirrors
    ``instagram.connect``), then schedules the actual data pull as a
    background task so the HTTP request never blocks on Gmail/Calendar
    calls."""
    mod = sys.modules.get("google_account")
    exchange_fn = getattr(mod, "_exchange_code", _exchange_code)
    fetch_email_fn = getattr(mod, "_fetch_email", _fetch_email)
    token_doc_fn = getattr(mod, "_token_doc", _token_doc)
    schedule_sync_fn = getattr(mod, "schedule_sync", None)

    token_payload = exchange_fn(code)
    refresh_token = token_payload.get("refresh_token")
    access_token = token_payload["access_token"]
    if not refresh_token:
        # No refresh token means offline access wasn't granted (should not
        # happen with access_type=offline&prompt=consent, but Google can
        # still omit it in edge cases) — nothing to persist or sync from.
        raise GoogleAccountError(
            "Google did not grant offline access; please try connecting again."
        )
    email = fetch_email_fn(access_token)
    token_doc_fn(db, uid).set(
        {
            "refresh_token": refresh_token,
            "scope": token_payload.get("scope", ""),
            "email": email,
            "connected_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )
    if schedule_sync_fn:
        schedule_sync_fn(db, uid)
    else:
        import google_account
        google_account.schedule_sync(db, uid)
    return {"ok": True, "email": email}


def disconnect(db, uid: str) -> None:
    """Revoke the refresh token with Google, then delete the stored token
    doc. Unlike Instagram (which leaves already-imported photos in place),
    there is no separately-stored raw import to clean up here — nothing
    pulled from Gmail/Calendar is ever persisted verbatim (see module
    docstring); only the Gemini-compiled wiki facts remain, same as any other
    wiki content, and are left in place (consistent with §8.1's Instagram
    precedent: disconnecting stops future access, it doesn't retract facts
    already learned)."""
    mod = sys.modules.get("google_account")
    token_doc_fn = getattr(mod, "_token_doc", _token_doc)
    revoke_fn = getattr(mod, "_revoke", _revoke)

    doc = token_doc_fn(db, uid)
    snap = doc.get()
    if snap.exists:
        data = snap.to_dict() or {}
        refresh_token = data.get("refresh_token")
        if refresh_token:
            revoke_fn(refresh_token)
    doc.delete()


def status(db, uid: str) -> dict:
    """Non-secret connection status for the client — never returns the token
    itself. Read via this backend endpoint rather than a Firestore rule,
    since the token doc has no client-read rule at all (see module
    docstring)."""
    mod = sys.modules.get("google_account")
    token_doc_fn = getattr(mod, "_token_doc", _token_doc)

    snap = token_doc_fn(db, uid).get()
    if not snap.exists:
        return {"connected": False}
    data = snap.to_dict() or {}
    return {
        "connected": True,
        "email": data.get("email", ""),
        "connected_at": iso_or_str(data.get("connected_at")),
        "last_synced_at": iso_or_str(data.get("last_synced_at")),
    }
