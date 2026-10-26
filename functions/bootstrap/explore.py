"""Explore feed (ARCHITECTURE.md §6.1, §6.2, §6.11 steps 4–5).

A live query over every user who has a ``profile/main`` — the caller included,
with no orientation or community gating (product decision, 2026-08-30). Blocks,
paused profiles and already-passed users are removed; deleted accounts have no
profile doc. Dropdown filters and a once-per-search NL-parsed filter are applied
over the same structured shape; ``matches`` / ``match_candidates`` overlay a
score when present.

A filter on a ``physical_attrs``-mirror field (see :func:`_passes_filters`)
only ever matches against a candidate's PUBLIC attributes —
``physical_attributes.public_fields(db, other)`` — never a field they've kept
private (§ founder 2026-09-21: repurposing the per-field visibility flag that
used to gate the since-removed ``story_public`` Attributes section: "Use it
for the heuristic search tho"). A private field is dropped before any filter
reads it, so it's treated EXACTLY like a missing/unknown one — which, per
field, already means one of two things here: never excludes (the
``_PHYSICAL_ENUM_FIELDS`` group, plus race/height/weight), or excludes the
same as a genuine mismatch would (the ``_PHOTO_FIELDS`` group, which has no
"unknown never excludes" guard even today). Either way, a private value
never gets to act as if it were public.
"""

from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path

import gemini
import physical_attributes
import token_ledger
from matching import _age
from matching_schema import block_id
from pair_key import sorted_pair_key

logger = logging.getLogger("ayma.explore")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "explore_nl_filter.md"

