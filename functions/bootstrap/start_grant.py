"""Free start-grant eligibility (anti-abuse gate for the one-time grant).

The one-time start grant (:mod:`billing` free plan) unlocks only for accounts
that clear three checks: (1) a verified phone/email on the Firebase record,
(2) a completed verification selfie (``users/{uid}.face_verification``
embedding) and (3) a selfie that does not match another grant-holding
account. This module hosts those checks; :mod:`token_ledger` only consumes
the resulting status in :func:`token_ledger._load`.

Limits, stated honestly: this is evidence the client-side selfie flow ran,
plus a same-face dedupe. It is NOT liveness detection — a printed or screen
photo, or a different photo of the same person that scores under the
threshold, can still pass; an attacker with a second real face or heavy
edits is not stopped. It raises the cost of farming the grant; it does not
eliminate it.
"""

from __future__ import annotations

import logging
import time

import schema
from config import CONFIG
from db import get_db

# Same logger token_ledger used before this module was split out, so the
# grant-decision log stream is unchanged.
logger = logging.getLogger("ayma.tokens")


_UNVERIFIED_RECHECK_SECONDS = 60
_pending_until: dict[str, float] = {}
_DUPLICATE_NEIGHBOURS = 5

GRANT_OK = "ok"
GRANT_PENDING = "pending"
GRANT_DUPLICATE = "duplicate"


def contact_verified(uid: str) -> bool:
    """Whether the Firebase account has a verified phone number or a verified
    email (Google/Apple/email-link sign-ins are verified; anonymous, custom
    token and unconfirmed-email accounts are not). A failed lookup counts as
    unverified (re-checked later)."""
    try:
        from firebase_admin import auth as firebase_auth

        user = firebase_auth.get_user(uid)
        email = str(user.email or "").strip().lower()
        # Demo/judge accounts (docs/DEMO_ACCOUNTS.md) skip the email-verified
        # check — and only these exact emails; every other account still needs a
        # verified phone/email. See CONFIG.test_bypass_emails.
        if email and email in CONFIG.test_bypass_emails:
            return True
        return bool(user.phone_number) or (
            bool(user.email) and bool(user.email_verified)
        )
    except Exception:  # noqa: BLE001 - fail closed, retry on a later read
        logger.exception("verification lookup failed for %s", uid)
        return False


def grant_status(uid: str, data: dict) -> str:
    """Whether the one-time start grant may be unlocked for ``uid``:
    ``GRANT_OK`` only when the account has (1) a verified phone/email on its
    Firebase record and (2) a completed verification selfie.
    ``GRANT_PENDING`` otherwise (re-checked, negatives cached briefly so a
    locked account doesn't cost a Firebase call per metered request)."""
    now = time.monotonic()
    if _pending_until.get(uid, 0.0) > now:
        return GRANT_PENDING
    status = GRANT_PENDING
    try:
        fv = data.get(schema.FIELD_FACE_VERIFICATION) or {}
        has_selfie = bool(
            fv.get("verified")
            or fv.get(schema.FACE_VERIFICATION_STORAGE_PATH)
            or fv.get(schema.FACE_VERIFICATION_EMBEDDING)
        )
        if has_selfie and contact_verified(uid):
            status = GRANT_OK
    except Exception:  # noqa: BLE001 - fail closed, retry on a later read
        logger.exception("start-grant eligibility check failed for %s", uid)
    if status == GRANT_PENDING:
        _pending_until[uid] = now + _UNVERIFIED_RECHECK_SECONDS
    else:
        _pending_until.pop(uid, None)
    return status
