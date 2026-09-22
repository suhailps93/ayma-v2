"""Google account linking + bounded import (new, mirrors ``instagram.py``'s
OAuth-connect architecture — see that module's docstring and ARCHITECTURE.md
§8.1–§8.7 for the pattern this follows).

OAuth against Google's standard OAuth 2.0 / OpenID Connect endpoints, official
and documented only (no scraping, no undocumented endpoint — see the founder's
explicit decline of an "even if the API doesn't allow it" request for a
different platform; that reasoning applies here too):

* :func:`auth_url` — the URL the client opens to authorise. Requests the
  minimum read-only scopes needed: Gmail (metadata for every message, plus a
  full read for a small filtered subset — see :func:`_gmail_facts` below),
  Calendar events, and the user's email address (to label the connected
  account — mirrors Instagram's username display).
* :func:`connect` — exchange the returned ``code`` for tokens, store the
  refresh token, do one bounded sync pass.
* :func:`disconnect` — revoke the refresh token with Google (a real
  ``/revoke`` call, not just a local delete) and delete the stored token doc.
* :func:`sync_user` — the bounded, capped pull: Gmail (Subject/From headers
  for up to ``google_gmail_limit`` recent messages, plus the plain-text body
  for a small, exclude-filtered subset — see below) and Calendar events
  (title + attendee count, never attendee identities). Everything pulled is
  transient — held only in memory for one Gemini wiki-ingest call — never
  written to any Firestore doc verbatim. Contrast with ``instagram.py``,
  which persists captions into ``raw_turns`` before ingest; Gmail/Calendar
  content is materially more sensitive than a public Instagram caption, so
  this module skips that intermediate persistence step entirely and feeds
  the ingest call directly.

Google Photos was part of this feature at first (item counts only, never
downloads) but has been removed entirely: Google retired third-party
``photoslibrary.readonly`` access to a user's *existing* photo library on
2025-03-31 — a restricted app can now only reach photos it created itself via
that API family, so the old ``_photos_facts`` call would 403 silently in
production (caught by its own try/except) and never actually pull anything.
Users can already share photos with Ayma directly through the app's own photo
upload flow (unrelated to this module — see ``photo_attrs.py`` /
``photo_pipeline.py``), so there is no gap left by dropping this.

**Gmail body reading** (new): the original design read Subject/From headers
only. The founder asked for real body content on a small subset instead of
staying metadata-only forever, with a sender-domain exclude list he can edit
himself later without a code deploy. The mechanism (mirrors how
``admin_config/livekit_manual_cost`` is read in ``infra_cost.py``):

1. The existing metadata pass (``format=metadata``, Subject/From) still runs
   first, over up to ``google_gmail_limit`` messages — the cheap first filter,
   unchanged.
2. Messages whose sender domain matches ``admin_config/gmail_exclude_domains``
   (a Firestore doc holding a ``domains`` list field, case-insensitive,
   subdomain-aware — see :func:`_domain_excluded`) are skipped for body
   reading; if that doc doesn't exist yet, :data:`_DEFAULT_GMAIL_EXCLUDE_DOMAINS`
   is used instead. The founder can add/remove domains by editing that
   Firestore doc directly (Firebase console today, a future admin-dashboard
   field later) — no code change, no deploy.
3. From what's left, up to ``google_gmail_body_limit`` messages (small by
   design — default 8) get a second ``format=full`` fetch. The plain-text
   part is extracted (``payload.parts`` walk for ``text/plain``, or a
   base64url decode of ``payload.body.data`` when there are no parts),
   obvious quoted-reply-chain lines are stripped (``>``-prefixed lines and
   "On ... wrote:" boilerplate — a simple heuristic, not a full quote-parsing
   library), and the result is truncated to a bounded length
   (:data:`_GMAIL_BODY_MAX_CHARS`, 2000 chars).
4. This body text is exactly as transient as everything else in this module
   (see above) — it only ever feeds the in-memory ``lines`` list for one
   ``wiki_ingest.ingest()`` call, never persisted verbatim to any Firestore
   doc.

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
import base64
import json
import logging
import os
import re
import threading
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

from firebase_admin import firestore

import schema
from config import CONFIG
from transcript import ROLE_USER, Turn

logger = logging.getLogger("ayma.google_account")

_AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
_TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
_REVOKE_ENDPOINT = "https://oauth2.googleapis.com/revoke"
_USERINFO_ENDPOINT = "https://openidconnect.googleapis.com/v1/userinfo"
_GMAIL_BASE = "https://gmail.googleapis.com/gmail/v1/users/me"
_CALENDAR_BASE = "https://www.googleapis.com/calendar/v3/calendars/primary/events"

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

# --------------------------------------------------------------------- #
# Gmail body-reading config: a founder-editable exclude list (see module
# docstring) plus the body-extraction bound.
# --------------------------------------------------------------------- #

_GMAIL_BODY_MAX_CHARS = 2000

# Seed default — used only until the founder edits (or creates)
# admin_config/gmail_exclude_domains. Not exhaustive; a representative
# starter set of categories the founder called out explicitly: major banks,
# payment processors, a common health/gov example, and Google's own
# account-security sender (which is itself already surfaced structurally by
# the OAuth connect flow, not something worth re-deriving from an email body).
_DEFAULT_GMAIL_EXCLUDE_DOMAINS: tuple[str, ...] = (
    # Banks
    "chase.com",
    "bankofamerica.com",
    "wellsfargo.com",
    "citi.com",
    "capitalone.com",
    "usbank.com",
    "schwab.com",
    "fidelity.com",
    "vanguard.com",
    # Payments
    "paypal.com",
    "venmo.com",
    "stripe.com",
    # Government / tax
    "irs.gov",
    "ssa.gov",
    # Health
    "healthcare.gov",
    # Known transactional/OTP senders
    "accounts.google.com",
)


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
# (CONFIG.google_sync_window_days), never a full-history pull. Calendar stays
# metadata-only (title + attendee count, never attendee identities or the
# description). Gmail is metadata-only for the bulk (Subject/From headers)
# plus a small, exclude-filtered, plain-text-body read for a bounded subset —
# see the module docstring for the full mechanism.
# --------------------------------------------------------------------- #


def _read_gmail_exclude_domains(db) -> list[str]:
    """Founder-editable sender-domain exclude list for Gmail body reading.
    Mirrors ``infra_cost._read_livekit_manual``'s pattern exactly: a plain
    Firestore doc (``admin_config/gmail_exclude_domains``, ``domains`` list
    field) the founder can hand-edit any time, with a built-in default used
    until that doc exists or while the read fails. Never raises — a Firestore
    hiccup here must not block the whole Gmail pull."""
    try:
        snap = (
            db.collection(schema.ADMIN_CONFIG_COLLECTION)
            .document(schema.GMAIL_EXCLUDE_DOMAINS_DOC)
            .get()
        )
        data = snap.to_dict() if snap.exists else None
    except Exception:  # noqa: BLE001
        logger.exception("gmail_exclude_domains read failed; using default")
        data = None
    domains = (data or {}).get("domains")
    if not domains:
        return list(_DEFAULT_GMAIL_EXCLUDE_DOMAINS)
    return [str(d).strip().lower() for d in domains if str(d).strip()]


def _domain_excluded(domain: str, excluded: list[str]) -> bool:
    """Case-insensitive exact-or-subdomain match: excluding ``chase.com``
    also excludes ``secure.chase.com``, but not ``notchase.com``."""
    domain = (domain or "").strip().lower()
    if not domain:
        return False
    for raw in excluded:
        ex = (raw or "").strip().lower()
        if not ex:
            continue
        if domain == ex or domain.endswith("." + ex):
            return True
    return False


_QUOTE_HEADER_RE = re.compile(r"^\s*On .{0,120} wrote:\s*$", re.IGNORECASE)


def _strip_quoted_lines(text: str) -> str:
    """Simple heuristic quote-stripping (deliberately not a full quote-parsing
    library — see module docstring): drops ``>``-prefixed reply-chain lines
    and "On <date>, <name> wrote:" boilerplate headers."""
    kept = [
        line
        for line in text.splitlines()
        if not line.lstrip().startswith(">") and not _QUOTE_HEADER_RE.match(line)
    ]
    return "\n".join(kept).strip()


def _iter_text_plain_parts(parts):
    for part in parts or []:
        if (part.get("mimeType") or "") == "text/plain":
            yield part
        sub_parts = part.get("parts")
        if sub_parts:
            yield from _iter_text_plain_parts(sub_parts)


def _decode_body_data(data: str) -> str:
    try:
        padded = data + "=" * (-len(data) % 4)
        return base64.urlsafe_b64decode(padded.encode()).decode(
            "utf-8", errors="replace"
        )
    except Exception:  # noqa: BLE001
        return ""


def _extract_gmail_body(msg: dict) -> str:
    """Plain-text body only, never HTML: a ``payload.parts`` walk for the
    first non-empty ``text/plain`` part, falling back to base64url-decoding
    ``payload.body.data`` directly when the message has no ``parts`` at all
    (a simple, non-multipart message). Quote-stripped and truncated to
    :data:`_GMAIL_BODY_MAX_CHARS` before it ever reaches the fact lines."""
    payload = msg.get("payload") or {}
    parts = payload.get("parts")
    text = ""
    if parts:
        for part in _iter_text_plain_parts(parts):
            data = (part.get("body") or {}).get("data")
            if data:
                text = _decode_body_data(data)
                if text:
                    break
    else:
        data = (payload.get("body") or {}).get("data")
        if data:
            text = _decode_body_data(data)
    text = _strip_quoted_lines(text)
    return text[:_GMAIL_BODY_MAX_CHARS]


def _gmail_facts(db, access_token: str) -> list[str]:
    days = CONFIG.google_sync_window_days
    limit = CONFIG.google_gmail_limit
    body_limit = CONFIG.google_gmail_body_limit
    try:
        q = urllib.parse.urlencode(
            {"q": f"newer_than:{days}d", "maxResults": limit}
        )
        listing = _get_json_auth(f"{_GMAIL_BASE}/messages?{q}", access_token)
    except Exception:  # noqa: BLE001
        logger.exception("Gmail list failed")
        return []
    ids = [m.get("id") for m in (listing.get("messages") or []) if m.get("id")]

    excluded = _read_gmail_exclude_domains(db)

    lines: list[str] = []
    # (message id, subject, domain) for the small subset eligible for a body
    # read — anything not on the exclude list, in metadata-pass order, capped
    # at google_gmail_body_limit.
    body_candidates: list[tuple[str, str, str]] = []
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
        if not subject:
            continue
        line = f"Email subject: {subject}"
        if domain:
            line += f" (from {domain})"
        lines.append(line)
        if len(body_candidates) < body_limit and not _domain_excluded(
            domain, excluded
        ):
            body_candidates.append((mid, subject, domain))

    # Second, small, bounded pass: real body content for the filtered subset
    # (see module docstring). Independent per-message try/except so one bad
    # fetch doesn't drop the rest.
    for mid, subject, domain in body_candidates[:body_limit]:
        try:
            full_q = urllib.parse.urlencode({"format": "full"})
            full_msg = _get_json_auth(
                f"{_GMAIL_BASE}/messages/{mid}?{full_q}", access_token
            )
        except Exception:  # noqa: BLE001
            continue
        body = _extract_gmail_body(full_msg)
        if not body:
            continue
        line = "Email body"
        if domain:
            line += f" from {domain}"
        if subject:
            line += f" (Subject: {subject})"
        line += f": {body}"
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


async def sync_user(db, uid: str) -> dict:
    """One bounded sync pass for an already-connected user. Best-effort per
    source — Gmail/Calendar failures are independent, so one disabled API
    doesn't block the other. Never blocks an HTTP request — callers use
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
    try:
        lines.extend(_gmail_facts(db, access_token))
    except Exception:  # noqa: BLE001
        logger.exception("_gmail_facts failed for %s", uid)
    try:
        lines.extend(_calendar_facts(access_token))
    except Exception:  # noqa: BLE001
        logger.exception("_calendar_facts failed for %s", uid)

    written = 0
    if lines:
        import wiki_ingest

        turns = [Turn(ROLE_USER, "\n".join(lines))]
        try:
            # session_id="" — this content is never persisted to raw_turns
            # (see module docstring); force_visibility="private" so imported
            # facts never default to the public profile, mirroring the
            # `finances` page type's own-default-private discipline.
            # record_source=False for the same reason: `source_log` (§
            # fact-source-of-truth, 2026-09-21) keeps the verbatim `turns`
            # text behind a page write so Ayma can cite it later — exactly
            # what this module promises never to do with Gmail/Calendar
            # content (see module docstring: "never persisted verbatim to
            # any Firestore doc").
            written = await wiki_ingest.ingest(
                db, uid, "", turns,
                force_visibility="private", record_source=False,
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
    """Fire-and-forget a sync. Unlike ``completeness.schedule`` (which this
    was modelled on), this is called from inside :func:`connect` — a sync
    function the ``/google/connect`` endpoint always runs via
    ``asyncio.to_thread`` (to keep its own blocking ``urllib`` calls off the
    event loop). That means there is never a *running* event loop in the
    thread ``schedule_sync`` executes in, so the original
    ``asyncio.get_running_loop()`` approach silently no-op'd on every real
    call — confirmed in production (2026-09-20): a real connect stored the
    refresh token fine, but ``oauth_tokens/google.last_synced_at`` was never
    set and no wiki facts appeared, with no error logged anywhere, because
    ``RuntimeError`` was being caught and swallowed exactly as designed for
    the *unit-test* case, not distinguishing it from this real one. Runs the
    sync on its own dedicated thread with a fresh event loop instead, which
    works regardless of the caller's thread."""
    if not db or not uid:
        return False
    threading.Thread(
        target=lambda: asyncio.run(_safe_sync(db, uid)),
        daemon=True,
    ).start()
    return True


def connect(db, uid: str, code: str) -> dict:
    """Exchange ``code``, store the refresh token, kick off a bounded sync.
    Synchronous — the caller runs it off the event loop (mirrors
    ``instagram.connect``), then schedules the actual data pull as a
    background task so the HTTP request never blocks on Gmail/Calendar
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
    pulled from Gmail/Calendar is ever persisted verbatim (see module
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