_NL_SCHEMA = {
    "type": "object",
    "properties": {
        "gender": {"type": "string"},
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
        # physical-attributes filters (§ physical attributes) — matched against
        # the flat profile.physical_attrs mirror.
        "race_ethnicity": {"type": "string"},
        "skin_tone": {"type": "string"},
        "hair_length": {"type": "string"},
        "hair_type": {"type": "string"},
        "build": {"type": "string"},
        "height_min_cm": {"type": "integer"},
        "height_max_cm": {"type": "integer"},
        "weight_min_kg": {"type": "integer"},
        "weight_max_kg": {"type": "integer"},
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

# Enum fields that live only on the physical-attributes mirror. Missing /
# "unknown" never excludes — only an explicit mismatch does.
_PHYSICAL_ENUM_FIELDS = (
    "skin_tone",
    "hair_length",
    "hair_type",
    "build",
)

# Every filter key `_passes_filters` can satisfy off the `physical_attrs`
# mirror (`physical_attributes.flat_mirror`) — the fallback half of
# `_PHOTO_FIELDS`, all of `_PHYSICAL_ENUM_FIELDS`, plus race/height/weight.
# Used only to skip the extra `physical_attributes.public_fields` read in
# `explore()` when a search has none of these active (the common case).
_PHYSICAL_MIRROR_FILTER_KEYS = frozenset(
    _PHOTO_FIELDS
    + _PHYSICAL_ENUM_FIELDS
    + (
        "race_ethnicity",
        "height_min_cm",
        "height_max_cm",
        "weight_min_kg",
        "weight_max_kg",
    )
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


_GENDER_ALIASES = {
    "woman": "woman", "women": "woman", "female": "woman", "f": "woman",
    "man": "man", "men": "man", "male": "man", "m": "man", "guy": "man",
    "guys": "man",
    "non-binary": "non-binary", "nonbinary": "non-binary", "nb": "non-binary",
    "enby": "non-binary",
}


def _passes_filters(
    profile: dict, filters: dict, *, public_fields: set[str] | None = None
) -> bool:
    """``True`` when ``profile`` (a candidate being considered for someone
    else's Explore search) satisfies every set ``filters`` key.

    ``public_fields`` — the subset of ``physical_attributes.fields()`` this
    candidate has made public (``physical_attributes.public_fields(db,
    other)``; see :func:`explore`'s call site). When given, a private field
    is dropped from ``physical_attrs`` before any filter below ever reads
    it — so it's treated exactly as an unset/unknown value already is on
    that same field (never excludes, for the ``_PHYSICAL_ENUM_FIELDS``
    group plus race/height/weight; excludes the same as a real mismatch,
    for the ``_PHOTO_FIELDS`` group, which forgives no missing value even
    today) — never something more lenient invented for privacy specifically.
    Either way, a search can't use a physical attribute the candidate chose
    to keep off their public Story to find OR rule them out (§ founder
    2026-09-21: repurposing the per-field visibility flag that used to only
    gate the Story-public Living Report's since-removed Attributes section
    — "Use it for the heuristic search tho"). ``None`` (the default) applies
    no such restriction — every direct unit test of this function short of
    :func:`explore` itself calls it this way."""
    want_g = str(filters.get("gender") or "").strip().lower()
    if want_g:
        norm = _GENDER_ALIASES.get(want_g, want_g)
        if str(profile.get("gender") or "").strip().lower() != norm:
            return False

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
    phys = profile.get("physical_attrs") or {}
    if public_fields is not None:
        phys = {f: v for f, v in phys.items() if f in public_fields}
    for field in _PHOTO_FIELDS:
        want = filters.get(field)
        if not want:
            continue
        # Prefer the per-upload photo_attrs read (existing behaviour); fall back
        # to the physical-attributes mirror only when photo_attrs has no value.
        have = attrs.get(field)
        if have is None:
            have = phys.get(field)
        if str(have or "").lower() != str(want).lower():
            return False

    # Physical-attributes-only enum fields: an unknown / missing value on the
    # profile does NOT exclude — only an explicit, concrete mismatch does.
    for field in _PHYSICAL_ENUM_FIELDS:
        want = str(filters.get(field) or "").strip().lower()
        if not want:
            continue
        have = str(phys.get(field) or "").strip().lower()
        if have and have != "unknown" and have != want:
            return False

    # race_ethnicity: coarse free text, substring match, unknown never excludes.
    want_re = str(filters.get("race_ethnicity") or "").strip().lower()
    if want_re:
        have_re = str(phys.get("race_ethnicity") or "").strip().lower()
        if have_re and have_re != "unknown" and want_re not in have_re:
            return False

    # Rough height / weight ranges from the physical-attributes mirror. A
    # missing estimate never excludes (photos rarely give a scale cue).
    if not _in_range(
        phys.get("height_estimate_cm"),
        filters.get("height_min_cm"),
        filters.get("height_max_cm"),
    ):
        return False
    if not _in_range(
        phys.get("weight_estimate_kg"),
        filters.get("weight_min_kg"),
        filters.get("weight_max_kg"),
    ):
        return False
    return True


def _in_range(value, lo, hi) -> bool:
    """``True`` unless ``value`` is a real number that falls outside an
    explicitly-set ``[lo, hi]`` bound. Missing values pass."""
    if lo is None and hi is None:
        return True
    try:
        v = int(value)
    except (TypeError, ValueError):
        return True  # no estimate -> don't exclude
    if lo is not None and v < int(lo):
        return False
    if hi is not None and v > int(hi):
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


def _like_state(db, uid: str, other: str) -> tuple[bool, bool]:
    """``(you_liked, mutual)`` — for the Explore filter chips."""
    try:
        you = (
            db.collection("users").document(uid)
            .collection("likes").document(other).get().exists
        )
        if not you:
            return (False, False)
        them = (
            db.collection("users").document(other)
            .collection("likes").document(uid).get().exists
        )
        return (True, them)
    except Exception:  # noqa: BLE001
        return (False, False)


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
    seen: set[str] = set()
    for user_snap in db.collection("users").stream():
        other = user_snap.id
        # Explore lists everyone with a profile, the caller included — no
        # orientation or community gating (product decision, 2026-08-30). Only
        # blocks / paused / already-passed and the active search filters cut
        # the roster down. `seen` guards against ever emitting the same
        # person twice — a stream shouldn't repeat a document id, but a
        # single duplicate card showing two different (stale vs. current)
        # percentages for the same real person is exactly the kind of
        # data-integrity bug worth defending against defensively, not just
        # trusting the source query never to regress.
        if other in passed or other in seen or len(cards) >= limit:
            continue
        seen.add(other)
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
            # A profile with no name isn't a real, set-up person — half-finished
            # onboarding or a test fixture. Keep it out of the feed (self is
            # exempt so you always see your own card).
            if other != uid and not str(prof.get("name") or "").strip():
                continue
            # "Pause matching" (§14.2) hides you from *other* people's Explore;
            # you still see your own card (so you can tell you're paused and
            # un-pause).
            if other != uid and prof.get("paused") is True:
                continue
            if other != uid and _blocked(db, uid, other):
                continue
            # Only spend the extra read on a search that actually touches a
            # physical-attributes filter key (the common case doesn't).
            public_fields = (
                physical_attributes.public_fields(db, other)
                if any(filters.get(k) for k in _PHYSICAL_MIRROR_FILTER_KEYS)
                else None
            )
            if not _passes_filters(prof, filters, public_fields=public_fields):
                continue

            photo_path = _primary_photo_path(db, other, prof.get("photos"))
            # Return a ready token URL, not a raw storage path — Storage rules
            # only let a user read their *own* uploads/ tree, so the client
            # can't resolve another person's photo itself.
            photo_url = ""
            if photo_path:
                try:
                    from public_profile import _photo_url

                    photo_url = _photo_url(photo_path) or ""
                except Exception:  # noqa: BLE001 - never sink the feed on a photo
                    photo_url = ""

            liked, mutual = (
                (False, False) if other == uid
                else _like_state(db, uid, other)
            )
            cards.append(
                {
                    "uid": other,
                    "name": prof.get("name", ""),
                    "age": _age(prof.get("birthdate")),
                    "location": prof.get("location", ""),
                    "photo_path": photo_path,  # kept for back-compat
                    "photo_url": photo_url,
                    "score": None
                    if other == uid
                    else _score_for(db, uid, other),
                    "liked": liked,
                    "mutual": mutual,
                    "self": other == uid,
                    "paused": other == uid and prof.get("paused") is True,
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


def apply_saved_age_range(filters: dict, profile: dict | None) -> dict:
    """Default the Explore age filter to the user's saved partner age range
    (``qz_partner_age_min`` / ``qz_partner_age_max``). A bound the search
    itself set (dropdown or natural language) is never overridden."""
    out = dict(filters)
    profile = profile or {}
    for key, saved in (
        ("age_min", profile.get("qz_partner_age_min")),
        ("age_max", profile.get("qz_partner_age_max")),
    ):
        if out.get(key) is None and isinstance(saved, int):
            out[key] = saved
    return out
