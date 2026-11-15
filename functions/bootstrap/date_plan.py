"""Plan a date in a human-to-human DM thread (payment-free).

Either person proposes a concrete place and time; the card is posted in
the thread. Each person approves for themselves; a "Suggest a change"
revises the plan and RESETS approvals. Once both approve the plan is
``both_approved`` - the terminal approved state the "date moment"
step-in (:mod:`date_moments`) reads.

Plan state lives on the card message doc's ``date_plan`` map, so the
thread stream the clients already watch carries every state change::

    proposed -> partially_approved -> both_approved

The place carries a GEOGRAPHIC ANCHOR (``place_name`` + an ``address``
string and/or ``lat``/``lng``) so the step-in can match the user's
arrival to it; the place must be locatable (a name plus an address or
coordinates). This module makes NO model-provider call: Ayma inference
stays on the existing LiveKit-routed path (founder rule, 2026-11-02),
and this feature does not route around it.
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone

from firebase_admin import firestore

import dm_schema

STATUS_PROPOSED = "proposed"
STATUS_PARTIALLY_APPROVED = "partially_approved"
STATUS_BOTH_APPROVED = "both_approved"


def _coord(value) -> float | None:
    """A latitude/longitude as a float, or ``None`` when absent/unparsable."""
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


# A proposed time more than this far in the past is rejected: the card must
# never go out with a time that has already passed (founder report
# 2026-11-14). The grace covers clock skew and a plan for "right now".
_PAST_START_GRACE = timedelta(minutes=5)

_PAST_TIME_MSG = "That time has already passed. Pick a time in the future."

# A ``time_label`` names a day in the USER's own frame, so an explicit past-day
# word is unambiguously past regardless of the server's timezone.
_PAST_DAY_RE = re.compile(
    r"\b(yesterday|last\s+night|day\s+before\s+yesterday|last\s+week|"
    r"last\s+(mon|tues?|wednes|thurs?|fri|satur|sun)day)\b",
    re.I,
)
_WEEKDAYS = (
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"
)
# The widest real UTC offset: a label we can pin to a clock time but not to a
# timezone is only refused when it is past beyond any plausible zone's doubt,
# so a valid future plan is never wrongly blocked.
_TZ_SLACK = timedelta(hours=14)
_TIME_RE = re.compile(
    r"\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)\b|\b(\d{1,2}):(\d{2})\b",
    re.I,
)


def _parse_starts_at(value: str) -> datetime | None:
    """An ISO 8601 start time as an aware datetime, or None when absent/unparseable."""
    text = (value or "").strip()
    if not text:
        return None
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _time_of_day(s: str) -> tuple[int, int] | None:
    """``(hour, minute)`` parsed from a label's clock time, or None."""
    if "midnight" in s:
        return (0, 0)
    if re.search(r"\bnoon\b", s):
        return (12, 0)
    m = _TIME_RE.search(s)
    if not m:
        return None
    if m.group(3):  # 12-hour am/pm form
        hour = int(m.group(1))
        mins = int(m.group(2) or 0)
        pm = m.group(3).lower().startswith("p")
        if pm and hour != 12:
            hour += 12
        if not pm and hour == 12:
            hour = 0
        return (hour % 24, mins)
    return (int(m.group(4)) % 24, int(m.group(5)))  # 24-hour form


def _resolve_label_time(time_label: str, now: datetime) -> datetime | None:
    """Best-effort resolve a human ``time_label`` ("yesterday at 7pm",
    "tomorrow 8pm", "Nov 20 7pm") to an aware datetime (UTC day), or None when
    it carries no day we can pin down. Used only to catch a clearly-past time
    when the model left ``starts_at`` empty (Scout NOTE 214 Defect B)."""
    s = (time_label or "").strip().lower()
    if not s:
        return None
    today = now.date()
    day = None
    if "day before yesterday" in s:
        day = today - timedelta(days=2)
    elif "yesterday" in s or "last night" in s:
        day = today - timedelta(days=1)
    elif "day after tomorrow" in s:
        day = today + timedelta(days=2)
    elif "tomorrow" in s:
        day = today + timedelta(days=1)
    elif any(
        w in s
        for w in ("today", "tonight", "this evening", "this afternoon",
                  "this morning", "right now")
    ):
        day = today
    else:
        for i, wd in enumerate(_WEEKDAYS):
            if wd in s:
                ahead = (i - today.weekday()) % 7
                if "last" in s:
                    ahead -= 7
                elif ahead == 0:
                    ahead = 7  # a bare weekday means the upcoming one
                day = today + timedelta(days=ahead)
                break
    tod = _time_of_day(s)
    if day is not None:
        hour, mins = tod if tod else (12, 0)
        return datetime(day.year, day.month, day.day, hour, mins, tzinfo=timezone.utc)
    # No relative day word — try an absolute date (needs a digit, e.g.
    # "Nov 20 at 7pm"); plain prose with no date resolves to nothing.
    if not re.search(r"\d", s):
        return None
    try:
        from dateutil import parser as _dateparser
        base = now.replace(
            hour=(tod or (12, 0))[0], minute=(tod or (12, 0))[1],
            second=0, microsecond=0,
        )
        dt = _dateparser.parse(s, default=base, fuzzy=True)
    except (ValueError, OverflowError, TypeError):
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _require_future_start(
    starts_at: str, time_label: str = "", now: datetime | None = None
) -> None:
    """Reject a proposed start time that has already passed.

    Checks the structured ``starts_at`` first (precise, 5-minute grace). When
    the model left ``starts_at`` empty — as it did on Scout's past-time card
    (NOTE 214 Defect B), which is exactly why the 2438 ``starts_at``-only guard
    never fired — fall back to the human ``time_label``: an explicit past-day
    word ("yesterday", "last Friday") is past in the user's own frame, and any
    other label we can pin to a clock time is refused only when it is past
    beyond the widest timezone offset, so a valid future plan is never blocked.
    """
    moment = now or datetime.now(timezone.utc)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    start = _parse_starts_at(starts_at)
    if start is not None:
        if start < moment - _PAST_START_GRACE:
            raise ValueError(_PAST_TIME_MSG)
        return
    label = (time_label or "").strip()
    if not label:
        return
    if _PAST_DAY_RE.search(label):
        raise ValueError(_PAST_TIME_MSG)
    resolved = _resolve_label_time(label, moment)
    if resolved is not None and resolved < moment - _PAST_START_GRACE - _TZ_SLACK:
        raise ValueError(_PAST_TIME_MSG)


