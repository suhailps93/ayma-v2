"""Taste-graph client — OFFLINE FIXTURE ONLY (Qloo integration removed).

Founder order, Nov 6, 2026: the Qloo API integration is taken out
completely. The live Qloo client that used to live here (``X-Api-Key``
header, ``GET /search`` + ``GET /v2/insights`` against
``hackathon.api.qloo.com``) is DELETED — this module contains no HTTP
code, reads no API key, and can make no network call of any kind, so no
Qloo charge is possible from this codebase. What remains is the
deterministic offline fixture (``qloo_fixture.json``: real, well-known
entities scored by shared tags), kept so the taste-match engine and its
tests still run end to end with zero external calls.
"""

from __future__ import annotations

import json
import logging
from collections import Counter
from pathlib import Path

logger = logging.getLogger("ayma.qloo")


# Taste domain → Qloo entity type URN. The first three are the original demo
# domains; the rest are recognised ADDITIVELY when a Taste page lists them
# (TV/Books/Podcasts/Games) and are simply absent otherwise — a music/film/food
# page behaves exactly as before.
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

class QlooError(Exception):
    """A live Qloo call failed (transport, auth, or an unexpected payload)."""


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
        demographics block."""
        return {}


def qloo_enabled() -> bool:
    """The ``qloo_enabled`` feature flag (default OFF since the Qloo
    removal, Nov 6, 2026). When false, :func:`taste_match.match`
    short-circuits before any taste work and the taste features degrade
    to the no-taste empty state. Flip with::

        scripts/flags.py set qloo_enabled=false --yes

    See docs/FEATURE_FLAGS.md.
    """
    import feature_flags

    return feature_flags.enabled("qloo_enabled")


def get_client():
    """Always the offline fixture client. There is no live Qloo client
    anymore (removed Nov 6, 2026): no API key is read and no network
    call can be made from this module, whatever the environment holds."""
    return FixtureQlooClient()
