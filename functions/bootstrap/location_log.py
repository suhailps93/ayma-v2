"""The opt-in location log + the patterns Ayma learns from it.

OPT-IN, default off. A visit is only ever stored when the user has turned
the log on (``profile/main.location_log_enabled == True``). Granting the OS
location permission is NOT enough — the toggle is the opt-in, and with it off
:func:`log_visit` writes nothing.

Each stored visit is ``users/{uid}/location_log/{entry_id}`` =
``{lat, lng, timestamp, place_name, place_kind}``. The place name + kind come
from :mod:`places_client` (a maps lookup, fail-closed to ``"unknown"`` when
the Places key is absent); the raw coordinates + time are always kept.

The patterns Ayma "learns" are derived from the log DETERMINISTICALLY — pure
place-kind + day/time bucketing, NO model call (same rule as the date-moment
compose). They are derived live on read, so wiping the log (the knowledge
wipe already clears the ``location_log`` subcollection) clears the patterns
too, with nothing separate to delete.
"""

from __future__ import annotations

import logging
from collections import Counter
from datetime import datetime, timezone

from firebase_admin import firestore

import places_client
import schema

logger = logging.getLogger("ayma.location_log")

# A kind must recur at least this many times in a bucket to count as a pattern.
MIN_PATTERN_COUNT = 2
# At most this many patterns surface, strongest first.
MAX_PATTERNS = 6
# Only keep this many most-recent entries when deriving (bounded work).
_DERIVE_LIMIT = 500

_WEEKDAYS = (
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday",
    "Saturday", "Sunday",
)

_TOD_ADJECTIVE = {
    "morning": "morning",
    "afternoon": "afternoon",
    "evening": "evening",
    "late": "late-night",
}

# A place kind rendered as the activity in a named routine. A kind with no
# entry here (e.g. "unknown") never forms a routine. The learned routine name
# is "<time> <activity>" (e.g. "morning walks", "late-night drinks") or
# "<Weekday> <activity>" (e.g. "Sunday hikes").
_KIND_ACTIVITY = {
    "cafe": "coffee",
    "bar": "drinks",
    "restaurant": "dinners",
    "gym": "gym sessions",
    "trailhead": "hikes",
    "park": "walks",
    "beach": "beach time",
    "cinema": "movies",
    "museum": "museum visits",
    "bookstore": "bookshop trips",
    "shopping": "shopping trips",
    "venue": "shows",
    "attraction": "outings",
    "workplace": "work",
}


def _log_ref(db, uid: str):
    return schema.user_doc(db, uid).collection(schema.LOCATION_LOG)


def _profile(db, uid: str) -> dict:
    try:
        snap = db.document(f"users/{uid}/profile/main").get()
    except Exception:  # noqa: BLE001 - a read blip reads as "most restrictive"
        logger.warning("location_log: profile read failed for %s", uid,
                       exc_info=False)
        return {}
    return snap.to_dict() or {}


def master_on(data: dict) -> bool:
    """The master location kill switch. ON (not killed) unless EXPLICITLY set
    false — the switch defaults to "not killed" so a user who never opened the
    screen still sees the per-feature opt-ins (all default off) govern
    collection. Master off halts ALL location use."""
    return data.get("location_master_enabled") is not False


def background_on(data: dict) -> bool:
    """The background/closed-app switch. ON unless explicitly set false; off
    stops background + closed-app checks (foreground-only), master permitting."""
    return data.get("location_background_enabled") is not False


def log_enabled(db, uid: str) -> bool:
    """Whether the location log may store a visit: the master switch is on AND
    the per-feature log opt-in is on. A missing profile / field reads as off, so
    nothing is logged by default (and master-off halts it regardless)."""
    data = _profile(db, uid)
    return master_on(data) and data.get("location_log_enabled") is True


def log_visit(
    db,
    uid: str,
    lat: float,
    lng: float,
    *,
    timestamp: datetime | None = None,
    classifier=places_client.classify_point,
) -> str | None:
    """Store one visit for ``uid`` — ONLY when the log is opted in. Returns the
    entry id, or ``None`` when the log is off (nothing written) or the point is
    unusable. The place kind fails closed to ``"unknown"`` when Places is not
    configured; the coordinates + time are always kept."""
    if not log_enabled(db, uid):
        return None
    try:
        latf, lngf = float(lat), float(lng)
    except (TypeError, ValueError):
        return None
    details = None
    try:
        details = classifier(latf, lngf)
    except Exception:  # noqa: BLE001 - classification is best-effort
        logger.warning("location_log: classify failed", exc_info=False)
        details = None
    details = details or {}
    entry = {
        "lat": latf,
        "lng": lngf,
        "timestamp": timestamp or firestore.SERVER_TIMESTAMP,
        "place_name": str(details.get("place_name") or ""),
        "place_kind": str(details.get("place_kind") or "unknown"),
    }
    ref = _log_ref(db, uid).document()
    ref.set(entry)
    return ref.id


def _parse_ts(value) -> datetime | None:
    if isinstance(value, datetime):
        dt = value
    elif isinstance(value, (int, float)):
        dt = datetime.fromtimestamp(float(value), tz=timezone.utc)
    elif isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        try:
            dt = datetime.fromisoformat(text)
        except ValueError:
            return None
    else:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _tod_bucket(hour: int) -> str:
    if 5 <= hour < 11:
        return "morning"
    if 11 <= hour < 17:
        return "afternoon"
    if 17 <= hour < 21:
        return "evening"
    return "late"