def propose_plan(
    place_name: str,
    address: str = "",
    lat=None,
    lng=None,
    time_label: str = "",
    starts_at: str = "",
    proposer_uid: str = "",
    place_kind: str = "",
    now: datetime | None = None,
) -> dict:
    """Build a fresh proposed plan from the proposer's own place and time.

    The place must be locatable: a non-empty name plus either an address
    or a latitude/longitude pair. Raises ``ValueError`` otherwise. The
    ``place_kind`` (cafe, bar, park, …) is filled by the Places lookup when
    available and is advisory - it never gates the plan. A ``starts_at``
    that has already passed is also rejected (5-minute grace).
    """
    name = (place_name or "").strip()
    if not name:
        raise ValueError("A date plan needs a place name.")
    addr = (address or "").strip()
    latf, lngf = _coord(lat), _coord(lng)
    has_coords = latf is not None and lngf is not None
    if not addr and not has_coords:
        raise ValueError(
            "A date plan needs an address or coordinates so the place is "
            "locatable.")
    _require_future_start(starts_at, time_label, now)
    return {
        "status": STATUS_PROPOSED,
        "proposer_uid": str(proposer_uid or ""),
        "place_name": name,
        "place_kind": str(place_kind or "").strip(),
        "address": addr,
        "lat": latf,
        "lng": lngf,
        "time_label": (time_label or "").strip(),
        "starts_at": (starts_at or "").strip(),
        "approvals": {},
        "revision": 1,
        "suggestions": [],
        # Set True exactly once by date_moments.fire_moment when the step-in
        # posts; never re-posted. The ONLY record the step-in keeps.
        "moment_fired": False,
    }


def card_body(plan: dict) -> str:
    place = str(plan.get("place_name", ""))
    time_label = str(plan.get("time_label", ""))
    if time_label:
        return f"Date plan: {place} - {time_label}."
    return f"Date plan: {place}."


# --- Card message storage -------------------------------------------------

def _thread_ref(db, thread_id: str):
    return db.collection(dm_schema.DM_THREADS_COLLECTION).document(thread_id)


def post_date_plan_message(db, thread_id: str, participants: list[str],
                           plan: dict) -> str:
    """Append the Ayma date card to an existing thread. Returns its id."""
    thread_ref = _thread_ref(db, thread_id)
    msg_ref = thread_ref.collection(dm_schema.DM_MESSAGES_COLLECTION).document()
    doc = {
        "sender_uid": "ayma",
        "type": dm_schema.MESSAGE_DATE_PLAN,
        "body": card_body(plan),
        "created_at": firestore.SERVER_TIMESTAMP,
        "date_plan": plan,
        "participants": list(participants),
    }
    msg_ref.set(doc)
    unread = {uid: firestore.Increment(1) for uid in participants}
    thread_ref.set(
        {"last_message_at": firestore.SERVER_TIMESTAMP, "unread": unread},
        merge=True,
    )
    return msg_ref.id


def load_plan(db, thread_id: str, message_id: str) -> tuple[object, dict]:
    """``(message ref, {plan, participants})`` for a card, or ``ValueError``."""
    ref = (_thread_ref(db, thread_id)
           .collection(dm_schema.DM_MESSAGES_COLLECTION)
           .document(message_id))
    snap = ref.get()
    if not snap.exists:
        raise ValueError("No such date plan card.")
    data = snap.to_dict() or {}
    if data.get("type") != dm_schema.MESSAGE_DATE_PLAN:
        raise ValueError("That message is not a date plan card.")
    plan = dict(data.get("date_plan") or {})
    if not plan:
        raise ValueError("That date plan card has no plan on it.")
    participants = [str(p) for p in (data.get("participants") or [])]
    return ref, {"plan": plan, "participants": participants}


