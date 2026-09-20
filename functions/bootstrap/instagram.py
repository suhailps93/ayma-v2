"""Instagram linking + import (ARCHITECTURE.md §8.1, §8.2, §8.6, §8.7 steps 1–2)
— plus "Sign in with Instagram" (new, below).

OAuth against the Instagram Graph API ("Instagram API with Instagram Login"):

* :func:`auth_url` — the URL the client opens to authorise.
* :func:`connect` — exchange the returned ``code`` for a long-lived token,
  store it on ``users/{uid}.instagram_access_token``, then pull the account's
  recent photos into ``uploads/{uid}/{filename}`` (one ``user_media`` doc each,
  ``source: instagram_import``, ``moderation_status: pending`` — the unified
  photo pipeline in Step 59 fills embedding / attributes / caption / moderation)
  and the username + each caption into ``raw_turns`` (``source:
  instagram_import``) for the standard wiki ingest.
* :func:`disconnect` — drop the token; already-imported photos stay (§8.1).

No secret is stored in the repo or in :data:`config.CONFIG` — the app secret is
read from ``INSTAGRAM_APP_SECRET`` here at the call site.

**Sign in with Instagram** (new): a genuine account-creation / login method,
architecturally distinct from the "Connect Instagram" import feature above —
it runs *before* any Firebase auth exists (no ``uid`` yet):

* :func:`signin_auth_url` — like :func:`auth_url`, but reachable with no uid.
  ``state`` is a fresh random anti-CSRF token instead of a uid; it is not
  round-tripped/verified server-side — see the function's own docstring for
  why that's a deliberate, documented choice rather than a skipped one.
* :func:`signin` — exchanges the returned ``code`` (reusing :func:`_exchange_code`,
  same as :func:`connect`), fetches the Instagram account's numeric ``id`` +
  ``username``, and resolves it to a Firebase user via the
  ``instagram_identities`` collection (doc id = Instagram numeric id, field
  ``uid``): first sign-in creates a new ``firebase_admin.auth`` user (no
  email — Instagram doesn't reliably provide one — ``username`` becomes
  ``display_name`` when present) and stores the mapping; a repeat sign-in with
  the same Instagram id reuses the same ``uid`` instead of creating a
  duplicate account. Either way it mints and returns a Firebase custom token
  (``firebase_admin.auth.create_custom_token``) for the client to call
  ``FirebaseAuth.instance.signInWithCustomToken`` with.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
import urllib.parse
import urllib.request
from datetime import datetime, timezone

from firebase_admin import auth as firebase_auth
from firebase_admin import firestore, storage

from config import CONFIG
from post_turn import persist_raw_turns
from transcript import ROLE_USER, Turn

logger = logging.getLogger("ayma.instagram")

_AUTH_ENDPOINT = "https://api.instagram.com/oauth/authorize"
_TOKEN_ENDPOINT = "https://api.instagram.com/oauth/access_token"
_LONG_LIVED_ENDPOINT = "https://graph.instagram.com/access_token"
_GRAPH = "https://graph.instagram.com"
_SCOPES = "instagram_business_basic"
_IMPORT_SOURCE = "instagram_import"
_TOKEN_FIELD = "instagram_access_token"
_IDENTITY_COLLECTION = "instagram_identities"
"""Top-level collection mapping an Instagram numeric user id (doc id) to the
Firebase ``uid`` it signed in as (field ``uid``) — a reverse index, so it has
to be a top-level collection keyed by the *Instagram* id, unlike the
per-user ``users/{uid}/oauth_tokens/*`` subcollections (there is no ``uid``
to nest under until this lookup resolves one). No Firestore rule grants any
client access to it — same "falls through to the default-deny catch-all" as
``users/{uid}/oauth_tokens/*`` (see ``google_account.py``'s module docstring
and ``firestore.rules``); it is backend-only, Admin-SDK-only, by construction."""


class InstagramError(RuntimeError):
    pass


def _app_secret() -> str:
    secret = os.getenv("INSTAGRAM_APP_SECRET", "")
    if not (CONFIG.instagram_app_id and secret and CONFIG.instagram_redirect_uri):
        raise InstagramError("Instagram OAuth is not configured.")
    return secret


def _build_auth_url(state: str) -> str:
    params = urllib.parse.urlencode(
        {
            "client_id": CONFIG.instagram_app_id,
            "redirect_uri": CONFIG.instagram_redirect_uri,
            "response_type": "code",
            "scope": _SCOPES,
            "state": state,
        }
    )
    return f"{_AUTH_ENDPOINT}?{params}"


def auth_url(state: str) -> str:
    _app_secret()  # validate config
    return _build_auth_url(state)


def signin_auth_url() -> str:
    """Like :func:`auth_url`, but for "Sign in with Instagram" — reachable
    with no Firebase uid yet, so ``state`` can't be a uid. Uses a fresh random
    anti-CSRF token instead.

    That token is deliberately *not* stored or verified server-side. The
    standard reason ``state`` exists is to stop an attacker's authorization
    ``code`` from being silently accepted by an automatic redirect-URI
    callback the client blindly processes. This app has no such callback —
    there is no deep-link/App-Link handling at all (see
    ``instagram_screen.dart`` / ``google_account_screen.dart``'s docstrings):
    the redirect page is a dead end the user must manually read, then
    manually copy the ``code`` out of and paste back into the app themselves.
    That manual step is what the automatic-redirect CSRF vector `state`
    verification defends against, and it's already required for every OAuth
    flow this app has (:func:`connect` above sets the same precedent — its
    ``state=uid`` is likewise never round-tripped/verified). Instagram's
    authorization codes are additionally single-use, short-lived, and bound
    to this app's ``client_id``/``redirect_uri``, which bounds the residual
    login-CSRF replay risk (a victim would have to be tricked into pasting a
    stranger's freshly-obtained code into their own sign-in dialog before it
    expires). If deep-link handling is ever added, this decision should be
    revisited — an automatic callback is exactly the vector `state`
    verification exists for.
    """
    _app_secret()
    return _build_auth_url(secrets.token_urlsafe(24))


def _post_form(url: str, fields: dict) -> dict:
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read())


def _get_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=20) as resp:
        return json.loads(resp.read())


def _exchange_code(code: str) -> str:
    short = _post_form(
        _TOKEN_ENDPOINT,
        {
            "client_id": CONFIG.instagram_app_id,
            "client_secret": _app_secret(),
            "grant_type": "authorization_code",
            "redirect_uri": CONFIG.instagram_redirect_uri,
            "code": code,
        },
    )
    token = short.get("access_token")
    if not token:
        raise InstagramError("Instagram did not return an access token.")
    # Upgrade to a long-lived (60-day) token.
    params = urllib.parse.urlencode(
        {
            "grant_type": "ig_exchange_token",
            "client_secret": _app_secret(),
            "access_token": token,
        }
    )
    try:
        long = _get_json(f"{_LONG_LIVED_ENDPOINT}?{params}")
        return long.get("access_token") or token
    except Exception:  # noqa: BLE001
        logger.warning("long-lived token exchange failed; using short-lived")
        return token


def _fetch_username(token: str) -> str:
    try:
        me = _get_json(
            f"{_GRAPH}/me?fields=username&access_token={urllib.parse.quote(token)}"
        )
        return str(me.get("username", "")).strip()
    except Exception:  # noqa: BLE001
        logger.exception("Instagram profile fetch failed")
        return ""


def _fetch_profile(token: str) -> dict:
    """``id`` + ``username`` for the authorised account — used by
    :func:`signin` to resolve/create the Firebase identity. Unlike
    :func:`_fetch_username` (best-effort, swallows errors for the import
    flow where a missing username just means one fewer raw_turn), a failure
    here means sign-in genuinely cannot proceed, so it raises."""
    try:
        return _get_json(
            f"{_GRAPH}/me?fields=id,username&access_token={urllib.parse.quote(token)}"
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Instagram profile fetch failed")
        raise InstagramError("Could not fetch Instagram profile.") from exc


def _fetch_media(token: str, limit: int) -> list[dict]:
    fields = "id,caption,media_type,media_url,permalink,timestamp"
    url = (
        f"{_GRAPH}/me/media?fields={fields}"
        f"&limit={limit}&access_token={urllib.parse.quote(token)}"
    )
    try:
        payload = _get_json(url)
    except Exception:  # noqa: BLE001
        logger.exception("Instagram media list failed")
        return []
    items = payload.get("data") or []
    return [m for m in items if m.get("media_type") in ("IMAGE", "CAROUSEL_ALBUM")]


def _download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=30) as resp:
        return resp.read()


def _import_media(db, uid: str, token: str) -> int:
    media = _fetch_media(token, CONFIG.instagram_media_limit)
    bucket = storage.bucket(CONFIG.storage_bucket)
    imported = 0
    captions: list[str] = []
    for m in media:
        mid = str(m.get("id"))
        media_url = m.get("media_url")
        if not (mid and media_url):
            continue
        if m.get("media_type") not in ("IMAGE", "CAROUSEL_ALBUM"):
            continue
        try:
            blob_path = f"uploads/{uid}/ig_{mid}.jpg"
            bucket.blob(blob_path).upload_from_string(
                _download(media_url), content_type="image/jpeg"
            )
        except Exception:  # noqa: BLE001
            logger.exception("Instagram media download failed for %s", mid)
            continue
        # Same §8.5 pipeline as any other photo: moderation → embed →
        # attributes → caption, all onto the user_media doc.
        try:
            import asyncio

            import photo_pipeline

            asyncio.run(
                photo_pipeline.process(db, uid, blob_path, _IMPORT_SOURCE)
            )
        except Exception:  # noqa: BLE001
            logger.exception("Instagram photo pipeline failed for %s", mid)
        # Auto-analysis (§ auto analysis): the user's own imported photo ->
        # face/body read into their private skill-memory pages. Never raises.
        try:
            import asyncio

            import auto_analysis

            asyncio.run(auto_analysis.analyse_photo(db, uid, blob_path))
        except Exception:  # noqa: BLE001
            logger.exception("Instagram auto-analysis failed for %s", mid)
        cap = (m.get("caption") or "").strip()
        if cap:
            captions.append(cap)
        imported += 1

    username = _fetch_username(token)
    lines = []
    if username:
        lines.append(f"My Instagram username is @{username}.")
    lines.extend(f"Instagram photo caption: {c}" for c in captions)
    if lines:
        session_id = (
            f"instagram-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}"
        )
        persist_raw_turns(
            db, uid, session_id, [Turn(ROLE_USER, "\n".join(lines))]
        )
    return imported


def connect(db, uid: str, code: str) -> dict:
    """Exchange ``code``, store the token, import recent media. Synchronous —
    the caller runs it off the event loop."""
    token = _exchange_code(code)
    db.collection("users").document(uid).set(
        {_TOKEN_FIELD: token}, merge=True
    )
    try:
        imported = _import_media(db, uid, token)
    except Exception:  # noqa: BLE001
        logger.exception("Instagram import failed for %s", uid)
        imported = 0
    return {"ok": True, "imported": imported}


def disconnect(db, uid: str) -> None:
    """Remove the stored token. Imported photos are regular uploads now (§8.1)."""
    db.collection("users").document(uid).set(
        {_TOKEN_FIELD: firestore.DELETE_FIELD}, merge=True
    )


def signin(db, code: str) -> dict:
    """"Sign in with Instagram": exchange ``code``, resolve the Instagram
    account to a Firebase user (creating one on first sign-in), and mint a
    custom token. Synchronous — the caller runs it off the event loop, same
    as :func:`connect`.

    Returns ``{"customToken": str, "isNewUser": bool}``.
    """
    token = _exchange_code(code)
    profile = _fetch_profile(token)
    ig_id = str(profile.get("id") or "").strip()
    if not ig_id:
        raise InstagramError("Instagram did not return an account id.")
    username = str(profile.get("username") or "").strip()

    identity_ref = db.collection(_IDENTITY_COLLECTION).document(ig_id)
    snap = identity_ref.get()
    is_new_user = not snap.exists
    if is_new_user:
        create_kwargs: dict = {}
        if username:
            create_kwargs["display_name"] = username
        firebase_user = firebase_auth.create_user(**create_kwargs)
        uid = firebase_user.uid
        identity_ref.set(
            {
                "uid": uid,
                "username": username,
                "created_at": firestore.SERVER_TIMESTAMP,
            }
        )
    else:
        uid = (snap.to_dict() or {}).get("uid")
        if not uid:
            raise InstagramError("Instagram identity mapping is corrupt.")

    custom_token = firebase_auth.create_custom_token(uid)
    if isinstance(custom_token, bytes):
        custom_token = custom_token.decode()
    return {"customToken": custom_token, "isNewUser": is_new_user}
