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


def propose_plan(
    place_name: str,
    address: str = "",
    lat=None,
    lng=None,
    time_label: str = "",
    starts_at: str = "",
    proposer_uid: str = "",
    place_kind: str = "",
) -> dict:
    """Build a fresh proposed plan from the proposer's own place and time.

    The place must be locatable: a non-empty name plus either an address
    or a latitude/longitude pair. Raises ``ValueError`` otherwise. The
    ``place_kind`` (cafe, bar, park, …) is filled by the Places lookup when
    available and is advisory - it never gates the plan.
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
