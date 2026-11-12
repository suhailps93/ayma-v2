"""Proactive outreach when a learned routine fires (founder 2026-11-12).

When the background geofence reports the opted-in user is at a place that
matches one of their LEARNED ROUTINES (:mod:`location_log`), Ayma reaches out
in her own voice: an in-app chat message (``chat_history.append``) plus a push
(``notifications_triggers.notify_checkin``) — both reusing the EXISTING
infrastructure, no new notification system.

**Composition path: TEMPLATE, not model inference (founder preference).** The
message is a deterministic template that slots the learned routine name + the
place, so it carries "her own voice" with NO model call — which keeps this
entirely clear of the LiveKit inference rule (no provider call happens here,
so there is nothing to route anywhere). Richer fact-slotting (e.g. a dog's
name) in her generated voice would run through Ayma's existing LiveKit chat
gateway, never a direct provider — a documented follow-up, not built here.

**Opt-in + frequency-capped.** Only fires when the location log is opted in
(the caller only reaches here after a visit was actually stored, which is
already gated by master-on + log-on). Capped at :data:`MAX_PER_DAY` total and
ONCE per routine per day, enforced in Firestore, so it never spams.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from firebase_admin import firestore

import chat_history
import location_log
import schema

logger = logging.getLogger("ayma.proactive")

# A sane cap so proactive outreach never spams: at most this many proactive
# messages a day, and each distinct routine at most once a day.
MAX_PER_DAY = 3

PROACTIVE_SENDS = schema.PROACTIVE_SENDS


def matching_routine(patterns: list[dict], place_kind: str,
                     now: datetime) -> str | None:
    """The learned-routine name that the user's current place + time matches,
    or ``None``. Pure + deterministic: it recomputes the candidate routine
    names for the current (place_kind, time) and returns one that is actually
    a learned routine for this user."""
    kind = str(place_kind or "").strip()
    if kind not in location_log._KIND_ACTIVITY:
        return None
    labels = {str(p.get("label") or "") for p in (patterns or [])}
    tod = location_log._tod_bucket(now.hour)
    candidates = (
        location_log._tod_routine_name(tod, kind),
        location_log._weekday_routine_name(now.weekday(), kind),
    )
    for name in candidates:
        if name in labels:
            return name
    return None


def compose_routine_message(routine_name: str, place_name: str) -> str:
    """Ayma's proactive line (template; her voice; no model call)."""
    place = str(place_name or "").strip()
    if place:
        return (f"Looks like you're on your {routine_name} — hope {place} is "
                "good today. Tell me about it when you're free. 💛")
    return (f"Looks like you're on your {routine_name} — hope it's a good one. "
            "Tell me about it when you're free. 💛")


def _sends_ref(db, uid: str, day: str):
    return (schema.user_doc(db, uid)
            .collection(PROACTIVE_SENDS).document(day))


def _reserve(db, uid: str, routine_name: str, now: datetime) -> bool:
    """Reserve a send slot for ``routine_name`` today. Returns ``True`` when
    this is the first send of that routine today AND the daily cap is not yet
    reached; ``False`` (do not send) otherwise. Best-effort; a read/write blip
    fails closed to "do not send" so a glitch never spams."""
    day = now.astimezone(timezone.utc).strftime("%Y-%m-%d")
    ref = _sends_ref(db, uid, day)
    try:
        snap = ref.get()
        data = snap.to_dict() or {}
        routines = dict(data.get("routines") or {})
        count = int(data.get("count") or 0)
        if routines.get(routine_name):
            return False
        if count >= MAX_PER_DAY:
            return False
        routines[routine_name] = True
        ref.set({"routines": routines, "count": count + 1,
                 "updated_at": firestore.SERVER_TIMESTAMP}, merge=True)
        return True
    except Exception:  # noqa: BLE001 - never spam on a store glitch
        logger.warning("proactive: reserve failed for %s", uid, exc_info=False)
        return False


def maybe_fire_routine(db, uid: str, place_kind: str, place_name: str = "",
                       now: datetime | None = None) -> str | None:
    """If the user's current place/time matches a learned routine and the daily
    cap allows, post Ayma's proactive chat message and return its text (for the
    caller to push). Returns ``None`` when nothing fires. Never raises."""
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    try:
        patterns = location_log.patterns_for(db, uid)
    except Exception:  # noqa: BLE001
        return None
    routine = matching_routine(patterns, place_kind, now)
    if not routine:
        return None
    if not _reserve(db, uid, routine, now):
        return None
    text = compose_routine_message(routine, place_name)
    try:
        chat_history.append(db, uid, "ayma", text)
    except Exception:  # noqa: BLE001 - the push still goes out
        logger.warning("proactive: chat append failed for %s", uid,
                       exc_info=False)
    return text
