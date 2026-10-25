"""Live toggle of the ``dev_panel`` feature flag from the app's Developer panel.

``POST /dev/flags`` lets a signed-in caller who knows ``DEV_PANEL_PASSWORD``
(Secret Manager) switch ``dev_panel`` on or off without a deploy. Only that one
flag can be written here; every other flag stays CLI-only (``scripts/flags.py``).

The password is compared in constant time and never logged. Failed attempts are
counted in Firestore (``dev_panel_attempts/{uid}`` and a shared ``_all`` doc) so
the lockout holds across Cloud Run instances: ``MAX_FAILURES_PER_UID`` misses
lock that account out for ``LOCKOUT_SECONDS``; ``MAX_FAILURES_GLOBAL`` misses
from any accounts lock the endpoint for everyone for the same period.
"""

from __future__ import annotations

import hmac
import logging
import time

import feature_flags
from config import CONFIG

logger = logging.getLogger("ayma.dev_flags")

ATTEMPTS_COLLECTION = "dev_panel_attempts"
GLOBAL_DOC = "_all"
MAX_FAILURES_PER_UID = 5
MAX_FAILURES_GLOBAL = 20
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


def current() -> bool:
    """The effective ``dev_panel`` value."""
    return feature_flags.enabled(FLAG)


def set_dev_panel(db, uid: str, password: str, value: bool, *, now: float | None = None) -> bool:
    """Verify ``password`` and write ``dev_panel = value``. Raises
    :class:`NotConfigured`, :class:`LockedOut` or :class:`BadPassword`."""
    expected = CONFIG.dev_panel_password
    if not expected:
        raise NotConfigured()
    t = time.time() if now is None else now
    attempts = db.collection(ATTEMPTS_COLLECTION)
    user_ref = attempts.document(uid)
    global_ref = attempts.document(GLOBAL_DOC)
    user_state = _state(user_ref)
    global_state = _state(global_ref)
    wait = max(_locked_for(user_state, t), _locked_for(global_state, t))
    if wait:
        raise LockedOut(wait)
    if not hmac.compare_digest(password.encode("utf-8"), expected.encode("utf-8")):
        _record_failure(user_ref, user_state, MAX_FAILURES_PER_UID, t)
        _record_failure(global_ref, global_state, MAX_FAILURES_GLOBAL, t)
        logger.warning("dev_panel toggle: wrong password from uid=%s", uid)
        raise BadPassword()
    if user_state.get("failures"):
        user_ref.set({"failures": 0, "locked_until": 0}, merge=True)
    feature_flags.write(db, {FLAG: value}, by=f"app:{uid}")
    logger.info("dev_panel set to %s by uid=%s", value, uid)
    return value
