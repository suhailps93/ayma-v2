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
* ``usable_for_body`` — a single person's body visible (any pose — standing,
  sitting, whatever the photo shows), not just their face; derived from
  ``shot_type`` (`upper_body`/`full_body`) rather than the model's own
  judgment, so a face-only crop or a group photo is the only thing excluded

These are *not* Explore filters — they live only on the per-photo record.
"""

from __future__ import annotations

import json
import logging
from functools import lru_cache
from pathlib import Path

from prompt import load_prompt_file
import gemini
import schema
import token_ledger

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
    # Derived from shot_type rather than trusting the model's own judgment
    # verbatim — founder report: a sitting, clothed body-visible photo (and a
    # cropped mirror selfie) both got tagged unusable because the old prompt
    # asked for "full-length / standing", so the physique report never had a
    # qualifying photo despite two real body shots. Founder's actual rule:
    # any single-person shot with the body visible counts, in any pose;
    # exclude only a face-only crop or a group photo. `upper_body` and
    # `full_body` are exactly that; `face`/`group`/`other` are not.
    out["usable_for_body"] = st in ("upper_body", "full_body")
    return out


async def extract_attributes(
    image_bytes: bytes, mime_type: str, *, uid: str | None = None
) -> dict:
    """Return the §6.3 attribute map for a photo, including the shot-type tags.
    On any failure returns a blank record (all ``"unknown"`` / ``other`` /
    ``False``) so callers stay best-effort."""
    try:
        result = await gemini.generate_json(
            "Extract the profile-photo attributes.",
            system_prompt=load_prompt_file(_PROMPT_PATH),
            response_schema=_response_schema(),
            image=(image_bytes, mime_type),
            uid=uid,
            feature=token_ledger.FEATURE_PHOTO_ATTRS,
            enforce_cap=False,
        )
    except Exception:  # noqa: BLE001
        logger.exception("photo attribute extraction failed")
        return _blank()
    if not isinstance(result, dict):
        return _blank()
    return _coerce(result)


# --- per-user coverage ------------------------------------------------------


def _grid_media_ids(prof: dict) -> list[str]:
    # Public grid + removed-from-public photos kept for analysis (§8.3), so
    # attribute coverage still includes photos the user hid from their public
    # profile.
    entries = schema.analysis_photo_entries(prof)
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


def eligibility(db, uid: str) -> dict:
    """Per-photo face/body eligibility for the Appearance pre-run sheet.

    Returns ``{"face": [...], "body": [...], "has_face_photo",
    "has_body_photo"}`` where each list holds, for every current grid photo
    eligible for that axis, a map of::

        {"media_id", "url", "person_count", "multi_person",
         "shows_face", "shows_body", "auto_select"}

    in grid order — so the client can show the two groups as thumbnails before a
    run and let the user pick which photos feed each.

    ``auto_select`` is the per-axis default the sheet pre-checks (§ founder
    2026-10-28 screenshot fix): a photo is auto-selected for an axis ONLY when
    it is a solo shot of the user (``person_count == 1``, i.e. not a ``group``
    photo) AND it actually shows that axis — a single clear face for Face
    (``shows_face``) or the user's body for Body (``shows_body``). A multi-person
    photo is NEVER auto-selected (analysis needs solo shots of the user, and not
    analysing a photo of other people is privacy-positive); a face-only crop is
    never auto-selected into Body, nor a body-only shot into Face. The user may
    still manually check any surfaced photo — ``auto_select`` only controls the
    pre-check. Defensive: an untagged / ambiguous photo (``person_count`` 0,
    ``shows_* == False``) is surfaced but never pre-checked.

    The same shot-type tags :func:`coverage` reads; a photo can appear in both
    groups (a full-body shot with a clear face) or neither (a group photo). The
    ``url`` is the stable token-download URL the rest of the app serves photos
    with (:func:`public_profile._photo_url`); a photo whose URL can't be
    resolved is dropped from its group rather than shown broken. Best-effort: a
    read failure just yields empty groups."""
    from public_profile import _photo_url

    out: dict = {
        "face": [],
        "body": [],
        "has_face_photo": False,
        "has_body_photo": False,
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
            media = (
                db.collection("users")
                .document(uid)
                .collection("user_media")
                .document(mid)
                .get()
                .to_dict()
            ) or {}
        except Exception:  # noqa: BLE001
            continue
        attrs = media.get("attributes") or {}
        sp = str(media.get("storage_path") or "").strip()
        if not sp:
            continue
        try:
            url = _photo_url(sp)
        except Exception:  # noqa: BLE001
            url = None
        if not url:
            continue
        uf = bool(attrs.get("usable_for_face"))
        ub = bool(attrs.get("usable_for_body"))
        # Per-photo people signal. The vision pass (prompts/photo_attributes.md)
        # already tags `shot_type: group` for "more than one person in frame";
        # no cheaper per-photo face-count signal exists (face embeddings are one
        # vector per image), so reuse that tag rather than a new vision call.
        # `person_count` is coarse on purpose — 1 for a single-person shot type,
        # 2 for a group ("≥ 2"), 0 when the shot type is unknown / untagged.
        st = str(attrs.get(SHOT_TYPE_FIELD) or "").strip().lower()
        multi_person = st == "group"
        if st in ("face", "upper_body", "full_body"):
            person_count = 1
        elif multi_person:
            person_count = 2
        else:
            person_count = 0  # unknown / untagged -> safer defaults below
        # has_* stay the honest coverage signal (a real usable-for-axis photo
        # exists), feeding the add-a-photo nudges elsewhere.
        if uf:
            out["has_face_photo"] = True
        if ub:
            out["has_body_photo"] = True
        # Surface EVERY grid photo, auto-sorted into the two buckets so the
        # pre-run sheet shows the whole set (§ founder 2026-10-28: a photo must
        # not be hidden just because its shot-type tag is missing/ambiguous).
        # A photo clearly for one axis shows only there; an untagged, group, or
        # otherwise-ambiguous photo shows in BOTH so the user can pick. A
        # face-only crop is never offered for body, nor a body-only shot for
        # face. The user's explicit pick is honoured by :func:`appearance._pick`
        # regardless of the tag, so a freshly-added, not-yet-tagged photo is
        # still analysable.
        #
        # `auto_select` is the per-axis pre-check default the sheet obeys
        # (§ founder 2026-10-28 screenshot bug): only a SOLO photo of the user
        # that actually shows that axis is pre-checked. A multi-person photo is
        # never auto-selected (analysis needs solo shots; not analysing other
        # people is also privacy-positive); a face-only/no-body or body-only/no-
        # face photo is surfaced in the other bucket but not pre-checked there.
        solo = person_count == 1
        base = {
            "media_id": mid,
            "url": url,
            "person_count": person_count,
            "multi_person": multi_person,
            "shows_face": uf,
            "shows_body": ub,
        }
        if uf or not ub:
            out["face"].append({**base, "auto_select": solo and uf})
        if ub or not uf:
            out["body"].append({**base, "auto_select": solo and ub})
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
            fresh = await extract_attributes(image, mime, uid=uid)
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


async def resync_usable_for_body(db, *, user_limit: int = 500) -> dict:
    """One-time data fix, no Gemini calls: every already-tagged photo's
    ``usable_for_body`` was set by the OLD prompt's "full-length / standing"
    rule (§ founder report: a sitting, clothed, body-visible photo and a
    cropped mirror selfie both got marked unusable, so the physique report
    never had a qualifying photo despite two real body shots). ``_coerce``
    now derives ``usable_for_body`` from the already-stored ``shot_type``
    instead — this just re-applies that same derivation to every existing
    ``user_media`` record so already-uploaded photos don't need a re-upload
    to benefit. Bounded by ``user_limit`` users; best-effort, a per-photo
    failure is skipped."""
    scanned = fixed = 0
    try:
        users = list(db.collection("users").stream())
    except Exception:  # noqa: BLE001
        logger.exception("usable_for_body resync: user scan failed")
        return {"users": 0, "photos_fixed": 0}
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
            if not isinstance(attrs, dict):
                continue
            st = str(attrs.get(SHOT_TYPE_FIELD, "") or "")
            correct = st in ("upper_body", "full_body")
            if bool(attrs.get("usable_for_body")) == correct:
                continue
            attrs["usable_for_body"] = correct
            try:
                db.collection("users").document(uid).collection(
                    "user_media"
                ).document(m.id).set({"attributes": attrs}, merge=True)
                fixed += 1
            except Exception:  # noqa: BLE001
                logger.exception(
                    "usable_for_body resync: write failed for %s/%s", uid, m.id
                )
    return {"users": scanned, "photos_fixed": fixed}
