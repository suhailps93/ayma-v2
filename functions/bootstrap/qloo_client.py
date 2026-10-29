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

# Taste domain → Qloo entity type URN. The first three are the original demo
# domains; the rest are recognised ADDITIVELY when a Taste page lists them
# (TV/Books/Podcasts/Games) and are simply absent otherwise — a music/film/food
# page behaves exactly as before. All seven resolve against the live Qloo graph.
ENTITY_TYPES = {
    "music": "urn:entity:artist",
    "film": "urn:entity:movie",
    "dining": "urn:entity:place",
    "tv": "urn:entity:tv_show",
    "books": "urn:entity:book",
    "podcasts": "urn:entity:podcast",
    "games": "urn:entity:videogame",
    "travel": "urn:entity:destination",
    "brands": "urn:entity:brand",
    # Nightlife is a place scene — same entity type as dining, narrowed to
    # nightlife venues by a tag filter in ``taste_match`` (``_DOMAIN_FILTER_TAGS``).
    "nightlife": "urn:entity:place",
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
    """Normalise one Qloo entity: ``{id, name, affinity, tags, tag_ids, address}``.

    ``tags`` are human labels (unchanged); ``tag_ids`` are the parallel Qloo tag
    URNs (``urn:tag:…``), kept so the engine can tag-align a follow-up query via
    ``filter.tags`` (which rejects freeform strings — only tag URNs)."""
    props = raw.get("properties") or {}
    query = raw.get("query") or {}
    # ``tags`` (names) and ``tag_ids`` (URNs) are kept index-aligned: one entry
    # per tag that has a usable name, ``tag_ids[i]`` being that tag's URN or ""
    # when absent — so callers can pair a label with its subtype.
    tags: list[str] = []
    tag_ids: list[str] = []
    for t in raw.get("tags") or []:
        if not t:
            continue
        if isinstance(t, dict):
            name = str(t.get("name") or "").strip()
            tid = str(t.get("tag_id") or t.get("id") or "").strip()
        else:
            name, tid = str(t).strip(), ""
        if name and name != "None":
            tags.append(name)
            tag_ids.append(tid)
    affinity = query.get("affinity", raw.get("affinity", 0.0))
    try:
        affinity = float(affinity)
    except (TypeError, ValueError):
        affinity = 0.0
    return {
        "id": str(raw.get("entity_id") or raw.get("id") or ""),
        "name": str(raw.get("name") or "").strip(),
        "affinity": affinity,
        "tags": tags,
        "tag_ids": tag_ids,
        "address": (props.get("address") or raw.get("address") or None),
    }


def _average_demographics(rows: list[dict]) -> dict:
    """Mean of Qloo's per-entity age/gender skews into one profile read.

    ``rows`` is ``results.demographics`` — one ``{entity_id, query:{age,gender}}``
    per anchor entity. Returns ``{"age": {bucket: skew}, "gender": {...}}`` with
    each value averaged across entities, or ``{}`` when nothing usable is
    present (so callers degrade gracefully)."""
    age_sums: dict[str, float] = {}
    gender_sums: dict[str, float] = {}
    age_n = 0
    gender_n = 0
    for row in rows:
        q = row.get("query") or {}
        age = q.get("age") or {}
        gender = q.get("gender") or {}
        if isinstance(age, dict) and age:
            age_n += 1
            for bucket, val in age.items():
                try:
                    age_sums[bucket] = age_sums.get(bucket, 0.0) + float(val)
                except (TypeError, ValueError):
                    continue
        if isinstance(gender, dict) and gender:
            gender_n += 1
            for key, val in gender.items():
                try:
                    gender_sums[key] = gender_sums.get(key, 0.0) + float(val)
                except (TypeError, ValueError):
                    continue
    out: dict = {}
    if age_n:
        out["age"] = {k: round(v / age_n, 4) for k, v in age_sums.items()}
    if gender_n:
        out["gender"] = {k: round(v / gender_n, 4) for k, v in gender_sums.items()}
    return out


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
        filter_tags: list[str] | None = None,
        take: int = 10,
    ) -> list[dict]:
        params = {
            "filter.type": entity_type,
            "signal.interests.entities": ",".join(signal_ids),
            "take": take,
        }
        if location:
            params["filter.location.query"] = location
        if filter_tags:
            params["filter.tags"] = ",".join(filter_tags)
        data = self._get("/v2/insights", params)
        entities = (data.get("results") or {}).get("entities")
        if not isinstance(entities, list):
            raise QlooError("Qloo /v2/insights returned an unexpected payload")
        return [e for e in (_entity(r) for r in entities) if e["id"] and e["name"]]

    def tags(self, signal_ids: list[str], *, take: int = 20) -> list[dict]:
        """Qloo's affinity-ranked TAGS for a taste profile
        (``/v2/insights filter.type=urn:tag``) — the dominant descriptors Qloo
        infers across all of someone's taste, not just the literal tags on their
        few seed entities. Returns ``[{id, name, affinity}]`` ranked high→low."""
        if not signal_ids:
            return []
        data = self._get(
            "/v2/insights",
            {
                "filter.type": "urn:tag",
                "signal.interests.entities": ",".join(signal_ids),
                "take": take,
            },
        )
        rows = (data.get("results") or {}).get("tags")
        if not isinstance(rows, list):
            raise QlooError("Qloo /v2/insights (tags) returned an unexpected payload")
        out: list[dict] = []
        for r in rows:
            tid = str(r.get("tag_id") or r.get("id") or "").strip()
            name = str(r.get("name") or "").strip()
            if not tid or not name:
                continue
            aff = (r.get("query") or {}).get("affinity", r.get("popularity", 0.0))
            try:
                aff = float(aff)
            except (TypeError, ValueError):
                aff = 0.0
            out.append({"id": tid, "name": name, "affinity": aff})
        return out

    def demographics(self, signal_ids: list[str]) -> dict:
        """Audience skew for a taste profile
        (``/v2/insights filter.type=urn:demographics``). Qloo returns a signed
        over/under-index per anchor entity across six age buckets and two gender
        keys; this averages them into one ``{age:{bucket:skew}, gender:{…}}``
        read for the whole profile. ``{}`` when Qloo returns no demographics."""
        if not signal_ids:
            return {}
        data = self._get(
            "/v2/insights",
            {
                "filter.type": "urn:demographics",
                "signal.interests.entities": ",".join(signal_ids),
            },
        )
        rows = (data.get("results") or {}).get("demographics")
        if not isinstance(rows, list):
            raise QlooError(
                "Qloo /v2/insights (demographics) returned an unexpected payload"
            )
        return _average_demographics(rows)