def _save_plan(ref, plan: dict) -> None:
    ref.set({"date_plan": plan, "body": card_body(plan)}, merge=True)


def _participants_or_raise(info: dict, uid: str) -> list[str]:
    parts = info["participants"]
    if uid not in parts or len(parts) != 2:
        raise PermissionError("Not your date plan.")
    return parts


# --- Active-plan index (for the background arrival geofence) ----------------
# A tiny per-user pointer at users/{uid}/active_date_plans/{thread_id} so the
# client's always-on arrival geofence can find a both-approved plan's place
# WITHOUT opening (or scanning) every DM thread. Written for both participants
# when a plan reaches both_approved; cleared when it changes or the step-in
# fires. Holds only what the geofence needs - never a location trail.
ACTIVE_DATE_PLANS = "active_date_plans"


def _active_ref(db, uid: str, thread_id: str):
    return (db.collection("users").document(uid)
            .collection(ACTIVE_DATE_PLANS).document(thread_id))


def write_active_pointers(db, thread_id: str, message_id: str,
                          parts: list[str], plan: dict) -> None:
    """Record the both-approved plan's geofence anchor for each participant."""
    pointer = {
        "thread_id": thread_id,
        "message_id": message_id,
        "place_name": str(plan.get("place_name", "")),
        "place_kind": str(plan.get("place_kind", "") or ""),
        "lat": _coord(plan.get("lat")),
        "lng": _coord(plan.get("lng")),
        "starts_at": str(plan.get("starts_at", "")),
        "revision": int(plan.get("revision", 1)),
    }
    for uid in parts:
        _active_ref(db, uid, thread_id).set(pointer)


def clear_active_pointers(db, thread_id: str, parts: list[str]) -> None:
    """Remove the active-plan pointer for each participant (plan changed,
    fired, or no longer both-approved)."""
    for uid in parts:
        _active_ref(db, uid, thread_id).delete()


# --- State machine ---------------------------------------------------------

def approve(db, thread_id: str, message_id: str, uid: str) -> dict:
    """Record one person approving for themselves. The second approval
    moves the plan to ``both_approved`` - the terminal approved state."""
    ref, info = load_plan(db, thread_id, message_id)
    parts = _participants_or_raise(info, uid)
    plan = info["plan"]
    approvals = dict(plan.get("approvals") or {})
    if approvals.get(uid) and plan.get("status") == STATUS_BOTH_APPROVED:
        return plan
    approvals[uid] = True
    plan["approvals"] = approvals
    approved = [p for p in parts if approvals.get(p)]
    if len(approved) == 2:
        plan["status"] = STATUS_BOTH_APPROVED
    elif len(approved) == 1:
        plan["status"] = STATUS_PARTIALLY_APPROVED
    _save_plan(ref, plan)
    if plan["status"] == STATUS_BOTH_APPROVED:
        # Index the approved plan so each person's background geofence can
        # find its place without opening the thread.
        write_active_pointers(db, thread_id, message_id, parts, plan)
    return plan


def suggest_change(
    db,
    thread_id: str,
    message_id: str,
    uid: str,
    place_name: str | None = None,
    address: str | None = None,
    lat=None,
    lng=None,
    time_label: str | None = None,
    starts_at: str | None = None,
    note: str = "",
    now: datetime | None = None,
) -> dict:
    """A reply-to-card change: revise the plan, bump the revision and
    RESET approvals back to none. Only the fields the suggester supplies
    change; the rest carry over. A plan whose step-in has already fired
    can no longer change."""
    ref, info = load_plan(db, thread_id, message_id)
    parts = _participants_or_raise(info, uid)
    plan = info["plan"]
    if plan.get("moment_fired"):
        raise ValueError("That date has already started.")
    fresh = dict(plan)
    if place_name is not None and place_name.strip():
        fresh["place_name"] = place_name.strip()
    if address is not None:
        fresh["address"] = address.strip()
    if lat is not None or lng is not None:
        fresh["lat"] = _coord(lat) if lat is not None else fresh.get("lat")
        fresh["lng"] = _coord(lng) if lng is not None else fresh.get("lng")
    if time_label is not None:
        fresh["time_label"] = time_label.strip()
    if starts_at is not None:
        fresh["starts_at"] = starts_at.strip()
    # The revision must still be locatable.
    has_coords = fresh.get("lat") is not None and fresh.get("lng") is not None
    if not str(fresh.get("address", "")).strip() and not has_coords:
        raise ValueError(
            "The revised plan still needs an address or coordinates.")
    _require_future_start(
        str(fresh.get("starts_at", "")), str(fresh.get("time_label", "")), now
    )
    fresh["approvals"] = {}
    fresh["status"] = STATUS_PROPOSED
    fresh["revision"] = int(plan.get("revision", 1)) + 1
    history = list(plan.get("suggestions") or [])
    history.append({"from": uid, "note": (note or "").strip()})
    fresh["suggestions"] = history
    _save_plan(ref, fresh)
    # A revised plan is no longer approved: drop it from the arrival index
    # until both approve again.
    clear_active_pointers(db, thread_id, parts)
    return fresh
