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

# A place kind rendered as the plural activity/place noun used in a pattern
# label. A kind with no entry here (e.g. "unknown") never forms a pattern.
_KIND_NOUN = {
    "cafe": "cafes",
    "bar": "bars",
    "restaurant": "dinners",
    "gym": "gym sessions",
    "trailhead": "hikes",
    "park": "park visits",
    "beach": "beach trips",
    "cinema": "movies",
    "museum": "museum visits",
    "bookstore": "bookstore visits",
    "shopping": "shopping trips",
    "venue": "shows",
    "attraction": "outings",
}


def _log_ref(db, uid: str):
    return schema.user_doc(db, uid).collection(schema.LOCATION_LOG)


def log_enabled(db, uid: str) -> bool:
    """Whether the user has turned the location log on (the opt-in). A missing
    profile / field reads as off, so nothing is logged by default."""
    try:
        snap = db.document(f"users/{uid}/profile/main").get()
    except Exception:  # noqa: BLE001 - a read blip means "treat as off"
        logger.warning("location_log: enabled read failed for %s", uid,
                       exc_info=False)
        return False
    return bool((snap.to_dict() or {}).get("location_log_enabled") is True)


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


def _weekpart(weekday: int, tod: str) -> str:
    if weekday in (5, 6):
        return "weekend"
    return "weeknight" if tod in ("evening", "late") else "weekday"


def derive_patterns(entries, *, min_count: int = MIN_PATTERN_COUNT) -> list[dict]:
    """Deterministic place-kind + day/time patterns from log entries.

    Produces two kinds of pattern, both requiring ``min_count`` recurrences:
    a weekday pattern (``"Sunday hikes"``) and a time-of-week pattern
    (``"late-weeknight bars"``). No model call; pure bucketing. Patterns are
    deduped by label and returned strongest-first (count desc, then label)."""
    weekday_counts: Counter = Counter()
    time_counts: Counter = Counter()
    for entry in entries or []:
        data = entry if isinstance(entry, dict) else {}
        kind = str(data.get("place_kind") or "").strip()
        noun = _KIND_NOUN.get(kind)
        if not noun:
            continue
        dt = _parse_ts(data.get("timestamp"))
        if dt is None:
            continue
        weekday = dt.weekday()
        tod = _tod_bucket(dt.hour)
        weekday_counts[(weekday, kind)] += 1
        time_counts[(tod, _weekpart(weekday, tod), kind)] += 1

    patterns: list[dict] = []
    for (weekday, kind), count in weekday_counts.items():
        if count < min_count:
            continue
        patterns.append({
            "label": f"{_WEEKDAYS[weekday]} {_KIND_NOUN[kind]}",
            "place_kind": kind,
            "count": count,
            "basis": "weekday",
        })
    for (tod, weekpart, kind), count in time_counts.items():
        if count < min_count:
            continue
        patterns.append({
            "label": f"{tod}-{weekpart} {_KIND_NOUN[kind]}",
            "place_kind": kind,
            "count": count,
            "basis": "time_of_week",
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


def patterns_for(db, uid: str) -> list[dict]:
    """The patterns Ayma has learned from ``uid``'s location log, derived live.
    Empty when the log is off, empty, or on any read failure."""
    try:
        docs = list(_log_ref(db, uid).limit(_DERIVE_LIMIT).stream())
    except Exception:  # noqa: BLE001 - a read blip means no patterns, not a fail
        logger.warning("location_log: patterns read failed for %s", uid,
                       exc_info=False)
        return []
    return derive_patterns([doc.to_dict() or {} for doc in docs])