class FixtureQlooClient:
    """Deterministic offline stand-in: a small bundled catalogue of real
    entities, recommendations scored by tag overlap with the signal entities."""

    source = "fixture"

    def __init__(self, path: Path = _FIXTURE_PATH) -> None:
        data = json.loads(path.read_text(encoding="utf-8"))
        self._entities: list[dict] = data["entities"]
        self._by_id = {e["id"]: e for e in self._entities}

    def _out(self, e: dict, affinity: float) -> dict:
        tags = list(e.get("tags") or [])
        return {
            "id": e["id"],
            "name": e["name"],
            "affinity": round(affinity, 3),
            "tags": tags,
            # The fixture has no real Qloo tag URNs; mint stable local ids so
            # tag-overlap still works offline (filter.tags is a no-op here).
            "tag_ids": list(e.get("tag_ids") or [f"fx:tag:{t}" for t in tags]),
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
        filter_tags: list[str] | None = None,
        take: int = 10,
    ) -> list[dict]:
        bag: Counter = Counter()
        for sid in signal_ids:
            bag.update(self._by_id.get(sid, {}).get("tags") or [])
        loc = (location or "").strip().lower()
        # filter.tags is live-only; offline we honour it softly (prefer matches,
        # never empty the list) by mapping any tag id — our local ``fx:tag:NAME``
        # or a real Qloo ``urn:tag:…:NAME`` — to its trailing name segment.
        want_tags = {t.rsplit(":", 1)[-1] for t in (filter_tags or [])}
        scored = []
        for e in self._entities:
            if e["type"] != entity_type:
                continue
            if loc and str(e.get("city") or "").lower() != loc:
                continue
            etags = e.get("tags") or []
            if want_tags and not want_tags.intersection(etags):
                continue
            raw = sum(bag[t] for t in etags)
            if raw > 0:
                scored.append((raw, e))
        if not scored and want_tags:
            return self.insights(entity_type, signal_ids, location=location, take=take)
        if not scored:
            return []
        top = max(r for r, _ in scored)
        scored.sort(key=lambda x: (-x[0], x[1]["id"]))
        return [self._out(e, r / top) for r, e in scored[:take]]

    def tags(self, signal_ids: list[str], *, take: int = 20) -> list[dict]:
        """Offline stand-in for ``/v2/insights filter.type=urn:tag``: the signal
        entities' own tags, frequency-ranked, in the live ``[{id, name,
        affinity}]`` shape (affinity normalised to the most common tag)."""
        bag: Counter = Counter()
        for sid in signal_ids:
            bag.update(self._by_id.get(sid, {}).get("tags") or [])
        if not bag:
            return []
        top = max(bag.values())
        return [
            {"id": f"fx:tag:{name}", "name": name, "affinity": round(n / top, 3)}
            for name, n in bag.most_common(take)
        ]

    def demographics(self, signal_ids: list[str]) -> dict:
        """The fixture carries no demographic data (tags are illustrative, not
        Qloo data), so this degrades to ``{}`` — the taste match simply omits the
        demographics block offline and shows it from the live API when deployed."""
        return {}


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
