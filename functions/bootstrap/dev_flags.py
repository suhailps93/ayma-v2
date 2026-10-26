"""Live toggle of the ``dev_panel`` feature flag from the app's Developer panel.

``POST /dev/flags`` lets a signed-in caller who knows ``DEV_PANEL_PASSWORD``
(Secret Manager) switch ``dev_panel`` on or off without a deploy. Only that one
flag can be written here; every other flag stays CLI-only (``scripts/flags.py``).

The password is compared in constant time and never logged (neither is any
guess). Failed attempts are counted in Firestore so the lockout holds across
Cloud Run instances, per caller and never for everyone because of a few:

- ``MAX_FAILURES_PER_UID`` misses lock that account for ``LOCKOUT_SECONDS``
  (``dev_panel_attempts/{uid}``);
- ``MAX_FAILURES_PER_IP`` misses lock that client address for the same period
  (``dev_panel_attempts/ip_<hash>``; the address is hashed, never stored);
- a generous global ceiling of ``MAX_FAILURES_GLOBAL`` misses per
  ``LOCKOUT_SECONDS`` window (``_all``) stops a distributed guessing run. Each
  account and address is capped well below it, so a handful of clients can
  never trip it.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import time

import feature_flags
from config import CONFIG

logger = logging.getLogger("ayma.dev_flags")

ATTEMPTS_COLLECTION = "dev_panel_attempts"
GLOBAL_DOC = "_all"
MAX_FAILURES_PER_UID = 5
MAX_FAILURES_PER_IP = 10
MAX_FAILURES_GLOBAL = 200
LOCKOUT_SECONDS = 15 * 60
FLAG = "dev_panel"


class NotConfigured(Exception):
    """``DEV_PANEL_PASSWORD`` is unset — every toggle is refused."""


class BadPassword(Exception):
    """The supplied password did not match."""


class LockedOut(Exception):
    def __init__(self, retry_after: int):
        super().__init__(f"locked for {retry_after}s")
        self.retry_after = retry_after


def _state(ref) -> dict:
    snap = ref.get()
    return (snap.to_dict() or {}) if snap.exists else {}


def _locked_for(state: dict, now: float) -> int:
    until = state.get("locked_until") or 0
    return int(until - now) + 1 if now < until else 0


def _record_failure(ref, state: dict, limit: int, now: float) -> None:
    failures = int(state.get("failures") or 0) + 1
    if failures >= limit:
        ref.set({"failures": 0, "locked_until": now + LOCKOUT_SECONDS}, merge=True)
    else:
        ref.set({"failures": failures, "locked_until": 0}, merge=True)


def _record_global_failure(ref, state: dict, now: float) -> None:
    """Fixed-window counter: once the window holds ``MAX_FAILURES_GLOBAL``
    misses the endpoint is closed until the window ends."""
    start = float(state.get("window_start") or 0)
    if not start or now >= start + LOCKOUT_SECONDS:
        start, failures = now, 0
    else:
        failures = int(state.get("failures") or 0)
    failures += 1
    update = {"window_start": start, "failures": failures}
    if failures >= MAX_FAILURES_GLOBAL:
        update["locked_until"] = start + LOCKOUT_SECONDS
    ref.set(update, merge=True)


def _ip_doc_id(ip: str) -> str:
    return "ip_" + hashlib.sha256(ip.encode("utf-8")).hexdigest()[:32]


def current() -> bool:
    """The effective ``dev_panel`` value."""
    return feature_flags.enabled(FLAG)


def set_dev_panel(
    db, uid: str, password: str, value: bool, *, ip: str = "", now: float | None = None
) -> bool:
    """Verify ``password`` and write ``dev_panel = value``. ``ip`` is the
    caller's address (empty when unknown: only the account and global limits
    then apply). Raises :class:`NotConfigured`, :class:`LockedOut` or
    :class:`BadPassword`."""
    expected = CONFIG.dev_panel_password
    if not expected:
        raise NotConfigured()
    t = time.time() if now is None else now
    attempts = db.collection(ATTEMPTS_COLLECTION)
    user_ref = attempts.document(uid)
    ip_ref = attempts.document(_ip_doc_id(ip)) if ip else None
    global_ref = attempts.document(GLOBAL_DOC)
    user_state = _state(user_ref)
    ip_state = _state(ip_ref) if ip_ref else {}
    global_state = _state(global_ref)
    wait = max(
        _locked_for(user_state, t),
        _locked_for(ip_state, t),
        _locked_for(global_state, t),
    )
    if wait:
        raise LockedOut(wait)
    if not hmac.compare_digest(password.encode("utf-8"), expected.encode("utf-8")):
        _record_failure(user_ref, user_state, MAX_FAILURES_PER_UID, t)
        if ip_ref:
            _record_failure(ip_ref, ip_state, MAX_FAILURES_PER_IP, t)
        _record_global_failure(global_ref, global_state, t)
        logger.warning("dev_panel toggle: wrong password from uid=%s", uid)
        raise BadPassword()
    if user_state.get("failures"):
        user_ref.set({"failures": 0, "locked_until": 0}, merge=True)
    if ip_ref and ip_state.get("failures"):
        ip_ref.set({"failures": 0, "locked_until": 0}, merge=True)
    feature_flags.write(db, {FLAG: value}, by=f"app:{uid}")
    logger.info("dev_panel set to %s by uid=%s", value, uid)
    return value
