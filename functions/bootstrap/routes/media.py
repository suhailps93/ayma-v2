"""Media and Photo Grid endpoints (see docs/ARCHITECTURE.md § Media & Photos)."""

from __future__ import annotations

import asyncio
import logging
from typing import Literal

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from pydantic import BaseModel, Field

import appearance
from auth import require_uid
import auto_analysis
import photo_notes
import photo_ops
import physical_attributes

logger = logging.getLogger(__name__)

router = APIRouter(tags=["media"])


def get_db():
    import main
    fn = getattr(main, "get_db", None)
    if fn is not None:
        return fn()
    import db
    return db.get_db()


def _bucket():
    import main
    fn = getattr(main, "_bucket", None)
    if fn is not None and fn is not _bucket:
        return fn()
    from firebase_admin import storage
    from config import CONFIG
    return storage.bucket(CONFIG.storage_bucket)


class MediaRequest(BaseModel):
    storage_path: str = Field(min_length=1, max_length=500)
    context: Literal["profile", "chat", "dm"] = "profile"
    # Whatever the user typed alongside this photo (a chat message sent with
    # it) — optional, empty for a profile-grid upload (nothing is "said" when
    # adding one). Folded into the caption composer (§ photo_pipeline).
    caption_context: str = Field(default="", max_length=2000)


class PhotoRef(BaseModel):
    media_id: str = Field(min_length=1, max_length=128)


class PhotoBatchRef(BaseModel):
    media_ids: list[str] = Field(min_length=1, max_length=9)


class PhotoOrder(BaseModel):
    media_ids: list[str] = Field(min_length=0, max_length=32)


def _media_record(uid: str, media_id: str) -> dict:
    """The stored ``users/{uid}/user_media/{media_id}`` doc, or ``{}`` if it
    can't be read."""
    import main
    fn = getattr(main, "_media_record", None)
    if fn is not None and fn is not _media_record:
        return fn(uid, media_id)
    try:
        snap = (
            get_db()
            .collection("users")
            .document(uid)
            .collection("user_media")
            .document(media_id)
            .get()
        )
        return snap.to_dict() or {}
    except Exception:  # noqa: BLE001
        logger.exception(
            "media record lookup failed for %s/%s", uid, media_id
        )
        return {}


def _resolve_new_photo(uid: str, media_id: str) -> tuple[str, list[float] | None, dict | None] | None:
    """A newly-grid-added media id resolved to
    ``(storage_path, embedding, attributes)`` for
    :func:`appearance.run_batch_photos`, or ``None`` when it has no storage
    path (shouldn't happen for an approved photo, but never block on it)."""
    record = _media_record(uid, media_id)
    storage_path = str(record.get("storage_path") or "").strip()
    if not storage_path:
        return None
    return (
        storage_path, photo_notes._vec(record.get("embedding")),
        record.get("attributes"),
    )


