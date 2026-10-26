"""Biometric (face-matching) consent — mandatory for every Ayma account.

Ayma turns a member's photos into face embeddings and matches them against
photos found on the public web (deep dives, reverse-image search, the
public-profile source) and, for deep dives other members run on them from
Explore, against those results too. That is biometric processing, so it only
ever happens with an explicit, separate consent (founder decision
2026-10-25): a required checkbox on the app's sign-in page, recorded here
right after the first sign-in; accounts that predate it get a one-time
consent screen. The consent is mandatory: nobody uses Ayma without it, and
withdrawing it deletes the face data and the account.

- The record lives on ``users/{uid}.biometric_consent`` (backend-authored;
  ``firestore.rules`` lets the client write only ``onboarding_started`` there,
  so a client cannot forge it): ``consented_at``, ``consent_version``,
  ``region`` (device country, when known) and ``source``.
- :func:`has_consent` is the single server-side check. ``main`` applies it to
  every authenticated feature endpoint, and every face-embedding / face-match
  path (``deep_dive_images``, ``deep_dive_social``, ``photo_pipeline``,
  ``photo_notes``, ``reverse_image_search``, the verification selfie) checks it
  again for the user whose face is involved, so a background job never
  embeds or matches someone without a record.
- A record only counts for the current :data:`CONSENT_VERSION`; bumping it
  asks everyone to consent again. The one-time consent screen that existing
  accounts then see also asks them to accept the current Terms and Privacy
  Policy (its "I agree" stays disabled until both boxes are ticked), so a
  bump doubles as the Terms re-acceptance. ``2026-10-25.2``: Terms/Privacy
  update (advertising use, encryption, bold key clauses).
- :func:`withdraw` deletes the face data (:func:`delete_face_data`) and then
  soft-deletes the account (``account_ops.soft_delete``) — the face data is
  removed first so it never enters the recovery quarantine.
"""

from __future__ import annotations

import logging
import re
import time

from firebase_admin import firestore

import account_ops
import schema

logger = logging.getLogger("ayma.biometric_consent")

FIELD = schema.FIELD_BIOMETRIC_CONSENT
CONSENT_VERSION = "2026-10-25.2"

KEY_CONSENTED_AT = "consented_at"
KEY_VERSION = "consent_version"
KEY_REGION = "region"
KEY_SOURCE = "source"
KEY_WITHDRAWN_AT = "withdrawn_at"

SOURCE_APP = "app"
SOURCE_ADMIN_SEED = "admin_seed"

CODE_REQUIRED = "biometric_consent_required"
REQUIRED_MESSAGE = (
    "Ayma needs your face-matching consent before you can keep going."
)

_REGION_RE = re.compile(r"^[A-Za-z]{2}$")

# A positive result is cached briefly to keep the per-request endpoint gate to
# ~zero reads. The cache is per instance, so it is deliberately short, and
# every face job bypasses it with :func:`has_consent_fresh`.
_OK_TTL_SECONDS = 30.0
_OK_CACHE_MAX = 5000
_ok_until: dict[str, float] = {}


class ConsentError(ValueError):
    """The consent request is invalid (not agreed, stale version, bad region)."""


def is_valid_record(record) -> bool:
    """True for a current-version, not-withdrawn consent record."""
    if not isinstance(record, dict):
        return False
    return (
        record.get(KEY_VERSION) == CONSENT_VERSION
        and bool(record.get(KEY_CONSENTED_AT))
        and not record.get(KEY_WITHDRAWN_AT)
    )


def _read_record(db, uid: str) -> dict:
    snap = db.collection(schema.USERS).document(uid).get()
    if not getattr(snap, "exists", False):
        return {}
    rec = (snap.to_dict() or {}).get(FIELD)
    return rec if isinstance(rec, dict) else {}


def _read_ok(db, uid: str) -> bool:
    try:
        ok = is_valid_record(_read_record(db, uid))
    except Exception:  # noqa: BLE001 - fail closed; the next call retries
        logger.exception("biometric consent read failed for %s", uid)
        _ok_until.pop(uid, None)
        return False
    if ok:
        if len(_ok_until) >= _OK_CACHE_MAX:
            _ok_until.clear()
        _ok_until[uid] = time.monotonic() + _OK_TTL_SECONDS
    else:
        _ok_until.pop(uid, None)
    return ok


def has_consent(db, uid: str) -> bool:
    """Whether ``uid`` holds a valid biometric consent (cached for
    :data:`_OK_TTL_SECONDS`; used by the per-request endpoint gate). Fails
    closed (False) on a missing uid or a read error."""
    if not uid or db is None:
        return False
    if _ok_until.get(uid, 0.0) > time.monotonic():
        return True
    return _read_ok(db, uid)


def has_consent_fresh(db, uid: str) -> bool:
    """Like :func:`has_consent` but always reads the user doc (one cheap
    read), so a withdrawal on any instance takes effect at once. Every face
    job calls this at its start and before any web-photo match."""
    if not uid or db is None:
        return False
    return _read_ok(db, uid)


