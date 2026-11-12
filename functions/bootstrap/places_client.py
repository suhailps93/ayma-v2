"""Google Places lookups for the location-date-moments feature.

Two jobs, both plain maps lookups (NOT model inference, so outside the
LiveKit inference rule — ``AGENTS.md``):

* :func:`resolve_place` turns a user-typed / picked place string into
  ``{place_name, place_kind, lat, lng}`` so a date plan carries real
  coordinates (for the arrival geofence) plus a coarse place kind.
* :func:`classify_point` turns a logged visit's ``(lat, lng)`` into the
  nearest place's ``{place_name, place_kind}`` so the location log and the
  derived patterns can bucket by place kind.

**Fail-closed, no fallback.** The API key is read ONLY from
``CONFIG.places_api_key`` (the ``GOOGLE_PLACES_API_KEY`` secret / env var);
it is never hardcoded, never logged, never printed. When the key is absent,
or any lookup errors, both functions return ``None`` — the feature degrades
to coords-only / "unknown place kind". They never raise to the caller and
never call a different provider.

The HTTP call is injectable (``transport=``) so tests exercise the mapping
and the fail-closed path with no network.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Callable, Optional

from config import CONFIG

logger = logging.getLogger("ayma.places")

_TEXT_SEARCH_URL = "https://places.googleapis.com/v1/places:searchText"
_NEARBY_SEARCH_URL = "https://places.googleapis.com/v1/places:searchNearby"
_FIELD_MASK = (
    "places.displayName,places.location,places.types,places.primaryType"
)
_TIMEOUT_SECONDS = 8
# How close a logged point must be to a place to adopt its kind (metres).
_CLASSIFY_RADIUS_METERS = 80.0

# Coarse, human place kinds the date card and the learned-patterns surface
# use. The first matching Google place type wins, so order is by specificity.
_KIND_BY_TYPE: tuple[tuple[str, str], ...] = (
    ("cafe", "cafe"),
    ("coffee_shop", "cafe"),
    ("bakery", "cafe"),
    ("bar", "bar"),
    ("night_club", "bar"),
    ("pub", "bar"),
    ("wine_bar", "bar"),
    ("restaurant", "restaurant"),
    ("meal_takeaway", "restaurant"),
    ("gym", "gym"),
    ("fitness_center", "gym"),
    ("yoga_studio", "gym"),
    ("hiking_area", "trailhead"),
    ("trail_head", "trailhead"),
    ("park", "park"),
    ("national_park", "park"),
    ("dog_park", "park"),
    ("beach", "beach"),
    ("movie_theater", "cinema"),
    ("museum", "museum"),
    ("art_gallery", "museum"),
    ("tourist_attraction", "attraction"),
    ("book_store", "bookstore"),
    ("library", "bookstore"),
    ("shopping_mall", "shopping"),
    ("store", "shopping"),
    ("stadium", "venue"),
    ("concert_hall", "venue"),
    ("performing_arts_theater", "venue"),
)

# A transport takes (url, payload, api_key) and returns the parsed JSON
# response, or raises on any failure.
Transport = Callable[[str, dict, str], dict]


def _urllib_transport(url: str, payload: dict, api_key: str) -> dict:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "X-Goog-Api-Key": api_key,
            "X-Goog-FieldMask": _FIELD_MASK,
        },
    )
    with urllib.request.urlopen(req, timeout=_TIMEOUT_SECONDS) as resp:
        return json.loads(resp.read())


def place_kind_for_types(types, primary_type: str = "") -> str:
    """The coarse place kind for a Google ``types`` list (+ optional
    ``primaryType``), or ``"unknown"`` when nothing maps. Deterministic."""
    seen = []
    primary = str(primary_type or "").strip()
    if primary:
        seen.append(primary)
    for t in types or []:
        s = str(t or "").strip()
        if s and s not in seen:
            seen.append(s)
    for google_type, kind in _KIND_BY_TYPE:
        if google_type in seen:
            return kind
    return "unknown"


def _api_key() -> str:
    return str(getattr(CONFIG, "places_api_key", "") or "")


def _first_place(data: dict) -> Optional[dict]:
    places = (data or {}).get("places") or []
    return places[0] if places else None


def resolve_place(
    query: str, *, transport: Optional[Transport] = None
) -> Optional[dict]:
    """``{place_name, place_kind, lat, lng}`` for a typed/picked place, or
    ``None`` (fail-closed) when the key is missing or the lookup fails."""
    text = str(query or "").strip()
    if not text:
        return None
    key = _api_key()
    if not key:
        return None
    call = transport or _urllib_transport
    try:
        data = call(_TEXT_SEARCH_URL, {"textQuery": text}, key)
    except (urllib.error.URLError, ValueError, TimeoutError, OSError) as exc:
        logger.warning("places: text search failed (%s)", type(exc).__name__)
        return None
    except Exception:  # noqa: BLE001 - any transport error fails closed
        logger.warning("places: text search errored", exc_info=False)
        return None
    place = _first_place(data)
    if not place:
        return None
    loc = place.get("location") or {}
    lat, lng = loc.get("latitude"), loc.get("longitude")
    if lat is None or lng is None:
        return None
    name = str((place.get("displayName") or {}).get("text") or text).strip()
    return {
        "place_name": name or text,
        "place_kind": place_kind_for_types(
            place.get("types"), place.get("primaryType", "")
        ),
        "lat": float(lat),
        "lng": float(lng),
    }


def classify_point(
    lat: float,
    lng: float,
    *,
    radius: float = _CLASSIFY_RADIUS_METERS,
    transport: Optional[Transport] = None,
) -> Optional[dict]:
    """``{place_name, place_kind}`` for the nearest place to a logged point,
    or ``None`` (fail-closed) when the key is missing or the lookup fails."""
    try:
        latf, lngf = float(lat), float(lng)
    except (TypeError, ValueError):
        return None
    key = _api_key()
    if not key:
        return None
    call = transport or _urllib_transport
    payload = {
        "maxResultCount": 1,
        "rankPreference": "DISTANCE",
        "locationRestriction": {
            "circle": {
                "center": {"latitude": latf, "longitude": lngf},
                "radius": float(radius),
            }
        },
    }
    try:
        data = call(_NEARBY_SEARCH_URL, payload, key)
    except (urllib.error.URLError, ValueError, TimeoutError, OSError) as exc:
        logger.warning("places: nearby search failed (%s)", type(exc).__name__)
        return None
    except Exception:  # noqa: BLE001 - any transport error fails closed
        logger.warning("places: nearby search errored", exc_info=False)
        return None
    place = _first_place(data)
    if not place:
        return None
    name = str((place.get("displayName") or {}).get("text") or "").strip()
    return {
        "place_name": name,
        "place_kind": place_kind_for_types(
            place.get("types"), place.get("primaryType", "")
        ),
    }