@router.post("/media")
async def register_media(
    req: MediaRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Embed an uploaded photo and record it on ``user_media`` (§2.5, §2.8
    step 7). The client uploads the file to ``uploads/{uid}/…`` first, then
    calls this. The unified ``/media/upload`` entry + full §8.5 pipeline is
    Phase 10.
    """
    prefix = f"uploads/{uid}/"
    if not req.storage_path.startswith(prefix):
        raise HTTPException(
            status_code=403,
            detail="storage_path must be under the caller's uploads/ tree.",
        )
    import photo_pipeline

    try:
        result = await photo_pipeline.process(
            get_db(),
            uid,
            req.storage_path,
            req.context,
            wiki_uids=[uid] if req.context in ("profile", "chat") else None,
            accompanying_text=req.caption_context,
            background=background,
            # A profile-grid upload needs the photo stored, moderated and
            # tagged before it returns, but nothing on the upload/preview path
            # consumes the caption — defer the captioning + wiki fold off the
            # request path so the add returns as soon as the photo is safe to
            # show. Chat/DM keep it inline so Ayma can reference the image in
            # the same turn.
            defer_enrichment=(req.context == "profile"),
        )
    except Exception as exc:  # noqa: BLE001 - surface embed/storage failure
        raise HTTPException(
            status_code=502, detail=f"Media pipeline failed: {exc}"
        ) from exc

    if req.context == "profile":
        # A profile-grid photo isn't "added" yet at this point — it only
        # becomes visible via POST /media/photos or /media/photos/batch,
        # which run the batched Appearance pipeline
        # (appearance.run_batch_photos) themselves. Triggering analysis here
        # too used to double-analyse every profile upload (register + grid
        # add) — one of the causes of the old "7+ history entries from 4
        # photos" bug (§ appearance report v2).
        pass
    else:
        # A chat/DM attachment never goes through the grid — this is its
        # only analysis trigger, so keep it here. Auto-analysis (§ auto
        # analysis): the user's own photo -> face/body read into their
        # private `ai_only` memory, in the background. Reuses the
        # embedding/attributes the pipeline just computed rather than
        # re-deriving them, and is gated by them (group shot / face-match /
        # usable flags).
        background.add_task(
            auto_analysis.analyse_photo, get_db(), uid, req.storage_path,
            embedding=result.get("embedding"), attributes=result.get("attributes"),
        )

    return {
        "ok": True,
        "media_id": result["media_id"],
        "moderation_status": result["moderation_status"],
        "published": result["published"],
        "reason": result["reason"],
        "photo_attrs": result["attributes"],
    }


@router.get("/media/photos")
async def media_photos_list(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The current profile-photo grid (§8.3)."""
    return {"photos": await asyncio.to_thread(photo_ops.list_photos, get_db(), uid)}


@router.post("/media/photos")
async def media_photos_add(
    req: PhotoRef,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Add an already-processed photo to the grid (§8.7 step 6). A single add
    is a batch of one — see ``POST /media/photos/batch`` for adding several
    photos picked in one action."""
    try:
        photos = await asyncio.to_thread(
            photo_ops.add_photo, get_db(), uid, req.media_id
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    resolved = await asyncio.to_thread(_resolve_new_photo, uid, req.media_id)
    background.add_task(
        appearance.run_batch_photos, get_db(), uid,
        [resolved] if resolved else [], source="add_photo",
    )
    return {"ok": True, "photos": photos}


@router.post("/media/photos/batch")
async def media_photos_add_batch(
    req: PhotoBatchRef,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Add several already-processed photos to the grid in ONE call — the
    batched add-photos flow (§ appearance batching) onboarding and "add more
    photos" should use instead of looping ``POST /media/photos`` once per
    photo: picking N photos in one action analyses them together, as one
    update to the caller's single persistent Appearance report, instead of N
    separate per-photo runs."""
    result = await asyncio.to_thread(
        photo_ops.add_photos, get_db(), uid, req.media_ids
    )
    resolved = [
        r for r in (
            await asyncio.gather(
                *[
                    asyncio.to_thread(_resolve_new_photo, uid, mid)
                    for mid in result["added"]
                ]
            )
        ) if r is not None
    ]
    background.add_task(
        appearance.run_batch_photos, get_db(), uid, resolved,
        source="add_photos_batch",
    )
    return {
        "ok": True, "photos": result["photos"],
        "added": result["added"], "failed": result["failed"],
    }


@router.post("/media/photos/{media_id}/remove")
async def media_photos_remove(
    media_id: str,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Remove a photo from the PUBLIC profile — it moves to the hidden list, so
    it leaves every public reader but stays in Ayma's analysis pool and its
    ``user_media`` doc/Storage/embedding are untouched (§8.3, §8.7 step 5).
    Reversible by re-adding. For an irreversible erase see
    ``/media/photos/{id}/delete``."""
    photos = await asyncio.to_thread(
        photo_ops.remove_photo, get_db(), uid, media_id
    )
    # The public lead photo may have changed — rebuild physical attributes.
    background.add_task(physical_attributes.refresh, get_db(), uid)
    return {"ok": True, "photos": photos}


@router.post("/media/photos/{media_id}/primary")
async def media_photos_set_primary(
    media_id: str,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Make ``media_id`` the primary (hero) public photo (§8.3). A no-op for an
    id that isn't currently a public photo."""
    photos = await asyncio.to_thread(
        photo_ops.set_primary, get_db(), uid, media_id
    )
    # The lead photo changed — rebuild the physical-attributes record.
    background.add_task(physical_attributes.refresh, get_db(), uid)
    return {"ok": True, "photos": photos}


@router.post("/media/photos/{media_id}/delete")
async def media_photos_delete_permanent(
    media_id: str,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Delete a photo EVERYWHERE — drop it from the public grid and the hidden
    list, then erase the ``user_media`` doc and its Storage blob so the
    face/body embedding and analysis go too (§8.3). Not reversible; the inline
    carousel gates this behind a second "Delete everywhere" confirm. The usual
    "remove" (``/remove``) only hides it from the public profile."""
    photos = await asyncio.to_thread(
        photo_ops.delete_photo_permanent, get_db(), uid, media_id, _bucket()
    )
    # The photo set changed — rebuild the physical-attributes record.
    background.add_task(physical_attributes.refresh, get_db(), uid)
    return {"ok": True, "photos": photos}


@router.put("/media/photos/order")
async def media_photos_reorder(
    req: PhotoOrder,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Reorder the grid; ``media_ids[0]`` becomes the primary photo (§8.3)."""
    photos = await asyncio.to_thread(
        photo_ops.reorder_photos, get_db(), uid, req.media_ids
    )
    # Reordering changes which photos lead the physical-attributes read.
    background.add_task(physical_attributes.refresh, get_db(), uid)
    return {"ok": True, "photos": photos}
