"""Photo-derived attribute extraction (ARCHITECTURE.md §6.3, §6.11 step 3).

At profile-photo upload, alongside the face embedding (§2.5), a vision pass
pulls observable attributes and stores them as structured, filterable fields on
``users/{uid}/profile/main`` under ``photo_attrs`` and on the per-photo
``users/{uid}/user_media/{id}.attributes`` record. Low-confidence by design:
"unknown" is a first-class value.

The same pass also tags each photo by **shot type** so callers (the Appearance
report, the Skills-screen coverage line) can tell whether the user has a usable
face photo and a usable full-body photo:

* ``shot_type``       — ``face`` | ``upper_body`` | ``full_body`` | ``group`` | ``other``
* ``usable_for_face`` — a clear, single, front-ish face with the whole face in frame
* ``usable_for_body`` — a single person, roughly full-length / standing, body visible

These are *not* Explore filters — they live only on the per-photo record.
"""

from __future__ import annotations

import json
import logging
from functools import lru_cache
from pathlib import Path

import gemini

logger = logging.getLogger("ayma.media")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "photo_attributes.md"
_SCHEMA_PATH = Path(__file__).with_name("explore_filter_schema.json")

# Shot-type tagging — appended to every photo-attribute record, kept out of the
# Explore filter schema on purpose.
SHOT_TYPE_FIELD = "shot_type"
SHOT_TYPES: tuple[str, ...] = (
    "face",
    "upper_body",
    "full_body",
    "group",
    "other",
)
USABLE_FIELDS: tuple[str, ...] = ("usable_for_face", "usable_for_body")
# Tagged alongside `usable_for_body` — true only when loose/baggy clothing
# meaningfully hides the figure, so callers can nudge toward a fitted-clothing
# photo for a more accurate body-composition read (§1.8.0 shot-type nudge).
LOOSE_CLOTHING_FIELD = "loose_clothing"
_BOOL_FIELDS: tuple[str, ...] = (*USABLE_FIELDS, LOOSE_CLOTHING_FIELD)
_EXTRA_FIELDS: tuple[str, ...] = (SHOT_TYPE_FIELD, *_BOOL_FIELDS)


@lru_cache(maxsize=1)
def _prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def _explore_fields() -> tuple[str, ...]:
    return tuple(
        f["field"]
        for f in json.loads(_SCHEMA_PATH.read_text())["photo_attributes"]
    )


@lru_cache(maxsize=1)
def _response_schema() -> dict:
    fields = json.loads(_SCHEMA_PATH.read_text())["photo_attributes"]
    props: dict[str, dict] = {}
    for f in fields:
        if f["type"] == "enum":
            props[f["field"]] = {"type": "string", "enum": f["values"]}
        else:
            props[f["field"]] = {"type": "string"}
    props[SHOT_TYPE_FIELD] = {"type": "string", "enum": list(SHOT_TYPES)}
    for f in _BOOL_FIELDS:
        props[f] = {"type": "boolean"}
    return {
        "type": "object",
        "properties": props,
        "required": list(props),
    }


@lru_cache(maxsize=1)
def attribute_fields() -> tuple[str, ...]:
    """Every field on a per-photo attribute record — the Explore-filterable
    attributes plus the shot-type tags."""
    return _explore_fields() + _EXTRA_FIELDS


def _blank() -> dict:
    out: dict[str, object] = {f: "unknown" for f in _explore_fields()}
    out[SHOT_TYPE_FIELD] = "other"
    for f in _BOOL_FIELDS:
        out[f] = False
    return out


def _coerce(result: dict) -> dict:
    out: dict[str, object] = {
        f: str(result.get(f, "unknown")) or "unknown" for f in _explore_fields()
    }
    st = str(result.get(SHOT_TYPE_FIELD, "") or "").strip().lower()
    out[SHOT_TYPE_FIELD] = st if st in SHOT_TYPES else "other"
    for f in _BOOL_FIELDS:
        out[f] = bool(result.get(f))
    return out


