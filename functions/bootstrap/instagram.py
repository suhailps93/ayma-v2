"""Instagram linking + import (ARCHITECTURE.md §8.1, §8.2, §8.6, §8.7 steps 1–2).

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
"""

from __future__ import annotations

import json
import logging
import os
import urllib.parse
import urllib.request
from datetime import datetime, timezone

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


class InstagramError(RuntimeError):
    pass


def _app_secret() -> str:
    secret = os.getenv("INSTAGRAM_APP_SECRET", "")
    if not (CONFIG.instagram_app_id and secret and CONFIG.instagram_redirect_uri):
        raise InstagramError("Instagram OAuth is not configured.")
    return secret


def auth_url(state: str) -> str:
    _app_secret()  # validate config
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
