"""Plan-a-date in a DM thread (PayPal AI Hackathon build).

Flow, exactly as the founder described it on 2026-11-07:

1. Either person in a human-to-human DM thread sends "@ayma plan a date".
2. Ayma reads the thread (plus whatever taste notes are on file) and
   posts a date card in the thread: a place, a time, what it costs.
3. Each person approves for themselves on the card, or replies with a
   suggested change; a change revises the plan and resets approvals.
4. Once both have approved, Ayma creates two linked PayPal sandbox
   orders - one half of the total for each person - and the booking is
   confirmed only when both halves are paid. Confirming writes a real
   booking record (collection ``date_bookings``) whose confirmation
   number is shown on the card.

Planning here is a deterministic read of the thread words and taste
notes. It deliberately makes NO direct model-provider call: Ayma
inference stays on the existing LiveKit-routed path (founder rule,
2026-11-02), and this feature does not route around it.

Plan state lives on the card message doc itself, in its ``date_plan``
map, so the thread stream the clients already watch carries every
state change:

    proposed -> one person approved -> both approved ->
    paying (halves pending / paid) -> reservation confirmed
"""

from __future__ import annotations

import hashlib
import re
from datetime import datetime, timedelta, timezone

from firebase_admin import firestore

import dm_schema

STATUS_PROPOSED = "proposed"
STATUS_PARTIALLY_APPROVED = "partially_approved"
STATUS_BOTH_APPROVED = "both_approved"
STATUS_PAYING = "paying"
STATUS_CONFIRMED = "confirmed"

_TRIGGER_PHRASES = ("plan a date", "plan our date", "plan the date")

# A small, honest catalogue for the demo world. Each entry: display name,
# kind of place, one-line reason, and the total cost in cents for two.
_CATALOG = [
    {
        "keywords": ("sushi", "japanese", "ramen"),
        "place_name": "Sakura Sushi",
        "place_kind": "Sushi restaurant",
        "reason": "Sushi came up in your conversation.",
        "total_cents": 5600,
    },
    {
        "keywords": ("italian", "pasta", "pizza"),
        "place_name": "Nonna Table",
        "place_kind": "Italian restaurant",
        "reason": "Italian food came up in your conversation.",
        "total_cents": 4800,
    },
    {
        "keywords": ("taco", "mexican", "burrito"),
        "place_name": "Casa Verde",
        "place_kind": "Mexican restaurant",
        "reason": "Mexican food came up in your conversation.",
        "total_cents": 3600,
    },
    {
        "keywords": ("indian", "curry", "spicy"),
        "place_name": "Spice Route",
        "place_kind": "Indian restaurant",
        "reason": "Indian food came up in your conversation.",
        "total_cents": 4400,
    },
    {
        "keywords": ("burger", "bbq", "barbecue"),
        "place_name": "Stack Burger",
        "place_kind": "Burger place",
        "reason": "Burgers came up in your conversation.",
        "total_cents": 3200,
    },
    {
        "keywords": ("coffee", "cafe", "espresso"),
        "place_name": "Blue Door Coffee",
        "place_kind": "Coffee shop",
        "reason": "A coffee date came up in your conversation.",
        "total_cents": 1800,
    },
]
_DEFAULT_PLACE = {
    "place_name": "The Garden Kitchen",
    "place_kind": "Neighbourhood restaurant",
    "reason": "A relaxed place that suits the tastes Ayma has for you both.",
    "total_cents": 4800,
}
_CHEAP_PLACE = {
    "place_name": "Blue Door Coffee",
    "place_kind": "Coffee shop",
    "reason": "A lighter, cheaper plan, as suggested.",
    "total_cents": 1800,
}

_WEEKDAYS = {
    "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
    "friday": 4, "saturday": 5, "sunday": 6,
}
_WEEKDAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday",
                  "Friday", "Saturday", "Sunday"]
_MONTH_NAMES = ["", "January", "February", "March", "April", "May",
                "June", "July", "August", "September", "October",
                "November", "December"]


def is_plan_trigger(text: str) -> bool:
    """True for an @ayma mention carrying a plan-a-date intent."""
    low = (text or "").lower()
    return "@ayma" in low and any(p in low for p in _TRIGGER_PHRASES)


