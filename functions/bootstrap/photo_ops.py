"""Profile-photo grid management (ARCHITECTURE.md §8.3, §8.7 steps 5–6).

The user-visible grid is the ``photos`` array on ``users/{uid}/profile/main`` —
``[{media_id, order}, …]``, ``order: 0`` primary. Every entry points at a
``users/{uid}/user_media/{mediaId}`` doc; this module never touches those.

Delete is a **soft removal**: the array entry goes, the ``user_media`` doc, its
Storage file, face embedding, moderation status and any wiki-derived content
all stay — mirroring ``raw_turns`` immutability (§8.3).
"""

from __future__ import annotations

import logging

import schema

logger = logging.getLogger("ayma.media")

_MAX_PHOTOS = 9


def _profile_ref(db, uid: str):
    return schema.profile_doc(db, uid)


def _read_photos(db, uid: str) -> list[dict]:
    snap = _profile_ref(db, uid).get()
    photos = (snap.to_dict() or {}).get(schema.PF_PHOTOS) or [] \
        if snap.exists else []
    out = []
    for p in photos:
        if isinstance(p, dict) and p.get("media_id"):
            out.append({"media_id": str(p["media_id"]), "order": int(p.get("order", 0))})
    out.sort(key=lambda p: p["order"])
    return out


def _renumber(photos: list[dict]) -> list[dict]:
    return [{"media_id": p["media_id"], "order": i} for i, p in enumerate(photos)]


def _media_doc(db, uid: str, media_id: str) -> dict | None:
    """The ``user_media/{media_id}`` document for this user, or ``None`` if it
    doesn't exist."""
    snap = (
        db.collection("users")
        .document(uid)
        .collection(schema.USER_MEDIA)
        .document(media_id)
        .get()
    )
    return (snap.to_dict() or {}) if snap.exists else None


def list_photos(db, uid: str) -> list[dict]:
    return _read_photos(db, uid)


def add_photo(db, uid: str, media_id: str) -> list[dict]:
    """Append ``media_id`` to the visible grid (no-op if already present).

    The media must have cleared moderation: its ``user_media`` doc must exist
    and carry ``moderation_status == "approved"`` (§8.4). Flagged, pending,
    unmoderated (missing status) and unknown ids are all rejected here **before
    any write** — the pipeline deliberately keeps a ``user_media`` record for
    rejected photos, so an existence check alone would let a flagged id onto
    the grid.
    """
    media_id = media_id.strip()
    if not media_id:
        raise ValueError("media_id is required")
    doc = _media_doc(db, uid, media_id)
    if doc is None:
        raise ValueError("no such user_media doc for this user")
    status = str(doc.get(schema.MEDIA_MODERATION_STATUS, "")).strip()
    if status != schema.MEDIA_STATUS_APPROVED:
        raise ValueError(
            f"media {media_id} is not approved for display "
            f"(moderation_status={status or 'unset'})"
        )
    photos = _read_photos(db, uid)
    if any(p["media_id"] == media_id for p in photos):
        return photos
    if len(photos) >= _MAX_PHOTOS:
        raise ValueError(f"at most {_MAX_PHOTOS} photos")
    photos.append({"media_id": media_id, "order": len(photos)})
    photos = _renumber(photos)
    _profile_ref(db, uid).set({schema.PF_PHOTOS: photos}, merge=True)
    return photos


def add_photos(db, uid: str, media_ids: list[str]) -> dict:
    """Add several already-processed photos to the grid in one call — the
    batched "add photos" action (§ appearance batching): picking N photos in
    one action should mean ONE backend call, not N. Best-effort per id: one
    rejected id (not approved, already on the grid at the cap, ...) doesn't
    stop the rest. Returns ``{photos, added, failed}`` — ``added`` is the
    media ids that actually landed on the grid, in the order given;
    ``failed`` is ``[{media_id, error}]`` for the ones that didn't."""
    added: list[str] = []
    failed: list[dict] = []
    photos: list[dict] = []
    for media_id in media_ids:
        try:
            photos = add_photo(db, uid, media_id)
            added.append(media_id.strip())
        except ValueError as exc:
            failed.append({"media_id": media_id, "error": str(exc)})
    if not photos:
        photos = _read_photos(db, uid)
    return {"photos": photos, "added": added, "failed": failed}


def remove_photo(db, uid: str, media_id: str) -> list[dict]:
    """Soft-remove: drop the grid entry only. ``user_media`` is untouched."""
    photos = [p for p in _read_photos(db, uid) if p["media_id"] != media_id.strip()]
    photos = _renumber(photos)
    _profile_ref(db, uid).set({schema.PF_PHOTOS: photos}, merge=True)
    return photos


def reorder_photos(db, uid: str, media_ids: list[str]) -> list[dict]:
    """Set grid order to ``media_ids``. Ids not currently in the grid are
    ignored; missing ids keep their relative order at the end."""
    current = _read_photos(db, uid)
    by_id = {p["media_id"]: p for p in current}
    ordered = [by_id[m] for m in media_ids if m in by_id]
    ordered += [p for p in current if p["media_id"] not in set(media_ids)]
    photos = _renumber(ordered)
    _profile_ref(db, uid).set({schema.PF_PHOTOS: photos}, merge=True)
    return photos