def _tod_routine_name(tod: str, kind: str) -> str:
    activity = _KIND_ACTIVITY[kind]
    if kind == "workplace":
        return "days at work"  # time-of-day prefix reads oddly for work
    return f"{_TOD_ADJECTIVE[tod]} {activity}"


def _weekday_routine_name(weekday: int, kind: str) -> str:
    return f"{_WEEKDAYS[weekday]} {_KIND_ACTIVITY[kind]}"


def derive_patterns(entries, *, min_count: int = MIN_PATTERN_COUNT) -> list[dict]:
    """Deterministic NAMED ROUTINES from log entries (founder 2026-11-12).

    Turns recurring place-kind + time into named routines — a time-of-day
    routine (``"morning walks"``, ``"late-night drinks"``) and a weekday
    routine (``"Sunday hikes"``) — each requiring ``min_count`` recurrences.
    No model call; pure bucketing. Returned strongest-first (count desc, then
    name), deduped by name. The ``label`` is the routine name the Privacy
    "what Ayma has learned" surface shows."""
    weekday_counts: Counter = Counter()
    time_counts: Counter = Counter()
    for entry in entries or []:
        data = entry if isinstance(entry, dict) else {}
        kind = str(data.get("place_kind") or "").strip()
        if kind not in _KIND_ACTIVITY:
            continue
        dt = _parse_ts(data.get("timestamp"))
        if dt is None:
            continue
        weekday_counts[(dt.weekday(), kind)] += 1
        time_counts[(_tod_bucket(dt.hour), kind)] += 1

    patterns: list[dict] = []
    for (weekday, kind), count in weekday_counts.items():
        if count < min_count:
            continue
        patterns.append({
            "label": _weekday_routine_name(weekday, kind),
            "place_kind": kind,
            "count": count,
            "basis": "weekday",
        })
    for (tod, kind), count in time_counts.items():
        if count < min_count:
            continue
        patterns.append({
            "label": _tod_routine_name(tod, kind),
            "place_kind": kind,
            "count": count,
            "basis": "time_of_day",
        })

    by_label: dict[str, dict] = {}
    for pat in patterns:
        existing = by_label.get(pat["label"])
        if existing is None or pat["count"] > existing["count"]:
            by_label[pat["label"]] = pat
    ordered = sorted(
        by_label.values(), key=lambda p: (-p["count"], p["label"])
    )
    return ordered[:MAX_PATTERNS]


def _latest_entry(db, uid: str) -> dict | None:
    """The most recent stored visit (by timestamp), or ``None``. Read-all +
    max-in-Python so no Firestore composite index / order_by is required."""
    try:
        docs = list(_log_ref(db, uid).limit(_DERIVE_LIMIT).stream())
    except Exception:  # noqa: BLE001
        return None
    best, best_ts = None, None
    for doc in docs:
        data = doc.to_dict() or {}
        ts = _parse_ts(data.get("timestamp"))
        if ts is None:
            continue
        if best_ts is None or ts > best_ts:
            best, best_ts = data, ts
    return best


def current_location_context(db, uid: str) -> str:
    """A truthful location line for the brain's system context (founder bug,
    build 2426: Ayma said "no" to "do you have my location?" because the brain
    never received any location).

    Only opted-in users (master on + log on) get a real reading; everyone else
    gets an explicit "you do NOT have their location" so Ayma answers honestly
    and NEVER invents a place. Any model reasoning over this still runs on the
    existing LiveKit-routed brain — this only adds context text."""
    data = _profile(db, uid)
    opted_in = master_on(data) and data.get("location_log_enabled") is True
    if not opted_in:
        return (
            "LOCATION: The user has NOT shared their live location with you "
            "(location sharing is off or not opted in). If they ask whether "
            "you know where they are, say honestly that you don't have their "
            "location — never guess or name a place."
        )
    entry = _latest_entry(db, uid)
    if not entry:
        return (
            "LOCATION: The user shares their location with you, but you have "
            "no reading yet. If they ask, say you don't have a fix right now."
        )
    place = str(entry.get("place_name") or "").strip()
    where = place or (
        f"near {entry.get('lat')}, {entry.get('lng')}"
        if entry.get("lat") is not None else "an unknown place"
    )
    return (
        "LOCATION: The user shares their location with you. Their most recent "
        f"known place is {where}. If they ask whether you have their location "
        "or where they are, answer truthfully from this. Do NOT invent a more "
        "specific place than this."
    )


def patterns_for(db, uid: str) -> list[dict]:
    """The named routines Ayma has learned from ``uid``'s location log, derived
    live. Empty when the master switch is off (derive nothing), the log is off,
    the log is empty, or on any read failure."""
    if not master_on(_profile(db, uid)):
        return []
    try:
        docs = list(_log_ref(db, uid).limit(_DERIVE_LIMIT).stream())
    except Exception:  # noqa: BLE001 - a read blip means no patterns, not a fail
        logger.warning("location_log: patterns read failed for %s", uid,
                       exc_info=False)
        return []
    return derive_patterns([doc.to_dict() or {} for doc in docs])