async def extract_attributes(image_bytes: bytes, mime_type: str) -> dict:
    """Return the §6.3 attribute map for a photo, including the shot-type tags.
    On any failure returns a blank record (all ``"unknown"`` / ``other`` /
    ``False``) so callers stay best-effort."""
    try:
        result = await gemini.generate_json(
            "Extract the profile-photo attributes.",
            system_prompt=_prompt(),
            response_schema=_response_schema(),
            image=(image_bytes, mime_type),
        )
    except Exception:  # noqa: BLE001
        logger.exception("photo attribute extraction failed")
        return _blank()
    if not isinstance(result, dict):
        return _blank()
    return _coerce(result)


# --- per-user coverage ------------------------------------------------------


def _grid_media_ids(prof: dict) -> list[str]:
    entries = [p for p in (prof.get("photos") or []) if isinstance(p, dict)]
    entries.sort(key=lambda p: p.get("order", 0))
    return [
        str(e.get("media_id") or "").strip()
        for e in entries
        if str(e.get("media_id") or "").strip()
    ]


def coverage(db, uid: str) -> dict:
    """``{has_face_photo, has_body_photo, has_fitted_body_photo}`` for
    ``uid`` — derived from the shot-type tags on the user's current grid
    photos. ``has_fitted_body_photo`` is ``True`` only once at least one
    usable-for-body photo is NOT tagged ``loose_clothing`` — it powers the
    "avoid baggy clothing" nudge alongside the existing face/body-shot nudge.
    Best-effort: a read failure or an un-tagged photo set just reports
    ``False`` for everything."""
    out = {
        "has_face_photo": False,
        "has_body_photo": False,
        "has_fitted_body_photo": False,
    }
    try:
        prof = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
            .to_dict()
        ) or {}
    except Exception:  # noqa: BLE001
        return out
    for mid in _grid_media_ids(prof):
        try:
            attrs = (
                (
                    db.collection("users")
                    .document(uid)
                    .collection("user_media")
                    .document(mid)
                    .get()
                    .to_dict()
                )
                or {}
            ).get("attributes") or {}
        except Exception:  # noqa: BLE001
            continue
        if attrs.get("usable_for_face"):
            out["has_face_photo"] = True
        if attrs.get("usable_for_body"):
            out["has_body_photo"] = True
            if not attrs.get(LOOSE_CLOTHING_FIELD):
                out["has_fitted_body_photo"] = True
        if (
            out["has_face_photo"]
            and out["has_body_photo"]
            and out["has_fitted_body_photo"]
        ):
            break
    return out


# --- backfill ------------------------------------------------------------------


async def backfill_missing_tags(db, *, user_limit: int = 200) -> dict:
    """Re-run the attribute pass for every approved ``user_media`` photo that
    was processed before shot-type tagging existed (has ``attributes`` but no
    ``attributes.shot_type``). Mirrors
    :func:`physical_attributes.backfill_missing`. Bounded by ``user_limit``
    users. Best-effort — a per-photo failure is skipped, never raised."""
    import media_embed

    scanned = tagged = 0
    try:
        users = list(db.collection("users").stream())
    except Exception:  # noqa: BLE001
        logger.exception("photo-tags backfill: user scan failed")
        return {"users": 0, "photos_tagged": 0}
    for snap in users:
        if scanned >= user_limit:
            break
        uid = snap.id
        scanned += 1
        try:
            media = list(
                db.collection("users")
                .document(uid)
                .collection("user_media")
                .stream()
            )
        except Exception:  # noqa: BLE001
            continue
        for m in media:
            data = m.to_dict() or {}
            attrs = data.get("attributes")
            if not isinstance(attrs, dict) or attrs.get(SHOT_TYPE_FIELD):
                continue
            if data.get("moderation_status") not in (None, "", "approved"):
                continue
            sp = str(data.get("storage_path") or "").strip()
            if not sp:
                continue
            try:
                image, mime = media_embed.download_bytes(sp)
            except Exception:  # noqa: BLE001
                continue
            if not image:
                continue
            fresh = await extract_attributes(image, mime)
            try:
                db.collection("users").document(uid).collection(
                    "user_media"
                ).document(m.id).set({"attributes": fresh}, merge=True)
                tagged += 1
            except Exception:  # noqa: BLE001
                logger.exception(
                    "photo-tags backfill: write failed for %s/%s", uid, m.id
                )
    return {"users": scanned, "photos_tagged": tagged}
