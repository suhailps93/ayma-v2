"""Profile-photo grid management (ARCHITECTURE.md §8.3, §8.7 steps 5–6).

The user-visible grid is the ``photos`` array on ``users/{uid}/profile/main`` —
``[{media_id, order}, …]``, ``order: 0`` primary. Every entry points at a
``users/{uid}/user_media/{mediaId}`` doc.

Two tiers of removal, driven by the inline public-profile carousel (§8.3):

* **remove from public** (:func:`remove_photo`, the default) moves the entry
  out of ``photos`` into ``hidden_photos`` (:data:`schema.PF_HIDDEN_PHOTOS`).
  It disappears from every public reader, but stays in the analysis pool
  (:func:`schema.analysis_photo_entries`) and its ``user_media`` doc — Storage
  file, face embedding, moderation status — is untouched. Reversible.
* **delete everywhere** (:func:`delete_photo_permanent`) drops the entry from
  both arrays and erases the media itself (the ``user_media`` doc and its
  Storage blob). Not reversible.
"""

from __future__ import annotations

import logging

import schema

logger = logging.getLogger("ayma.media")

_MAX_PHOTOS = 9


def _profile_ref(db, uid: str):
    return schema.profile_doc(db, uid)


def _clean(entries) -> list[dict]:
    out = []
    for p in entries or []:
        if isinstance(p, dict) and p.get("media_id"):
            out.append(
                {"media_id": str(p["media_id"]), "order": int(p.get("order", 0))}
            )
    out.sort(key=lambda p: p["order"])
    return out


def _read_photos(db, uid: str) -> list[dict]:
    snap = _profile_ref(db, uid).get()
    data = (snap.to_dict() or {}) if snap.exists else {}
    return _clean(data.get(schema.PF_PHOTOS))


def _read_hidden(db, uid: str) -> list[dict]:
    snap = _profile_ref(db, uid).get()
    data = (snap.to_dict() or {}) if snap.exists else {}
    return _clean(data.get(schema.PF_HIDDEN_PHOTOS))


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
    payload = {schema.PF_PHOTOS: photos}
    # Re-adding a photo that was removed-from-public brings it back out of the
    # hidden list, so it isn't counted twice in the analysis pool.
    current_hidden = _read_hidden(db, uid)
    hidden = [h for h in current_hidden if h["media_id"] != media_id]
    if len(hidden) != len(current_hidden):
        payload[schema.PF_HIDDEN_PHOTOS] = _renumber(hidden)
    _profile_ref(db, uid).set(payload, merge=True)
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
    """Remove from public: move the grid entry into ``hidden_photos`` (§8.3).

    The photo leaves the public profile but stays in the analysis pool
    (:func:`schema.analysis_photo_entries`) and its ``user_media`` doc —
    Storage file, embedding, moderation status — is untouched. Reversible by a
    re-add. A no-op for an id that is not currently public. Returns the new
    public grid."""
    media_id = media_id.strip()
    photos = _read_photos(db, uid)
    moved = next((p for p in photos if p["media_id"] == media_id), None)
    if moved is None:
        return photos
    photos = _renumber([p for p in photos if p["media_id"] != media_id])
    hidden = [h for h in _read_hidden(db, uid) if h["media_id"] != media_id]
    hidden.append(moved)
    _profile_ref(db, uid).set(
        {schema.PF_PHOTOS: photos, schema.PF_HIDDEN_PHOTOS: _renumber(hidden)},
        merge=True,
    )
    return photos


def set_primary(db, uid: str, media_id: str) -> list[dict]:
    """Make ``media_id`` the primary (order 0) public photo, keeping the rest
    in their current relative order. A no-op for an id not currently public
    (you can't make a removed photo primary without re-adding it first).
    Returns the new public grid."""
    media_id = media_id.strip()
    photos = _read_photos(db, uid)
    if not any(p["media_id"] == media_id for p in photos):
        return photos
    ordered = [p for p in photos if p["media_id"] == media_id]
    ordered += [p for p in photos if p["media_id"] != media_id]
    photos = _renumber(ordered)
    _profile_ref(db, uid).set({schema.PF_PHOTOS: photos}, merge=True)
    return photos


def delete_photo_permanent(db, uid: str, media_id: str, bucket=None) -> list[dict]:
    """Delete everywhere: drop the entry from the public grid AND the hidden
    list, then erase the media itself — the ``user_media`` doc and its Storage
    blob (so the face/body embedding and analysis go too). Not reversible.
    Returns the new public grid. Missing media / Storage files are ignored
    (already gone is fine)."""
    media_id = media_id.strip()
    photos = _renumber(
        [p for p in _read_photos(db, uid) if p["media_id"] != media_id]
    )
    hidden = _renumber(
        [h for h in _read_hidden(db, uid) if h["media_id"] != media_id]
    )
    _profile_ref(db, uid).set(
        {schema.PF_PHOTOS: photos, schema.PF_HIDDEN_PHOTOS: hidden}, merge=True
    )
    media_ref = (
        db.collection("users")
        .document(uid)
        .collection(schema.USER_MEDIA)
        .document(media_id)
    )
    storage_path = ""
    try:
        snap = media_ref.get()
        if getattr(snap, "exists", False):
            storage_path = str((snap.to_dict() or {}).get("storage_path") or "")
        media_ref.delete()
    except Exception:  # noqa: BLE001 - never block the public-grid write on it
        logger.warning("user_media delete failed for %s/%s", uid, media_id,
                       exc_info=True)
    if storage_path and bucket is not None:
        try:
            bucket.blob(storage_path).delete()
        except Exception:  # noqa: BLE001 - already gone is fine
            logger.warning("storage delete failed for %s", storage_path,
                           exc_info=True)
    return photos


def reorder_photos(db, uid: str, media_ids: list[str]) -> list[dict]:
    """Set the public grid order to ``media_ids``; ``media_ids[0]`` becomes
    primary. Ids not currently public are ignored; omitted public ids keep
    their relative order at the end. Hidden photos are untouched."""
    current = _read_photos(db, uid)
    by_id = {p["media_id"]: p for p in current}
    ordered = [by_id[m] for m in media_ids if m in by_id]
    ordered += [p for p in current if p["media_id"] not in set(media_ids)]
    photos = _renumber(ordered)
    _profile_ref(db, uid).set({schema.PF_PHOTOS: photos}, merge=True)
    return photos
