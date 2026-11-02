"""Google Calendar bounded import and events formatting.

Fetches upcoming and recent primary calendar events within the sync window
(metadata only: title and attendee count, never attendee identities or descriptions)
for Gemini wiki ingest.

Split out of ``google_account.py`` (Tier-2 sweep item #16).
"""

from __future__ import annotations

import logging
import sys
import urllib.parse
from datetime import datetime, timedelta, timezone

from config import CONFIG
import config as _base_config
from google_account_oauth import _get_json_auth

logger = logging.getLogger("ayma.google_account.calendar")

_CALENDAR_BASE = "https://www.googleapis.com/calendar/v3/calendars/primary/events"


def _get_config():
    if CONFIG is not _base_config.CONFIG:
        return CONFIG
    mod = sys.modules.get("google_account")
    if mod and hasattr(mod, "CONFIG"):
        return mod.CONFIG
    return CONFIG


def _calendar_facts(access_token: str) -> list[str]:
    cfg = _get_config()
    mod = sys.modules.get("google_account")
    get_json_fn = getattr(mod, "_get_json_auth", _get_json_auth)

    days = cfg.google_sync_window_days
    limit = cfg.google_calendar_limit
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
        payload = get_json_fn(f"{_CALENDAR_BASE}?{q}", access_token)
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