def _parse_time(text: str, now: datetime) -> tuple[str, str]:
    """(label, iso) for the first weekday / time mention, else the
    default: the coming Saturday at 7:00 PM."""
    low = text.lower()
    weekday = None
    for name, num in _WEEKDAYS.items():
        if name in low:
            weekday = num
            break
    hour, minute = 19, 0
    m = re.search(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)", low)
    if m:
        hour = int(m.group(1)) % 12
        if m.group(3) == "pm":
            hour += 12
        minute = int(m.group(2) or 0)
    else:
        m24 = re.search(r"\b([01]?\d|2[0-3]):([0-5]\d)\b", low)
        if m24:
            hour, minute = int(m24.group(1)), int(m24.group(2))
    if weekday is None:
        days_ahead = (5 - now.weekday()) % 7
        if days_ahead == 0:
            days_ahead = 7
    else:
        days_ahead = (weekday - now.weekday()) % 7
        if days_ahead == 0:
            days_ahead = 7
    day = (now + timedelta(days=days_ahead)).replace(
        hour=hour, minute=minute, second=0, microsecond=0)
    hour12 = day.hour % 12 or 12
    ampm = "AM" if day.hour < 12 else "PM"
    label = (f"{_WEEKDAY_NAMES[day.weekday()]} "
             f"{_MONTH_NAMES[day.month]} {day.day} at "
             f"{hour12}:{day.minute:02d} {ampm}")
    return label, day.isoformat()


def propose_plan(thread_texts: list[str], tastes: list[str] | None = None,
                 now: datetime | None = None,
                 suggestion: str = "") -> dict:
    """Build a fresh plan dict from the thread words (+ taste notes).

    With a ``suggestion`` (a reply-to-card change), the suggestion words
    steer the revision: a different food, a different time, or
    "cheaper" for the cheaper place.
    """
    now = now or datetime.now(timezone.utc)
    steering = suggestion.strip()
    combined = " ".join(thread_texts or []).lower()
    steer_low = steering.lower()
    pick = None
    if "cheaper" in steer_low or "less expensive" in steer_low \
            or "budget" in steer_low:
        pick = _CHEAP_PLACE
    if pick is None:
        for entry in _CATALOG:
            if any(k in steer_low for k in entry["keywords"]):
                pick = entry
                break
    if pick is None:
        for entry in _CATALOG:
            if any(k in combined for k in entry["keywords"]):
                pick = entry
                break
        if pick is None:
            taste_blob = " ".join(tastes or []).lower()
            for entry in _CATALOG:
                if any(k in taste_blob for k in entry["keywords"]):
                    pick = entry
                    break
    if pick is None:
        pick = _DEFAULT_PLACE
    time_source = steering if (
        any(d in steer_low for d in _WEEKDAYS)
        or re.search(r"\d\s*(am|pm)", steer_low)) else combined + " " + steering
    label, iso = _parse_time(time_source, now)
    reason = pick["reason"]
    if steering and pick is not _CHEAP_PLACE:
        reason = "Revised after your suggestion."
    total = int(pick["total_cents"])
    return {
        "status": STATUS_PROPOSED,
        "place_name": pick["place_name"],
        "place_kind": pick["place_kind"],
        "reason": reason,
        "time_label": label,
        "starts_at": iso,
        "total_cents": total,
        "half_cents": total // 2,
        "currency": "USD",
        "approvals": {},
        "payments": {},
        "revision": 1,
        "suggestions": [],
        "reservation": {},
        "paypal_stubbed": False,
    }


def card_body(plan: dict) -> str:
    return (f"Date plan: {plan.get('place_name', '')} on "
            f"{plan.get('time_label', '')} - "
            f"${int(plan.get('total_cents', 0)) / 100:.2f} total, "
            "split between you both.")


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
    """(message ref, plan dict) for a card, or raise ValueError."""
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


# --- State machine ---------------------------------------------------------

def approve(db, thread_id: str, message_id: str, uid: str,
            paypal_client) -> dict:
    """Record one person approving. When the second approval lands,
    create the two linked half-amount PayPal sandbox orders."""
    ref, info = load_plan(db, thread_id, message_id)
    parts = _participants_or_raise(info, uid)
    plan = info["plan"]
    if plan.get("status") == STATUS_CONFIRMED:
        return plan
    approvals = dict(plan.get("approvals") or {})
    approvals[uid] = True
    plan["approvals"] = approvals
    approved = [p for p in parts if approvals.get(p)]
    if len(approved) == 2:
        plan["status"] = STATUS_BOTH_APPROVED
        if not plan.get("payments"):
            plan = create_split_orders(plan, parts, paypal_client)
            plan["status"] = STATUS_PAYING
    elif len(approved) == 1:
        plan["status"] = STATUS_PARTIALLY_APPROVED
    _save_plan(ref, plan)
    return plan


