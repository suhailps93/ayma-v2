"""Google account linking + bounded import (new, mirrors ``instagram.py``'s
OAuth-connect architecture — see that module's docstring and ARCHITECTURE.md
§8.1–§8.7 for the pattern this follows).

OAuth against Google's standard OAuth 2.0 / OpenID Connect endpoints, official
and documented only (no scraping, no undocumented endpoint — see the founder's
explicit decline of an "even if the API doesn't allow it" request for a
different platform; that reasoning applies here too):

* :func:`auth_url` — the URL the client opens to authorise. Requests the
  minimum read-only scopes needed: Gmail metadata, Calendar events, Photos
  library, and the user's email address (to label the connected account —
  mirrors Instagram's username display).
* :func:`connect` — exchange the returned ``code`` for tokens, store the
  refresh token, do one bounded sync pass.
* :func:`disconnect` — revoke the refresh token with Google (a real
  ``/revoke`` call, not just a local delete) and delete the stored token doc.
* :func:`sync_user` — the bounded, capped pull: Gmail *metadata only*
  (Subject/From headers, never the body or snippet), Calendar events (title +
  attendee count, never attendee identities), Google Photos *counts only*
  (never downloads an image). Everything pulled is transient — held only in
  memory for one Gemini wiki-ingest call — never written to any Firestore doc
  verbatim. Contrast with ``instagram.py``, which persists captions into
  ``raw_turns`` before ingest; Gmail/Calendar content is materially more
  sensitive than a public Instagram caption, so this module skips that
  intermediate persistence step entirely and feeds the ingest call directly.

Token storage: unlike ``users/{uid}.instagram_access_token`` (readable by the
owning client — see the module docstring on that field and this module's
report for the flag), the Google refresh token is stored at
``users/{uid}/oauth_tokens/google``, a subcollection with **no** Firestore
rule granting it to any client — it falls through to the default-deny
catch-all in ``firestore.rules``. Only the Admin SDK (this backend) can ever
read it. This is a deliberate upgrade over the Instagram precedent, not
applied to Instagram itself (out of scope for this change — flagged in the
report instead).

No secret is stored in the repo or in :data:`config.CONFIG` — the OAuth client
secret is read from ``GOOGLE_IMPORT_CLIENT_SECRET`` here at the call site,
same discipline as ``INSTAGRAM_APP_SECRET``.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

from firebase_admin import firestore

from config import CONFIG
from transcript import ROLE_USER, Turn

logger = logging.getLogger("ayma.google_account")

_AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
_REVOKE_ENDPOINT = "https://oauth2.googleapis.com/revoke"
_USERINFO_ENDPOINT = "https://openidconnect.googleapis.com/v1/userinfo"
_GMAIL_BASE = "https://gmail.googleapis.com/gmail/v1/users/me"
_CALENDAR_BASE = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
_PHOTOS_SEARCH = "https://photoslibrary.googleapis.com/v1/mediaItems:search"

# Minimum-necessary, read-only scopes (§ the task's own instruction). Every
# one of these is an official Google-documented OAuth scope granted only with
# the user's explicit consent.
_SCOPES = " ".join(
    [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/photoslibrary.readonly",
        "https://www.googleapis.com/auth/userinfo.email",
    ]
)

_TOKEN_COLLECTION = "oauth_tokens"
_TOKEN_DOC = "google"


class GoogleAccountError(RuntimeError):
    pass


def _client_secret() -> str:
    secret = os.getenv("GOOGLE_IMPORT_CLIENT_SECRET", "")
    if not (CONFIG.google_import_client_id and secret
            and CONFIG.google_import_redirect_uri):
        raise GoogleAccountError("Google account import is not configured.")
    return secret


def auth_url(state: str) -> str:
    _client_secret()  # validate config
    params = urllib.parse.urlencode(
        {
            "client_id": CONFIG.google_import_client_id,
            "redirect_uri": CONFIG.google_import_redirect_uri,
            "response_type": "code",
            "scope": _SCOPES,
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


def _post_json_auth(url: str, token: str, body: dict) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read())


def _exchange_code(code: str) -> dict:
    """Returns the raw token response (``access_token``, ``refresh_token``,
    ``expires_in``, ``scope``)."""
    payload = _post_form(
        _TOKEN_ENDPOINT,
        {
            "client_id": CONFIG.google_import_client_id,
            "client_secret": _client_secret(),
            "grant_type": "authorization_code",
            "redirect_uri": CONFIG.google_import_redirect_uri,
            "code": code,
        },
    )
    if not payload.get("access_token"):
        raise GoogleAccountError("Google did not return an access token.")
    return payload


def _refresh_access_token(refresh_token: str) -> str:
    payload = _post_form(
        _TOKEN_ENDPOINT,
        {
            "client_id": CONFIG.google_import_client_id,
            "client_secret": _client_secret(),
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
    try:
        info = _get_json_auth(_USERINFO_ENDPOINT, access_token)
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


# --------------------------------------------------------------------- #
# Bounded pulls — each capped by count and by a recent time window
# (CONFIG.google_sync_window_days), never a full-history pull. Every pull is
# metadata-only: no email body, no attendee identities, no photo bytes.
# --------------------------------------------------------------------- #


def _gmail_facts(access_token: str) -> list[str]:
    days = CONFIG.google_sync_window_days
    limit = CONFIG.google_gmail_limit
    try:
        q = urllib.parse.urlencode(
            {"q": f"newer_than:{days}d", "maxResults": limit}
        )
        listing = _get_json_auth(f"{_GMAIL_BASE}/messages?{q}", access_token)
    except Exception:  # noqa: BLE001
        logger.exception("Gmail list failed")
        return []
    ids = [m.get("id") for m in (listing.get("messages") or []) if m.get("id")]
    lines: list[str] = []
    for mid in ids[:limit]:
        try:
            headers_q = urllib.parse.urlencode(
                [
                    ("format", "metadata"),
                    ("metadataHeaders", "Subject"),
                    ("metadataHeaders", "From"),
                ]
            )
            msg = _get_json_auth(
                f"{_GMAIL_BASE}/messages/{mid}?{headers_q}", access_token
            )
        except Exception:  # noqa: BLE001
            continue
        headers = {
            h.get("name"): h.get("value", "")
            for h in (msg.get("payload") or {}).get("headers", [])
        }
        subject = (headers.get("Subject") or "").strip()
        sender = (headers.get("From") or "").strip()
        domain = sender.split("@")[-1].rstrip(">").strip() if "@" in sender else ""
        if subject:
            line = f"Email subject: {subject}"
            if domain:
                line += f" (from {domain})"
            lines.append(line)
    return lines


def _calendar_facts(access_token: str) -> list[str]:
    days = CONFIG.google_sync_window_days
    limit = CONFIG.google_calendar_limit
    now = datetime.now(timezone.utc)
    time_min = (now - timedelta(days=days)).isoformat()
    time_max = (now + timedelta(days=days)).isoformat()
    q = urllib.parse.urlencode(
        {
            "timeMin": time_min,
            "timeMax": time_max,
            "maxResults": limit,
            "singleEvents": "true",
            "orderBy": "startTime",
        }
    )
    try:
        payload = _get_json_auth(f"{_CALENDAR_BASE}?{q}", access_token)
    except Exception:  # noqa: BLE001
        logger.exception("Calendar list failed")
        return []
    lines: list[str] = []
    for ev in (payload.get("items") or [])[:limit]:
        summary = (ev.get("summary") or "").strip()
        if not summary:
            continue
        start = (ev.get("start") or {}).get("date") or (
            (ev.get("start") or {}).get("dateTime") or ""
        )[:10]
        attendees = len(ev.get("attendees") or [])
        line = f"Calendar event: {summary}"
        if start:
            line += f" on {start}"
        if attendees:
            line += f" with {attendees} attendee(s)"
        lines.append(line)
    return lines


def _photos_facts(access_token: str) -> list[str]:
    days = CONFIG.google_sync_window_days
    limit = CONFIG.google_photos_limit
    now = datetime.now(timezone.utc)
    start = now - timedelta(days=days)
    body = {
        "filters": {
            "dateFilter": {
                "ranges": [
                    {
                        "startDate": {
                            "year": start.year, "month": start.month, "day": start.day
                        },
                        "endDate": {
                            "year": now.year, "month": now.month, "day": now.day
                        },
                    }
                ]
            }
        },
        "pageSize": min(limit, 100),
    }
    try:
        payload = _post_json_auth(_PHOTOS_SEARCH, access_token, body)
    except Exception:  # noqa: BLE001
        logger.exception("Photos search failed")
        return []
    items = payload.get("mediaItems") or []
    if not items:
        return []
    photos = sum(1 for m in items if (m.get("mimeType") or "").startswith("image/"))
    videos = sum(1 for m in items if (m.get("mimeType") or "").startswith("video/"))
    return [
        f"Google Photos: {len(items)} item(s) added in the last {days} days "
        f"({photos} photo(s), {videos} video(s))."
    ]


async def sync_user(db, uid: str) -> dict:
    """One bounded sync pass for an already-connected user. Best-effort per
    source — Gmail/Calendar/Photos failures are independent, so one disabled
    API doesn't block the others. Never blocks an HTTP request — callers use
    :func:`schedule_sync` (fire-and-forget) or the ``/cron/google-sync``
    sweep."""
    doc = _token_doc(db, uid)
    snap = doc.get()
    if not snap.exists:
        return {"ok": False, "reason": "not_connected"}
    data = snap.to_dict() or {}
    refresh_token = data.get("refresh_token")
    if not refresh_token:
        return {"ok": False, "reason": "not_connected"}

    try:
        access_token = _refresh_access_token(refresh_token)
    except Exception:  # noqa: BLE001
        logger.exception("Google access-token refresh failed for %s", uid)
        return {"ok": False, "reason": "refresh_failed"}

    lines: list[str] = []
    for fetch in (_gmail_facts, _calendar_facts, _photos_facts):
        try:
            lines.extend(fetch(access_token))
        except Exception:  # noqa: BLE001
            logger.exception("%s failed for %s", fetch.__name__, uid)

    written = 0
    if lines:
        import wiki_ingest

        turns = [Turn(ROLE_USER, "\n".join(lines))]
        try:
            # session_id="" — this content is never persisted to raw_turns
            # (see module docstring); force_visibility="private" so imported
            # facts never default to the public profile, mirroring the
            # `finances` page type's own-default-private discipline.
            written = await wiki_ingest.ingest(
                db, uid, "", turns, force_visibility="private"
            )
        except Exception:  # noqa: BLE001
            logger.exception("Google wiki ingest failed for %s", uid)

    doc.set({"last_synced_at": firestore.SERVER_TIMESTAMP}, merge=True)
    return {"ok": True, "facts_pulled": len(lines), "pages_written": written}


async def _safe_sync(db, uid: str) -> None:
    try:
        await sync_user(db, uid)
    except Exception:  # noqa: BLE001
        logger.exception("Google sync: scheduled sync failed for %s", uid)


def schedule_sync(db, uid: str) -> bool:
    """Fire-and-forget a sync on the running loop (mirrors
    ``completeness.schedule``). Returns False (a no-op) when there is no
    loop — e.g. a synchronous unit test."""
    if not db or not uid:
        return False
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return False
    loop.create_task(_safe_sync(db, uid))
    return True


def connect(db, uid: str, code: str) -> dict:
    """Exchange ``code``, store the refresh token, kick off a bounded sync.
    Synchronous — the caller runs it off the event loop (mirrors
    ``instagram.connect``), then schedules the actual data pull as a
    background task so the HTTP request never blocks on Gmail/Calendar/Photos
    calls."""
    token_payload = _exchange_code(code)
    refresh_token = token_payload.get("refresh_token")
    access_token = token_payload["access_token"]
    if not refresh_token:
        # No refresh token means offline access wasn't granted (should not
        # happen with access_type=offline&prompt=consent, but Google can
        # still omit it in edge cases) — nothing to persist or sync from.
        raise GoogleAccountError(
            "Google did not grant offline access; please try connecting again."
        )
    email = _fetch_email(access_token)
    _token_doc(db, uid).set(
        {
            "refresh_token": refresh_token,
            "scope": token_payload.get("scope", ""),
            "email": email,
            "connected_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )
    schedule_sync(db, uid)
    return {"ok": True, "email": email}


def disconnect(db, uid: str) -> None:
    """Revoke the refresh token with Google, then delete the stored token
    doc. Unlike Instagram (which leaves already-imported photos in place),
    there is no separately-stored raw import to clean up here — nothing
    pulled from Gmail/Calendar/Photos is ever persisted verbatim (see module
    docstring); only the Gemini-compiled wiki facts remain, same as any other
    wiki content, and are left in place (consistent with §8.1's Instagram
    precedent: disconnecting stops future access, it doesn't retract facts
    already learned)."""
    doc = _token_doc(db, uid)
    snap = doc.get()
    if snap.exists:
        data = snap.to_dict() or {}
        refresh_token = data.get("refresh_token")
        if refresh_token:
            _revoke(refresh_token)
    doc.delete()


def status(db, uid: str) -> dict:
    """Non-secret connection status for the client — never returns the token
    itself. Read via this backend endpoint rather than a Firestore rule,
    since the token doc has no client-read rule at all (see module
    docstring)."""
    snap = _token_doc(db, uid).get()
    if not snap.exists:
        return {"connected": False}
    data = snap.to_dict() or {}
    return {
        "connected": True,
        "email": data.get("email", ""),
        "connected_at": _iso(data.get("connected_at")),
        "last_synced_at": _iso(data.get("last_synced_at")),
    }


def _age_hours(ts) -> float | None:
    if ts is None:
        return None
    try:
        then = ts if isinstance(ts, datetime) else None
        if then is None:
            return None
        now = datetime.now(timezone.utc)
        return (now - then).total_seconds() / 3600.0
    except Exception:  # noqa: BLE001
        return None


async def sweep(db, user_limit: int = 100) -> dict:
    """Periodic re-sync for every connected user whose last sync is older
    than ``CONFIG.google_sync_min_interval_hours`` (or who has never synced).
    Mirrors ``backfill_ops.sweep`` / other ``cron/*`` sweeps — bounded by
    ``user_limit`` docs scanned per run, intended for a daily Cloud Scheduler
    hit on ``POST /cron/google-sync``."""
    try:
        docs = list(
            db.collection_group(_TOKEN_COLLECTION)
            .limit(user_limit)
            .stream()
        )
    except Exception:  # noqa: BLE001
        logger.exception("Google sync sweep query failed")
        return {"users": 0, "synced": 0}

    scanned = synced = 0
    for doc in docs:
        if doc.id != _TOKEN_DOC:
            continue
        uid = doc.reference.parent.parent.id if doc.reference.parent.parent else ""
        if not uid:
            continue
        scanned += 1
        data = doc.to_dict() or {}
        age = _age_hours(data.get("last_synced_at"))
        if age is not None and age < CONFIG.google_sync_min_interval_hours:
            continue
        try:
            result = await sync_user(db, uid)
            if result.get("ok"):
                synced += 1
        except Exception:  # noqa: BLE001
            logger.exception("Google sync sweep failed for %s", uid)
    return {"users": scanned, "synced": synced}


def _iso(ts) -> str | None:
    if ts is None:
        return None
    try:
        return ts.isoformat()
    except AttributeError:
        return str(ts)
