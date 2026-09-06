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
import token_ledger
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


async def parse_nl_query(text: str, *, uid: str | None = None) -> dict:
    """One LLM call → the filter shape. ``{}`` on anything unclear or on error.
    Billed to ``uid`` in the token ledger (``explore`` feature)."""
    text = text.strip()
    if not text:
        return {}
    try:
        result = await gemini.generate_json(
            text,
            system_prompt=_prompt(),
            response_schema=_NL_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_EXPLORE,
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


def _primary_photo_path(db, other: str, photos: list) -> str | None:
    """Storage path of the profile's first photo, or ``None``.

    ``profile.photos`` is ``[{media_id, order}]`` — the real ``storage_path``
    lives on ``users/{other}/user_media/{media_id}``. Older docs inlined
    ``storage_path`` on the entry itself; both shapes are handled. Any lookup
    failure just yields ``None`` — a missing photo never breaks the feed.
    """
    try:
        entries = [p for p in (photos or []) if isinstance(p, dict)]
        if not entries:
            return None
        first = min(entries, key=lambda p: p.get("order", 0))
        if first.get("storage_path"):  # legacy inline shape
            return str(first["storage_path"])
        media_id = str(first.get("media_id") or "").strip()
        if not media_id:
            return None
        media = (
            db.collection("users")
            .document(other)
            .collection("user_media")
            .document(media_id)
            .get()
            .to_dict()
        ) or {}
        return str(media["storage_path"]) if media.get("storage_path") else None
    except Exception:  # noqa: BLE001 - a photo lookup must never 500 Explore
        logger.warning("explore: photo lookup failed for %s", other, exc_info=True)
        return None


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
        try:
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

            cards.append(
                {
                    "uid": other,
                    "name": prof.get("name", ""),
                    "age": _age(prof.get("birthdate")),
                    "location": prof.get("location", ""),
                    "photo_path": _primary_photo_path(
                        db, other, prof.get("photos")
                    ),
                    "score": None
                    if other == uid
                    else _score_for(db, uid, other),
                    "self": other == uid,
                }
            )
        except Exception:  # noqa: BLE001 - one bad profile never sinks the feed
            logger.warning(
                "explore: skipped %s (row build failed)", other, exc_info=True
            )
            continue

    # Your own card pins to the top; then scored matches high-to-low, then the
    # rest.
    cards.sort(
        key=lambda c: (not c["self"], c["score"] is None, -(c["score"] or 0))
    )
    return cards


def merge_filters(query_params: dict, nl_filters: dict) -> dict:
    """Explicit dropdown filters win over the NL parse."""
    merged = {k: v for k, v in (nl_filters or {}).items() if v not in (None, "")}
    merged.update({k: v for k, v in query_params.items() if v not in (None, "")})
    return merged
