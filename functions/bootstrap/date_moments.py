"""The date step-in ("date moments").

When an opted-in user ARRIVES at an approved date's place near its time,
Ayma posts ONE message in that DM thread, private to the arriving user:

1. the plan recap (place + time),
2. the other person's sim summary the user ALREADY HAS, and
3. one simple suggested opener.

It fires EXACTLY ONCE per plan (``moment_fired`` on the plan doc), never
for a plan that is not ``both_approved``, and never outside a time window
around the plan time. Arrival (device within a small radius of the place)
is decided client-side; the server enforces the plan state, the time
window and the once-only guard.

No new inference path: the sim summary is the user's existing latest
date-sim verdict for that pair (:mod:`date_sim`), and the opener is a
plain template. Ayma inference stays on the existing LiveKit-routed path.
No location trail is stored - the ONLY record is ``moment_fired``.
"""

from __future__ import annotations

import logging
import math
from datetime import datetime, timezone

from firebase_admin import firestore

import date_plan
import dm_schema

logger = logging.getLogger("ayma.date_moments")

# Pragmatic v1 geofence: the client fires when the device is within this
# radius of the place, and only within this many minutes of the plan time.
ARRIVAL_RADIUS_METERS = 150.0
TIME_WINDOW_MINUTES = 90


def haversine_meters(lat1: float, lng1: float,
                     lat2: float, lng2: float) -> float:
    """Great-circle distance between two lat/lng points, in metres."""
    radius = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlmb = math.radians(lng2 - lng1)
    a = (math.sin(dphi / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2)
    return 2 * radius * math.asin(min(1.0, math.sqrt(a)))


def _parse_iso(value) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def within_time_window(plan: dict, now: datetime | None = None,
                       minutes: int = TIME_WINDOW_MINUTES) -> bool:
    """True when ``now`` is within ``minutes`` either side of the plan time."""
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    dt = _parse_iso(plan.get("starts_at"))
    if dt is None:
        return False
    return abs((now - dt).total_seconds()) <= minutes * 60


def at_place(plan: dict, lat: float, lng: float,
             radius: float = ARRIVAL_RADIUS_METERS) -> bool:
    """True when (``lat``, ``lng``) is within ``radius`` of the plan's
    anchor. Only usable when the plan carries coordinates."""
    plat, plng = date_plan._coord(plan.get("lat")), date_plan._coord(
        plan.get("lng"))
    if plat is None or plng is None:
        return False
    return haversine_meters(lat, lng, plat, plng) <= radius


def latest_sim_summary(db, uid: str, other_uid: str) -> str:
    """The user's most recent finished date-sim summary for this pair, or
    ``""``. A best-effort read of data the user already has - never a new
    simulation and never a model call."""
    try:
        docs = (
            db.collection("users").document(uid)
            .collection("date_sims")
            .where("other_uid", "==", other_uid)
            .stream()
        )
    except Exception:  # noqa: BLE001 - a read blip means no summary, not a fail
        logger.warning("date moment: sim read failed for %s", uid,
                       exc_info=True)
        return ""
    best_summary = ""
    best_at = None
    for doc in docs:
        data = doc.to_dict() or {}
        if data.get("status") != "done":
            continue
        summary = str((data.get("verdict") or {}).get("summary") or "").strip()
        if not summary:
            continue
        completed = data.get("completed_at")
        if best_at is None or (completed is not None and completed > best_at):
            best_summary, best_at = summary, completed
    return best_summary


def _opener(other_name: str, place: str) -> str:
    who = other_name or "them"
    if place:
        return (f"Hey {who}, I've been looking forward to {place} - "
                "how's your day been?")
    return f"Hey {who}, so good to finally do this - how's your day been?"


def compose_moment_message(plan: dict, other_name: str,
                           sim_summary: str) -> str:
    """The single step-in message: recap, the summary the user has, opener."""
    place = str(plan.get("place_name", ""))
    time_label = str(plan.get("time_label", ""))
    who = other_name or "your date"
    lines = [f"You made it. This is your date with {who}."]
    recap = f"The plan: {place}" if place else "The plan"
    if time_label:
        recap += f" - {time_label}"
    lines.append(recap + ".")
    if sim_summary:
        lines.append(f"From your date simulation: {sim_summary}")
    lines.append(f'An easy opener: "{_opener(who, place)}"')
    return "\n".join(lines)


def fire_moment(db, thread_id: str, message_id: str, uid: str,
                other_name: str = "", now: datetime | None = None) -> dict | None:
    """Post the step-in message for the arriving user, exactly once.

    Returns the posted message id + body, or ``None`` when the step-in
    does not fire (plan not both-approved, already fired, or out of the
    time window). Raises ``PermissionError`` for a non-participant.
    """
    ref, info = date_plan.load_plan(db, thread_id, message_id)
    parts = date_plan._participants_or_raise(info, uid)
    plan = info["plan"]
    if plan.get("status") != date_plan.STATUS_BOTH_APPROVED:
        return None
    if plan.get("moment_fired"):
        return None
    if not within_time_window(plan, now):
        return None
    other = next((p for p in parts if p != uid), "")
    # Mark fired FIRST so a retry (or a second device) never double-posts;
    # the recap itself is best-effort after that point.
    plan["moment_fired"] = True
    date_plan._save_plan(ref, plan)
    summary = latest_sim_summary(db, uid, other)
    body = compose_moment_message(plan, other_name, summary)
    thread_ref = db.collection(
        dm_schema.DM_THREADS_COLLECTION).document(thread_id)
    msg_ref = thread_ref.collection(
        dm_schema.DM_MESSAGES_COLLECTION).document()
    msg_ref.set({
        "sender_uid": "ayma",
        "type": dm_schema.MESSAGE_TEXT,
        "body": body,
        "created_at": firestore.SERVER_TIMESTAMP,
        # Private to the arriving user: the summary and opener are their own
        # prep, so the other person never sees this message (clients hide a
        # message whose private_to is set and is not the viewer).
        "private_to": uid,
        "date_moment_for": message_id,
    })
    return {"message_id": msg_ref.id, "body": body}
