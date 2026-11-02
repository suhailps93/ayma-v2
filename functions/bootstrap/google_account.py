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
himself later without a code deploy. The mechanism (a plain
Firestore config doc under ``admin_config``):

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

Tier-2 sweep monolith split #16:
Split 701-line monolith into focused submodules:
- google_account_oauth: OAuth endpoints, auth_url, token exchange/refresh/revoke,
  userinfo, token doc, connect, disconnect, status
- google_account_gmail: Gmail exclude domains, quote stripping, plain-text body
  extraction, bounded facts (_gmail_facts)
- google_account_calendar: Calendar primary events fetching and formatting
  (_calendar_facts)
This module acts as the facade re-exporting all symbols for 100% backward
compatibility and hosts sync/sweep orchestration (sync_user, schedule_sync, sweep).
"""

from __future__ import annotations

import asyncio
import logging
import sys
import threading
from datetime import datetime, timezone

from firebase_admin import firestore
from timefmt import iso_or_str

import schema
from config import CONFIG
from transcript import ROLE_USER, Turn

# Re-exported from google_account_oauth
from google_account_oauth import (
    GoogleAccountError,
    _AUTH_ENDPOINT,
    _REVOKE_ENDPOINT,
    _SCOPES,
    _TOKEN_COLLECTION,
    _TOKEN_DOC,
    _TOKEN_ENDPOINT,
    _USERINFO_ENDPOINT,
    _client_secret,
    _exchange_code,
    _fetch_email,
    _get_json_auth,
    _post_form,
    _refresh_access_token,
    _revoke,
    _token_doc,
    auth_url,
    connect,
    disconnect,
    status,
)

# Re-exported from google_account_gmail
from google_account_gmail import (
    _DEFAULT_GMAIL_EXCLUDE_DOMAINS,
    _GMAIL_BASE,
    _GMAIL_BODY_MAX_CHARS,
    _QUOTE_HEADER_RE,
    _decode_body_data,
    _domain_excluded,
    _extract_gmail_body,
    _gmail_facts,
    _iter_text_plain_parts,
    _read_gmail_exclude_domains,
    _strip_quoted_lines,
)

# Re-exported from google_account_calendar
from google_account_calendar import (
    _CALENDAR_BASE,
    _calendar_facts,
)

logger = logging.getLogger("ayma.google_account")

__all__ = [
    "CONFIG",
    "GoogleAccountError",
    "ROLE_USER",
    "Turn",
    "_AUTH_ENDPOINT",
    "_CALENDAR_BASE",
    "_DEFAULT_GMAIL_EXCLUDE_DOMAINS",
    "_GMAIL_BASE",
    "_GMAIL_BODY_MAX_CHARS",
    "_QUOTE_HEADER_RE",
    "_REVOKE_ENDPOINT",
    "_SCOPES",
    "_TOKEN_COLLECTION",
    "_TOKEN_DOC",
    "_TOKEN_ENDPOINT",
    "_USERINFO_ENDPOINT",
    "_age_hours",
    "_calendar_facts",
    "_client_secret",
    "_decode_body_data",
    "_domain_excluded",
    "_exchange_code",
    "_extract_gmail_body",
    "_fetch_email",
    "_get_json_auth",
    "_gmail_facts",
    "_iter_text_plain_parts",
    "_post_form",
    "_read_gmail_exclude_domains",
    "_refresh_access_token",
    "_revoke",
    "_safe_sync",
    "_strip_quoted_lines",
    "_token_doc",
    "auth_url",
    "connect",
    "disconnect",
    "iso_or_str",
    "logger",
    "schedule_sync",
    "schema",
    "status",
    "sweep",
    "sync_user",
]


async def sync_user(db, uid: str) -> dict:
    """One bounded sync pass for an already-connected user. Best-effort per
    source — Gmail/Calendar failures are independent, so one disabled API
    doesn't block the other. Never blocks an HTTP request — callers use
    :func:`schedule_sync` (fire-and-forget) or the ``/cron/google-sync``
    sweep."""
    this_mod = sys.modules[__name__]
    token_doc_fn = getattr(this_mod, "_token_doc", _token_doc)
    refresh_fn = getattr(this_mod, "_refresh_access_token", _refresh_access_token)
    gmail_facts_fn = getattr(this_mod, "_gmail_facts", _gmail_facts)
    calendar_facts_fn = getattr(this_mod, "_calendar_facts", _calendar_facts)

    doc = token_doc_fn(db, uid)
    snap = doc.get()
    if not snap.exists:
        return {"ok": False, "reason": "not_connected"}
    data = snap.to_dict() or {}
    refresh_token = data.get("refresh_token")
    if not refresh_token:
        return {"ok": False, "reason": "not_connected"}

    try:
        access_token = refresh_fn(refresh_token)
    except Exception:  # noqa: BLE001
        logger.exception("Google access-token refresh failed for %s", uid)
        return {"ok": False, "reason": "refresh_failed"}

    lines: list[str] = []
    try:
        lines.extend(gmail_facts_fn(db, access_token))
    except Exception:  # noqa: BLE001
        logger.exception("_gmail_facts failed for %s", uid)
    try:
        lines.extend(calendar_facts_fn(access_token))
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
    this_mod = sys.modules[__name__]
    sync_user_fn = getattr(this_mod, "sync_user", sync_user)
    try:
        await sync_user_fn(db, uid)
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
    this_mod = sys.modules[__name__]
    safe_sync_fn = getattr(this_mod, "_safe_sync", _safe_sync)
    threading.Thread(
        target=lambda: asyncio.run(safe_sync_fn(db, uid)),
        daemon=True,
    ).start()
    return True


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
    this_mod = sys.modules[__name__]
    cfg = getattr(this_mod, "CONFIG", CONFIG)
    sync_user_fn = getattr(this_mod, "sync_user", sync_user)
    age_hours_fn = getattr(this_mod, "_age_hours", _age_hours)
    token_coll = getattr(this_mod, "_TOKEN_COLLECTION", _TOKEN_COLLECTION)
    token_doc_id = getattr(this_mod, "_TOKEN_DOC", _TOKEN_DOC)

    try:
        docs = list(
            db.collection_group(token_coll)
            .limit(user_limit)
            .stream()
        )
    except Exception:  # noqa: BLE001
        logger.exception("Google sync sweep query failed")
        return {"users": 0, "synced": 0}

    scanned = synced = 0
    for doc in docs:
        if doc.id != token_doc_id:
            continue
        uid = doc.reference.parent.parent.id if doc.reference.parent.parent else ""
        if not uid:
            continue
        scanned += 1
        data = doc.to_dict() or {}
        age = age_hours_fn(data.get("last_synced_at"))
        if age is not None and age < cfg.google_sync_min_interval_hours:
            continue
        try:
            result = await sync_user_fn(db, uid)
            if result.get("ok"):
                synced += 1
        except Exception:  # noqa: BLE001
            logger.exception("Google sync sweep failed for %s", uid)
    return {"users": scanned, "synced": synced}
