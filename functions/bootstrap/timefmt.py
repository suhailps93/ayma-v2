"""Shared time/format micro-helpers (sweep finding BE-#5).

Seven modules each grew a private ``_iso`` timestamp formatter, three a
private ``_now`` clock, and ``billing`` an ISO *parser* also called ``_iso``;
the copies already drifted (``report_hub`` passes strings through while
``appearance``/``story`` map them to ``None``; ``fact_source`` and
``biometric_consent`` default to ``""`` while the rest default to ``None``).
One implementation per exact semantic lives here — every call site keeps its
behaviour, drift included.
"""

from __future__ import annotations

from datetime import datetime, timezone


def utcnow() -> datetime:
    """The current UTC time.

    Was ``_now`` in ``provider_spend`` / ``profile_manual`` / ``mcp_oauth``
    (three identical copies).
    """
    return datetime.now(timezone.utc)


def iso_or_none(v, *, keep_strings: bool = False):
    """A Firestore-ish timestamp as an ISO string, or ``None``.

    ``None`` stays ``None``; anything with ``isoformat`` is rendered;
    anything else is ``None``. A value that is *already* a string passes
    through only with ``keep_strings=True`` (``report_hub``'s drifted copy
    did; ``appearance``'s and ``story``'s map it to ``None``) — call sites
    keep whichever their copy had.
    """
    if isinstance(v, str):
        return v if keep_strings else None
    if v is None:
        return None
    return v.isoformat() if hasattr(v, "isoformat") else None


def iso_or_str(v, none=None):
    """A Firestore-ish timestamp as an ISO string, never ``None``-ish.

    ``None`` becomes ``none`` (``google_account`` kept ``None``,
    ``fact_source`` kept ``""``); anything with ``isoformat`` is rendered;
    anything else falls back to ``str(v)``.
    """
    if v is None:
        return none
    try:
        return v.isoformat()
    except AttributeError:
        return str(v)


def iso_or_empty(v) -> str:
    """A Firestore-ish timestamp as an ISO string, ``""`` when missing.

    Was ``biometric_consent._iso``: no ``str()`` fallback — anything without
    ``isoformat`` (including an already-a-string value) becomes ``""``.
    """
    iso = getattr(v, "isoformat", None)
    return iso() if callable(iso) else ""


def parse_iso_utc(value) -> datetime | None:
    """Parse a RevenueCat ISO-8601 timestamp (``...Z`` or ``+00:00``) to an
    aware UTC datetime, or None when absent/unparseable.

    Was ``billing._iso`` — the one ``_iso`` that parsed instead of formatted,
    renamed to say so.
    """
    if not value:
        return None
    try:
        dt = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
