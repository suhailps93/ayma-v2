"""Per-user referral codes + durable attribution (founder feature 2026-09-29).

Design:

* ``users/{uid}.referral_code`` — the user's short shareable code, created
  lazily the first time ``GET /referral`` asks for it. Derived from a hash of
  the uid so it is stable across calls, with a collision check against the
  global lookup collection (rehash with a counter on the vanishingly rare
  clash).
* ``referral_codes/{code} -> {uid}`` — global lookup so redeeming never scans.
* ``users/{uid}.referred_by`` — set exactly once on the redeeming user, plus
  ``users/{referrer}/referrals/{new_uid}`` (a subcollection keyed by the
  referred uid, so recording is naturally idempotent and the list can grow
  unbounded without bloating the user doc).

No rewards are granted anywhere here — this is durable attribution only.
"""

from __future__ import annotations

import hashlib
import re

from firebase_admin import firestore

import schema

# Uppercase, no confusable characters (0/O, 1/I/L) — the code is meant to be
# read aloud or typed from a screenshot.
CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
CODE_LENGTH = 7

# The app's existing web surface is Firebase Hosting (firebase.json ->
# public/), whose default domain for the `ayma-ai` project is below; /r/* is
# rewritten to a tiny landing page that displays the code (public/r.html).
# TODO(domain): swap for the marketing domain (e.g. https://ayma.app) once one
# is registered and wired to Hosting — the path shape /r/{code} stays.
LINK_BASE = "https://ayma-ai.web.app/r/"

REFERRAL_CODES = "referral_codes"

_VALID_CODE = re.compile(r"^[A-Z0-9]{4,16}$")


def _candidate(uid: str, attempt: int) -> str:
    """Deterministic candidate code #``attempt`` for ``uid`` — stable across
    processes/restarts, so retries after a partial write converge on the same
    code instead of minting a new one."""
    digest = hashlib.sha256(f"ayma-referral:{uid}:{attempt}".encode()).digest()
    return "".join(
        CODE_ALPHABET[b % len(CODE_ALPHABET)] for b in digest[:CODE_LENGTH]
    )


def link_for(code: str) -> str:
    return f"{LINK_BASE}{code}"


def code_for(db, uid: str) -> str:
    """The user's referral code, minting it on first request.

    Write order matters for crash safety: the global lookup doc is claimed
    first, then mirrored onto ``users/{uid}``. A crash between the two leaves
    a claimed lookup that the next call recognises as its own (the
    ``owner == uid`` branch) and simply finishes the mirror — never a code
    that two users both hand out.
    """
    user_ref = schema.user_doc(db, uid)
    snap = user_ref.get()
    existing = (snap.to_dict() or {}).get("referral_code") if snap.exists else ""
    if existing:
        return str(existing)

    for attempt in range(64):
        code = _candidate(uid, attempt)
        lookup = db.collection(REFERRAL_CODES).document(code)
        lookup_snap = lookup.get()
        if lookup_snap.exists:
            owner = (lookup_snap.to_dict() or {}).get("uid")
            if owner != uid:
                continue  # someone else's code — rehash
        else:
            lookup.set(
                {"uid": uid, "created_at": firestore.SERVER_TIMESTAMP}
            )
        user_ref.set({"referral_code": code}, merge=True)
        return code
    raise RuntimeError(f"could not mint a referral code for {uid}")


def normalize(raw: str) -> str:
    """Uppercased, whitespace/dash-stripped user input — also accepts a whole
    pasted link and takes its trailing path segment."""
    text = (raw or "").strip()
    if "/" in text:
        text = text.rstrip("/").rsplit("/", 1)[-1]
    return text.replace("-", "").replace(" ", "").upper()


def redeem(db, uid: str, raw_code: str) -> bool:
    """Record that ``uid`` was referred by the owner of ``raw_code``.

    Returns True only when attribution was newly applied. Every rejection is
    silent (False, no exception): unknown/garbage code, self-referral, or the
    user already carrying a ``referred_by`` — redeeming is best-effort sugar
    at sign-up, never something that can fail an account creation.
    """
    code = normalize(raw_code)
    if not code or not _VALID_CODE.match(code):
        return False

    lookup_snap = db.collection(REFERRAL_CODES).document(code).get()
    if not lookup_snap.exists:
        return False
    referrer = str((lookup_snap.to_dict() or {}).get("uid") or "")
    if not referrer or referrer == uid:
        return False

    user_ref = schema.user_doc(db, uid)
    snap = user_ref.get()
    if snap.exists and (snap.to_dict() or {}).get("referred_by"):
        return False  # already attributed — first referrer wins, forever

    user_ref.set(
        {
            "referred_by": referrer,
            "referred_code": code,
            "referred_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )
    # Keyed by the referred uid — re-running can only overwrite the same doc,
    # so the referrer's list records each referred user exactly once.
    schema.user_subcollection(db, referrer, "referrals").document(uid).set(
        {"referred_at": firestore.SERVER_TIMESTAMP}
    )
    return True
