"""Authoritative 18+ age gate.

Ayma is 18+ only (Terms, Privacy "Children"). This module is the single place
the server decides whether a birthdate makes someone an adult, and what happens
when it doesn't:

- ``age_on`` / ``is_adult`` — whole-year age, leap-year correct (a Feb 29
  birthday is reached on Mar 1 in a common year), against today's **UTC**
  calendar date. A stored Firestore timestamp is read as its UTC date, the same
  basis ``firestore.rules``' ``isAdultBirthdate()`` uses, so a write the rules
  accepted is never later judged differently here.
- ``status`` — OK / MISSING (no usable birthdate) / UNDERAGE for a user.
- ``enforce`` — the gate the endpoints call. A user already closed as a minor,
  or whose stored birthdate is under 18, is refused; an under-18 profile is
  closed through the existing account soft-delete (privacy policy "Children":
  we close the account and delete the data — recovery window, then the
  scheduled purge), flagged ``closed_reason: underage`` so it can never be
  recovered, and logged.
"""

from __future__ import annotations

import logging
import time
from datetime import date, datetime, timezone

from firebase_admin import firestore

import account_ops
import schema

logger = logging.getLogger("ayma.age_gate")

MIN_AGE_YEARS = 18

STATUS_OK = "ok"
STATUS_MISSING = "birthdate_required"
STATUS_UNDERAGE = "underage"

CLOSED_REASON_UNDERAGE = "underage"

UNDERAGE_MESSAGE = "You must be 18 or older to use Ayma."
MISSING_MESSAGE = "Add your date of birth to continue. Ayma is 18+ only."

# Adults do not become minors, so a positive result is cached briefly to keep
# the gate to ~zero extra reads on hot endpoints.
_OK_TTL_SECONDS = 300.0
_OK_CACHE_MAX = 5000
_ok_until: dict[str, float] = {}


class AgeGateError(Exception):
    """The caller may not use this feature. ``code`` is ``underage`` or
    ``birthdate_required``."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def today_utc() -> date:
    return datetime.now(timezone.utc).date()


def to_date(value) -> date | None:
    """A birthdate as a calendar date, or None when it isn't one. Accepts a
    Firestore timestamp / datetime (read as its UTC date), a ``date``, or an
    ISO ``YYYY-MM-DD`` / ISO datetime string."""
    if isinstance(value, datetime):
        if value.tzinfo is not None:
            value = value.astimezone(timezone.utc)
        return value.date()
    if isinstance(value, date):
        return value
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            return date.fromisoformat(text)
        except ValueError:
            pass
        try:
            return to_date(datetime.fromisoformat(text.replace("Z", "+00:00")))
        except ValueError:
            return None
    return None


def age_on(birthdate: date, today: date) -> int:
    """Whole years between ``birthdate`` and ``today``."""
    had_birthday = (today.month, today.day) >= (birthdate.month, birthdate.day)
    return today.year - birthdate.year - (0 if had_birthday else 1)


def is_adult(value, today: date | None = None) -> bool:
    """True only for a parseable birthdate that makes the person 18+."""
    bd = to_date(value)
    if bd is None:
        return False
    return age_on(bd, today or today_utc()) >= MIN_AGE_YEARS


def status(profile: dict | None, today: date | None = None) -> str:
    bd = to_date((profile or {}).get(schema.PF_BIRTHDATE))
    if bd is None:
        return STATUS_MISSING
    if age_on(bd, today or today_utc()) < MIN_AGE_YEARS:
        return STATUS_UNDERAGE
    return STATUS_OK


def is_closed_underage(db, uid: str) -> bool:
    snap = db.collection(schema.DELETED_ACCOUNTS).document(uid).get()
    if not snap.exists:
        return False
    return (snap.to_dict() or {}).get("closed_reason") == CLOSED_REASON_UNDERAGE


def close_underage(db, bucket, uid: str, *, source: str) -> None:
    """Close an account found to belong to a minor: soft-delete through the
    normal account machinery, mark it unrecoverable, and log."""
    logger.warning("underage account closed uid=%s source=%s", uid, source)
    try:
        account_ops.soft_delete(db, bucket, uid)
    finally:
        db.collection(schema.DELETED_ACCOUNTS).document(uid).set(
            {
                "closed_reason": CLOSED_REASON_UNDERAGE,
                "closed_at": firestore.SERVER_TIMESTAMP,
                "closed_source": source,
            },
            merge=True,
        )
    _ok_until.pop(uid, None)


def enforce(db, bucket_factory, uid: str, *, require_birthdate: bool) -> None:
    """Raise :class:`AgeGateError` unless ``uid`` may use the feature.

    ``require_birthdate=False`` still refuses minors but lets a user with no
    birthdate yet through (they are mid-onboarding; the on-screen form collects
    it first).
    """
    if _ok_until.get(uid, 0.0) > time.monotonic():
        return

    if is_closed_underage(db, uid):
        raise AgeGateError(STATUS_UNDERAGE, UNDERAGE_MESSAGE)

    profile = schema.profile_doc(db, uid).get().to_dict() or {}
    state = status(profile)
    if state == STATUS_UNDERAGE:
        try:
            close_underage(db, bucket_factory(), uid, source="server_check")
        except Exception:  # noqa: BLE001 - still refuse; next call retries
            logger.exception("closing underage account failed uid=%s", uid)
        raise AgeGateError(STATUS_UNDERAGE, UNDERAGE_MESSAGE)
    if state == STATUS_MISSING:
        if require_birthdate:
            raise AgeGateError(STATUS_MISSING, MISSING_MESSAGE)
        return

    if len(_ok_until) >= _OK_CACHE_MAX:
        _ok_until.clear()
    _ok_until[uid] = time.monotonic() + _OK_TTL_SECONDS


def clear_cache() -> None:
    _ok_until.clear()
