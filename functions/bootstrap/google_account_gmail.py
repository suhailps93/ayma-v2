"""Gmail bounded import and plain-text body extraction.

Handles sender domain exclusion checks, quoted-reply stripping,
base64url payload decoding, and bounded fact generation for Gemini wiki ingest.

Split out of ``google_account.py`` (Tier-2 sweep item #16).
"""

from __future__ import annotations

import base64
import logging
import re
import sys
import urllib.parse

import schema
from config import CONFIG
import config as _base_config
from google_account_oauth import _get_json_auth

logger = logging.getLogger("ayma.google_account.gmail")

_GMAIL_BASE = "https://gmail.googleapis.com/gmail/v1/users/me"


def _get_config():
    if CONFIG is not _base_config.CONFIG:
        return CONFIG
    mod = sys.modules.get("google_account")
    if mod and hasattr(mod, "CONFIG"):
        return mod.CONFIG
    return CONFIG

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

_QUOTE_HEADER_RE = re.compile(r"^\s*On .{0,120} wrote:\s*$", re.IGNORECASE)


def _read_gmail_exclude_domains(db) -> list[str]:
    """Founder-editable sender-domain exclude list for Gmail body reading.
    A plain
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
    cfg = _get_config()
    mod = sys.modules.get("google_account")
    get_json_fn = getattr(mod, "_get_json_auth", _get_json_auth)
    read_exclude_fn = getattr(
        mod, "_read_gmail_exclude_domains", _read_gmail_exclude_domains
    )
    domain_excluded_fn = getattr(mod, "_domain_excluded", _domain_excluded)
    extract_body_fn = getattr(mod, "_extract_gmail_body", _extract_gmail_body)

    days = cfg.google_sync_window_days
    limit = cfg.google_gmail_limit
    body_limit = cfg.google_gmail_body_limit
    try:
        q = urllib.parse.urlencode(
            {"q": f"newer_than:{days}d", "maxResults": limit}
        )
        listing = get_json_fn(f"{_GMAIL_BASE}/messages?{q}", access_token)
    except Exception:  # noqa: BLE001
        logger.exception("Gmail list failed")
        return []
    ids = [m.get("id") for m in (listing.get("messages") or []) if m.get("id")]

    excluded = read_exclude_fn(db)

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
            msg = get_json_fn(
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
        if len(body_candidates) < body_limit and not domain_excluded_fn(
            domain, excluded
        ):
            body_candidates.append((mid, subject, domain))

    # Second, small, bounded pass: real body content for the filtered subset
    # (see module docstring). Independent per-message try/except so one bad
    # fetch doesn't drop the rest.
    for mid, subject, domain in body_candidates[:body_limit]:
        try:
            full_q = urllib.parse.urlencode({"format": "full"})
            full_msg = get_json_fn(
                f"{_GMAIL_BASE}/messages/{mid}?{full_q}", access_token
            )
        except Exception:  # noqa: BLE001
            continue
        body = extract_body_fn(full_msg)
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