def create_split_orders(plan: dict, participants: list[str],
                        paypal_client) -> dict:
    """Two linked half-amount orders, one per person. Returns the plan
    with its ``payments`` map filled in."""
    total = int(plan.get("total_cents", 0))
    first_half = total - total // 2
    payments: dict[str, dict] = {}
    stubbed = False
    for i, uid in enumerate(participants):
        amount = first_half if i == 0 else total // 2
        reference = (f"dateplan-{uid}-{plan.get('revision', 1)}-"
                     f"{abs(hash((uid, total))) % 99999}")
        order = paypal_client.create_order(
            amount_cents=amount,
            currency=str(plan.get("currency", "USD")),
            reference_id=reference,
        )
        stubbed = stubbed or bool(order.get("stubbed"))
        payments[uid] = {
            "order_id": str(order.get("order_id", "")),
            "approve_url": str(order.get("approve_url", "")),
            "amount_cents": amount,
            "status": "pending",
            "capture_id": "",
        }
    plan["payments"] = payments
    plan["paypal_stubbed"] = stubbed
    return plan


def suggest_change(db, thread_id: str, message_id: str, uid: str,
                   text: str, thread_texts: list[str] | None = None,
                   now: datetime | None = None) -> dict:
    """A reply-to-card change: revise the plan, reset approvals and any
    unpaid payment orders. Paid halves are never silently kept against
    a changed plan - a confirmed plan cannot be changed at all."""
    ref, info = load_plan(db, thread_id, message_id)
    _participants_or_raise(info, uid)
    plan = info["plan"]
    if plan.get("status") == STATUS_CONFIRMED:
        raise ValueError("That date is already booked and paid for.")
    payments = dict(plan.get("payments") or {})
    if any(p.get("status") == "paid" for p in payments.values()
           if isinstance(p, dict)):
        raise ValueError(
            "One half is already paid, so the plan can no longer change.")
    fresh = propose_plan(thread_texts or [], suggestion=text, now=now)
    fresh["revision"] = int(plan.get("revision", 1)) + 1
    history = list(plan.get("suggestions") or [])
    history.append({"from": uid, "text": text.strip()})
    fresh["suggestions"] = history
    _save_plan(ref, fresh)
    return fresh


def pay_half(db, thread_id: str, message_id: str, uid: str,
             paypal_client) -> dict:
    """Capture one person half. When both halves are paid, write the
    booking record and mark the card confirmed."""
    ref, info = load_plan(db, thread_id, message_id)
    parts = _participants_or_raise(info, uid)
    plan = info["plan"]
    if plan.get("status") == STATUS_CONFIRMED:
        return plan
    payments = dict(plan.get("payments") or {})
    mine = dict(payments.get(uid) or {})
    if not mine:
        raise ValueError("Both people need to approve before paying.")
    if mine.get("status") != "paid":
        result = paypal_client.capture_order(str(mine.get("order_id", "")))
        mine["status"] = "paid"
        mine["capture_id"] = str(result.get("capture_id", ""))
        payments[uid] = mine
        plan["payments"] = payments
    if all((payments.get(p) or {}).get("status") == "paid" for p in parts):
        confirmation = _confirmation_number(thread_id, message_id, plan)
        reservation = {
            "confirmation_number": confirmation,
            "status": "confirmed",
            "place_name": str(plan.get("place_name", "")),
            "time_label": str(plan.get("time_label", "")),
            "booked_for": parts,
        }
        plan["reservation"] = reservation
        plan["status"] = STATUS_CONFIRMED
        db.collection("date_bookings").document(confirmation).set({
            **reservation,
            "thread_id": thread_id,
            "card_message_id": message_id,
            "total_cents": int(plan.get("total_cents", 0)),
            "currency": str(plan.get("currency", "USD")),
            "payments": payments,
            "created_at": firestore.SERVER_TIMESTAMP,
        })
    else:
        plan["status"] = STATUS_PAYING
    _save_plan(ref, plan)
    return plan


def _confirmation_number(thread_id: str, message_id: str,
                         plan: dict) -> str:
    digest = hashlib.sha256(
        f"{thread_id}:{message_id}:{plan.get('revision', 1)}".encode()
    ).hexdigest()[:8].upper()
    return f"AYMA-{digest}"