def forget(uid: str) -> None:
    """Drop ``uid`` from the positive cache (after withdrawal)."""
    _ok_until.pop(uid, None)


def _iso(value) -> str:
    iso = getattr(value, "isoformat", None)
    return iso() if callable(iso) else ""


def status(db, uid: str) -> dict:
    """The caller's consent state for the app's consent screen / Settings."""
    rec = _read_record(db, uid)
    consented = is_valid_record(rec)
    return {
        "consented": consented,
        "current_version": CONSENT_VERSION,
        "consent_version": str(rec.get(KEY_VERSION) or "") if consented else "",
        "consented_at": _iso(rec.get(KEY_CONSENTED_AT)) if consented else "",
        "region": str(rec.get(KEY_REGION) or "") if consented else "",
    }


def normalize_region(region: str) -> str:
    """An ISO 3166-1 alpha-2 country code, upper-cased, or "" when unknown.
    Anything else is rejected."""
    text = (region or "").strip()
    if not text:
        return ""
    if not _REGION_RE.match(text):
        raise ConsentError("region must be a two-letter country code.")
    return text.upper()


def record(
    db,
    uid: str,
    *,
    agreed: bool,
    version: str,
    region: str = "",
    source: str = SOURCE_APP,
) -> dict:
    """Validate and store the consent. Raises :class:`ConsentError` unless
    the person explicitly agreed to the current version."""
    if agreed is not True:
        raise ConsentError("Consent requires an explicit agreement.")
    if version != CONSENT_VERSION:
        raise ConsentError(
            "This consent text is out of date. Update the app and try again."
        )
    if source not in (SOURCE_APP, SOURCE_ADMIN_SEED):
        raise ConsentError("Unknown consent source.")
    payload = {
        KEY_CONSENTED_AT: firestore.SERVER_TIMESTAMP,
        KEY_VERSION: CONSENT_VERSION,
        KEY_REGION: normalize_region(region),
        KEY_SOURCE: source,
    }
    # merge=[FIELD] replaces the whole map, so a stale withdrawn_at never
    # survives a fresh consent.
    db.collection(schema.USERS).document(uid).set({FIELD: payload}, merge=[FIELD])
    forget(uid)
    logger.info(
        "biometric consent recorded for %s (version=%s source=%s)",
        uid, CONSENT_VERSION, source,
    )
    return {"consented": True, "consent_version": CONSENT_VERSION}


def delete_face_data(db, bucket, uid: str) -> dict:
    """Delete every face embedding and face-match result held for ``uid``:
    the verification selfie (embedding + image), the embedding on each
    ``user_media`` photo and ``photo_notes`` entry, the face verdicts derived
    from them, and the staged reverse-image matches. The photos themselves
    are left to the account deletion that follows."""
    user = db.collection(schema.USERS).document(uid)
    snap = user.get()
    data = (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
    selfie_path = str(
        (data.get(schema.FIELD_FACE_VERIFICATION) or {}).get(
            schema.FACE_VERIFICATION_STORAGE_PATH
        )
        or ""
    )
    if schema.FIELD_FACE_VERIFICATION in data:
        user.update({schema.FIELD_FACE_VERIFICATION: firestore.DELETE_FIELD})
    selfie_deleted = False
    if selfie_path and bucket is not None:
        try:
            bucket.blob(selfie_path).delete()
            selfie_deleted = True
        except Exception:  # noqa: BLE001 - already gone is fine; log the rest
            logger.warning(
                "verification selfie delete failed for %s", uid, exc_info=True
            )

    media = 0
    for doc in user.collection("user_media").stream():
        if "embedding" in (doc.to_dict() or {}):
            doc.reference.update(
                {"embedding": firestore.DELETE_FIELD, "dim": firestore.DELETE_FIELD}
            )
            media += 1

    notes = 0
    for doc in user.collection("photo_notes").stream():
        d = doc.to_dict() or {}
        if "embedding" in d or "is_user" in d:
            doc.reference.update(
                {"embedding": firestore.DELETE_FIELD, "is_user": firestore.DELETE_FIELD}
            )
            notes += 1

    candidates = 0
    for doc in user.collection("web_photo_candidates").stream():
        doc.reference.delete()
        candidates += 1

    return {
        "selfie_deleted": selfie_deleted,
        "media_embeddings_deleted": media,
        "photo_note_embeddings_deleted": notes,
        "web_photo_candidates_deleted": candidates,
    }


def withdraw(db, bucket, uid: str) -> dict:
    """Withdraw consent: delete the face data, stamp the withdrawal (kept in
    the account quarantine as the audit trail), then delete the account."""
    face = delete_face_data(db, bucket, uid)
    db.collection(schema.USERS).document(uid).set(
        {
            FIELD: {
                KEY_WITHDRAWN_AT: firestore.SERVER_TIMESTAMP,
                KEY_VERSION: CONSENT_VERSION,
            }
        },
        merge=[FIELD],
    )
    forget(uid)
    account = account_ops.soft_delete(db, bucket, uid)
    logger.info("biometric consent withdrawn for %s; account deleted", uid)
    return {"withdrawn": True, "face_data": face, "account": account}
