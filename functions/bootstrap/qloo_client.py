"""Qloo Taste API client (Qloo hackathon, Oct 2026).

Two implementations behind one tiny interface — ``search`` (resolve a taste
name to a Qloo entity) and ``insights`` (taste-graph recommendations of one
entity type for a set of signal entities):

* :class:`LiveQlooClient` — the real Qloo Insights API (``X-Api-Key`` header,
  ``GET /search`` + ``GET /v2/insights``), used when ``QLOO_API_KEY`` is set.
* :class:`FixtureQlooClient` — a deterministic mini taste graph bundled in
  ``qloo_fixture.json`` (real, well-known entities scored by shared tags), so the
  demo runs end to end without a key and tests never touch the network.

Both return the same normalised shapes, so ``taste_match`` is identical on
either. Self-contained (stdlib HTTP, no new dependency) so it lifts cleanly into
the public hackathon repo. The key is a secret read from the environment here,
never stored in config or code.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, deque
from pathlib import Path

from config import CONFIG

logger = logging.getLogger("ayma.qloo")

# Taste domain → Qloo entity type URN.
ENTITY_TYPES = {
    "music": "urn:entity:artist",
    "film": "urn:entity:movie",
    "dining": "urn:entity:place",
}

_FIXTURE_PATH = Path(__file__).parent / "qloo_fixture.json"

# The hackathon key allows 10 requests/second; one taste match fires ~25, so
# calls are paced process-wide below that, and a 429 is retried after the
# one-second window resets.
_RATE_PER_SECOND = 8
_RETRIES_ON_429 = 2
_rate_lock = threading.Lock()
_recent_calls: deque[float] = deque()


def _wait_for_slot() -> None:
    """Block until a request fits in the rolling one-second window."""
    while True:
        with _rate_lock:
            now = time.monotonic()
            while _recent_calls and now - _recent_calls[0] >= 1.0:
                _recent_calls.popleft()
            if len(_recent_calls) < _RATE_PER_SECOND:
                _recent_calls.append(now)
                return
            delay = 1.0 - (now - _recent_calls[0])
        time.sleep(delay)


class QlooError(Exception):
    """A live Qloo call failed (transport, auth, or an unexpected payload)."""


def _entity(raw: dict) -> dict:
    """Normalise one Qloo entity: ``{id, name, affinity, tags, address}``."""
    props = raw.get("properties") or {}
    query = raw.get("query") or {}
    tags = [
        str(t.get("name") if isinstance(t, dict) else t)
        for t in (raw.get("tags") or [])
        if t
    ]
    affinity = query.get("affinity", raw.get("affinity", 0.0))
    try:
        affinity = float(affinity)
    except (TypeError, ValueError):
        affinity = 0.0
    return {
        "id": str(raw.get("entity_id") or raw.get("id") or ""),
        "name": str(raw.get("name") or "").strip(),
        "affinity": affinity,
        "tags": [t for t in tags if t and t != "None"],
        "address": (props.get("address") or raw.get("address") or None),
    }


class LiveQlooClient:
    """The real Qloo Insights API."""

    source = "qloo"

    def __init__(self, api_key: str, base_url: str, timeout: float) -> None:
        self._key = api_key
        self._base = base_url.rstrip("/")
        self._timeout = timeout

    def _get(self, path: str, params: dict) -> dict:
        url = f"{self._base}{path}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(
            url, headers={"X-Api-Key": self._key, "Accept": "application/json"}
        )
        for attempt in range(_RETRIES_ON_429 + 1):
            _wait_for_slot()
            try:
                with urllib.request.urlopen(req, timeout=self._timeout) as resp:
                    return json.loads(resp.read().decode("utf-8"))
            except urllib.error.HTTPError as exc:
                if exc.code == 429 and attempt < _RETRIES_ON_429:
                    time.sleep(1.0)
                    continue
                raise QlooError(f"Qloo {path} failed: {exc}") from exc
            except (urllib.error.URLError, TimeoutError, ValueError) as exc:
                raise QlooError(f"Qloo {path} failed: {exc}") from exc
        raise QlooError(f"Qloo {path} failed: rate limited")

    def search(self, name: str, entity_type: str) -> dict | None:
        data = self._get("/search", {"query": name, "types": entity_type, "take": 1})
        results = data.get("results") or []
        if not isinstance(results, list):
            raise QlooError("Qloo /search returned an unexpected payload")
        if not results:
            return None
        hit = _entity(results[0])
        return hit if hit["id"] else None

    def insights(
        self,
        entity_type: str,
        signal_ids: list[str],
        *,
        location: str | None = None,
        take: int = 10,
    ) -> list[dict]:
        params = {
            "filter.type": entity_type,
            "signal.interests.entities": ",".join(signal_ids),
            "take": take,
        }
        if location:
            params["filter.location.query"] = location
        data = self._get("/v2/insights", params)
        entities = (data.get("results") or {}).get("entities")
        if not isinstance(entities, list):
            raise QlooError("Qloo /v2/insights returned an unexpected payload")
        return [e for e in (_entity(r) for r in entities) if e["id"] and e["name"]]


class FixtureQlooClient:
    """Deterministic offline stand-in: a small bundled catalogue of real
    entities, recommendations scored by tag overlap with the signal entities."""

    source = "fixture"

    def __init__(self, path: Path = _FIXTURE_PATH) -> None:
        data = json.loads(path.read_text(encoding="utf-8"))
        self._entities: list[dict] = data["entities"]
        self._by_id = {e["id"]: e for e in self._entities}

    def _out(self, e: dict, affinity: float) -> dict:
        return {
            "id": e["id"],
            "name": e["name"],
            "affinity": round(affinity, 3),
            "tags": list(e.get("tags") or []),
            "address": e.get("address"),
        }

    def search(self, name: str, entity_type: str) -> dict | None:
        want = " ".join(name.lower().split())
        for e in self._entities:
            if e["type"] == entity_type and e["name"].lower() == want:
                return self._out(e, 1.0)
        return None

    def insights(
        self,
        entity_type: str,
        signal_ids: list[str],
        *,
        location: str | None = None,
        take: int = 10,
    ) -> list[dict]:
        bag: Counter = Counter()
        for sid in signal_ids:
            bag.update(self._by_id.get(sid, {}).get("tags") or [])
        loc = (location or "").strip().lower()
        scored = []
        for e in self._entities:
            if e["type"] != entity_type:
                continue
            if loc and str(e.get("city") or "").lower() != loc:
                continue
            raw = sum(bag[t] for t in e.get("tags") or [])
            if raw > 0:
                scored.append((raw, e))
        if not scored:
            return []
        top = max(r for r, _ in scored)
        scored.sort(key=lambda x: (-x[0], x[1]["id"]))
        return [self._out(e, r / top) for r, e in scored[:take]]


def qloo_enabled() -> bool:
    """Kill switch for ALL Qloo API calls — the ``qloo_enabled`` feature flag
    (default True). Flip it OFF at runtime, with NO redeploy, to stop every
    outbound Qloo HTTP call (billing protection once the hackathon credits run
    out)::

        scripts/flags.py set qloo_enabled=false --yes

    When false the taste features degrade to the no-taste empty state
    (:func:`taste_match.match` short-circuits before any Qloo call) and this
    function never hands out a :class:`LiveQlooClient`. See docs/FEATURE_FLAGS.md.
    """
    import feature_flags

    return feature_flags.enabled("qloo_enabled")


def get_client():
    """The live client when ``QLOO_API_KEY`` is set AND ``qloo_enabled`` is on;
    otherwise the offline fixture (which makes no network call). The flag is a
    second guard behind :func:`taste_match.match` so no path can bill Qloo while
    the kill switch is off."""
    key = os.environ.get("QLOO_API_KEY", "").strip()
    if key and qloo_enabled():
        return LiveQlooClient(key, CONFIG.qloo_api_base_url, CONFIG.qloo_timeout_seconds)
    return FixtureQlooClient()
