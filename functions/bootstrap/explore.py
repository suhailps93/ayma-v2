"""Explore feed (ARCHITECTURE.md §6.1, §6.2, §6.11 steps 4–5).

A live query over every user who has a ``profile/main`` — the caller included,
with no orientation or community gating (product decision, 2026-08-30). Blocks,
paused profiles and already-passed users are removed; deleted accounts have no
profile doc. Dropdown filters and a once-per-search NL-parsed filter are applied
over the same structured shape; ``matches`` / ``match_candidates`` overlay a
score when present.
"""

from __future__ import annotations

import json
import logging
from functools import lru_cache
from pathlib import Path

import gemini
from matching import _age
from matching_schema import block_id
from pair_key import sorted_pair_key

logger = logging.getLogger("ayma.explore")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "explore_nl_filter.md"

_NL_SCHEMA = {
    "type": "object",
    "properties": {
        "location": {"type": "string"},
        "age_min": {"type": "integer"},
        "age_max": {"type": "integer"},
        "hair_color": {"type": "string"},
        "eye_color": {"type": "string"},
        "age_range_apparent": {"type": "string"},
        "facial_hair": {"type": "string"},
        "glasses": {"type": "string"},
        "visible_tattoos": {"type": "string"},
        "visible_piercings": {"type": "string"},
    },
}

_PHOTO_FIELDS = (
    "hair_color",
    "eye_color",
    "age_range_apparent",
    "facial_hair",
    "glasses",
    "visible_tattoos",
    "visible_piercings",
)


@lru_cache(maxsize=1)
def _prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


async def parse_nl_query(text: str) -> dict:
    """One LLM call → the filter shape. ``{}`` on anything unclear or on error."""
    text = text.strip()
    if not text:
        return {}
    try:
        result = await gemini.generate_json(
            text, system_prompt=_prompt(), response_schema=_NL_SCHEMA
        )
    except Exception:  # noqa: BLE001
        logger.exception("NL filter parse failed")
        return {}
    return result if isinstance(result, dict) else {}


def _passes_filters(profile: dict, filters: dict) -> bool:
    age = _age(profile.get("birthdate"))
    if filters.get("age_min") is not None and (
        age is None or age < int(filters["age_min"])
    ):
        return False
    if filters.get("age_max") is not None and (
        age is None or age > int(filters["age_max"])
    ):
        return False
    if filters.get("location"):
        loc = (profile.get("location") or "").lower()
        if filters["location"].lower() not in loc:
            return False

    attrs = profile.get("photo_attrs") or {}
    for field in _PHOTO_FIELDS:
        want = filters.get(field)
        if want and str(attrs.get(field, "")).lower() != str(want).lower():
            return False
    return True


def _score_for(db, uid: str, other: str):
    match = (
        db.collection("matches")
        .document(sorted_pair_key(uid, other))
        .get()
    )
    if match.exists:
        return (match.to_dict() or {}).get("score")
    cand = (
        db.collection("users")
        .document(uid)
        .collection("match_candidates")
        .document(other)
        .get()
    )
    if cand.exists:
        return (cand.to_dict() or {}).get("heuristic_score")
    return None


def _blocked(db, uid: str, other: str) -> bool:
    blocks = db.collection("blocks")
    return (
        blocks.document(block_id(uid, other)).get().exists
        or blocks.document(block_id(other, uid)).get().exists
    )


def explore(db, uid: str, filters: dict, limit: int = 30) -> list[dict]:
    me = (
        db.collection("users")
        .document(uid)
        .collection("profile")
        .document("main")
        .get()
        .to_dict()
    )
    if not me:
        return []
    passed = {
        s.id
        for s in db.collection("users")
        .document(uid)
        .collection("explore_passed")
        .stream()
    }

    cards: list[dict] = []
    for user_snap in db.collection("users").stream():
        other = user_snap.id
        # Explore lists everyone with a profile, the caller included — no
        # orientation or community gating (product decision, 2026-08-30). Only
        # blocks / paused / already-passed and the active search filters cut
        # the roster down.
        if other in passed or len(cards) >= limit:
            continue
        prof = (
            db.collection("users")
            .document(other)
            .collection("profile")
            .document("main")
            .get()
            .to_dict()
        )
        if not prof:
            continue
        if prof.get("paused") is True:  # "Pause matching" (§14.2)
            continue
        if other != uid and _blocked(db, uid, other):
            continue
        if not _passes_filters(prof, filters):
            continue

        photos = prof.get("photos") or []
        cards.append(
            {
                "uid": other,
                "name": prof.get("name", ""),
                "age": _age(prof.get("birthdate")),
                "location": prof.get("location", ""),
                "photo_path": photos[0]["storage_path"] if photos else None,
                "score": None if other == uid else _score_for(db, uid, other),
                "self": other == uid,
            }
        )

    cards.sort(key=lambda c: (c["score"] is None, -(c["score"] or 0)))
    return cards


def merge_filters(query_params: dict, nl_filters: dict) -> dict:
    """Explicit dropdown filters win over the NL parse."""
    merged = {k: v for k, v in (nl_filters or {}).items() if v not in (None, "")}
    merged.update({k: v for k, v in query_params.items() if v not in (None, "")})
    return merged
