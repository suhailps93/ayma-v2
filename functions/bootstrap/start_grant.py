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


def is_duplicate_face(db, uid: str, embedding: list[float]) -> bool:
    """True when another account that already holds the start grant has a
    verification-selfie embedding at or above the same-person cosine
    threshold used by the deep-dive face check
    (``deep_dive_images._VERIFY_THRESHOLD``). Uses a native COSINE
    ``find_nearest`` over ``users.face_verification.embedding`` (needs the
    vector index in ``firestore.indexes.json``). A failed query fails closed
    (grant withheld, retried on a later read)."""
    import deep_dive_images
    from google.cloud.firestore_v1.base_vector_query import DistanceMeasure
    from google.cloud.firestore_v1.vector import Vector

    field = f"{schema.FIELD_FACE_VERIFICATION}.{schema.FACE_VERIFICATION_EMBEDDING}"
    query = db.collection("users").find_nearest(
        vector_field=field,
        query_vector=Vector(embedding),
        distance_measure=DistanceMeasure.COSINE,
        limit=_DUPLICATE_NEIGHBOURS + 1,
    )
    for snap in query.stream():
        if snap.id == uid:
            continue
        other = snap.to_dict() or {}
        if (other.get("billing") or {}).get("start_grant_unlocked") is False:
            continue  # holds no grant -> not the original
        vec = deep_dive_images._vec_from_raw(
            (other.get(schema.FIELD_FACE_VERIFICATION) or {}).get(
                schema.FACE_VERIFICATION_EMBEDDING
            )
        )
        if vec and (
            deep_dive_images._cosine(embedding, vec)
            >= deep_dive_images._VERIFY_THRESHOLD
        ):
            logger.warning(
                "start grant withheld for %s: selfie matches account %s",
                uid, snap.id,
            )
            return True
    return False


def grant_status(uid: str, data: dict) -> str:
    """Whether the one-time start grant may be unlocked for ``uid``:
    ``GRANT_OK`` only when the account has (1) a verified phone/email on its
    Firebase record, (2) a completed verification selfie
    (``users/{uid}.face_verification.embedding``) and (3) a selfie that does
    not match another grant-holding account (``GRANT_DUPLICATE``, permanent).
    ``GRANT_PENDING`` otherwise (re-checked, negatives cached briefly so a
    locked account doesn't cost a Firebase call per metered request).

    Limits, stated honestly: this is evidence the client-side selfie flow
    ran, plus a same-face dedupe. It is NOT liveness detection — a printed or
    screen photo, or a different photo of the same person that scores under
    the threshold, can still pass; an attacker with a second real face or
    heavy edits is not stopped. It raises the cost of farming the grant; it
    does not eliminate it."""
    now = time.monotonic()
    if _pending_until.get(uid, 0.0) > now:
        return GRANT_PENDING
    status = GRANT_PENDING
    try:
        from deep_dive_images import _vec_from_raw

        embedding = _vec_from_raw(
            (data.get(schema.FIELD_FACE_VERIFICATION) or {}).get(
                schema.FACE_VERIFICATION_EMBEDDING
            )
        )
        if embedding and contact_verified(uid):
            status = (
                GRANT_DUPLICATE
                if is_duplicate_face(get_db(), uid, embedding)
                else GRANT_OK
            )
    except Exception:  # noqa: BLE001 - fail closed, retry on a later read
        logger.exception("start-grant eligibility check failed for %s", uid)
    if status == GRANT_PENDING:
        _pending_until[uid] = now + _UNVERIFIED_RECHECK_SECONDS
    else:
        _pending_until.pop(uid, None)
    return status
