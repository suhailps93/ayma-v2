"""Unified photo pipeline (ARCHITECTURE.md §8.5, §8.7 step 4).

Every photo — profile upload, Instagram import, DM image — runs the same
sequence, and the results all land on one ``users/{uid}/user_media/{mediaId}``
doc:

1. **moderation** (§8.4). Flagged photos stop here: the ``user_media`` doc is
   written with ``moderation_status: "flagged"`` so admin can review, but the
   photo is never embedded, never captioned into the wiki, and the caller must
   keep it out of ``profile.photos`` / Explore / DM.
2. **face embedding** (§2.5) — the multimodal vector, for same-person checks.
3. **attribute extraction** (§6.3) — observable filterable attributes.
4. **vision captioning into the wiki** (§2.3) — for the uids in ``wiki_uids``,
   at ``wiki_visibility`` (DM images default ``ai_only``, §6.8).

Only ``visibility`` differs by source; the steps do not.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone

from google.cloud.firestore_v1.vector import Vector

import deep_dive_images
import gemini
import media_embed
import photo_attrs
import photo_moderation
import schema
from post_turn import persist_raw_turns
from transcript import ROLE_USER, Turn
from wiki_ingest import ingest as wiki_ingest

logger = logging.getLogger("ayma.media")

_CAPTION_SCHEMA = {
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"],
}

# Canonical values live in schema.py so photo_ops can gate the grid on the
# same constant it's written with.
STATUS_APPROVED = schema.MEDIA_STATUS_APPROVED
STATUS_FLAGGED = schema.MEDIA_STATUS_FLAGGED


async def _caption(image: bytes, mime: str) -> str:
    try:
        result = await gemini.generate_json(
            "Caption what this photo shows in one or two plain sentences.",
            system_prompt="You describe images factually and briefly.",
            response_schema=_CAPTION_SCHEMA,
            image=(image, mime),
        )
    except Exception:  # noqa: BLE001
        logger.exception("photo caption failed")
        return ""
    return (result or {}).get("text", "").strip() if isinstance(result, dict) else ""


def _media_col(db, uid: str):
    return db.collection("users").document(uid).collection("user_media")


def caption_turn_text(caption: str, *, shot_type: str = "", match: str = "") -> str:
    """The turn text folded into the wiki for a shared/uploaded photo —
    the vision caption plus the face-match verdict, so "of user" vs. "other"
    is unambiguous right at ingest time (shared by every caller that folds a
    photo caption into the wiki: this module's own ``wiki_uids`` path,
    ``dm_ingest``, and ``main._run_chat_followups``).

    * a group shot (``shot_type == "group"``) — "(shared a group photo) …"
    * a confirmed match (``match == "self"``) — "(shared a photo of
      themselves) …"
    * a confirmed non-match (``match == "not_self"``) — "(shared a photo,
      not of themselves — shows …)"
    * anything else (no reference to check against, or a borderline
      "can't tell") — "(shared a photo) …", same as before this existed.
    """
    caption = (caption or "").strip()
    if shot_type == "group":
        prefix = "(shared a group photo)"
    elif match == "self":
        prefix = "(shared a photo of themselves)"
    elif match == "not_self":
        if caption:
            return f"(shared a photo, not of themselves — shows {caption})"
        return "(shared a photo, not of themselves)"
    else:
        prefix = "(shared a photo)"
    return f"{prefix} {caption}" if caption else prefix


async def process(
    db,
    uid: str,
    storage_path: str,
    source: str,
    *,
    wiki_uids: list[str] | None = None,
    wiki_visibility: str | None = None,
) -> dict:
    """Run the full pipeline for one image. Returns a status dict:
    ``{media_id, moderation_status, published, reason, attributes, caption,
    embedding}`` — ``embedding`` is the already-computed face-embedding
    vector (``None`` on a moderation reject), passed to
    ``auto_analysis.analyse_photo`` by every caller so it never has to
    re-derive it.
    """
    now = datetime.now(timezone.utc)
    image, mime = media_embed.download_bytes(storage_path)

    verdict = await photo_moderation.moderate(image, mime)
    if not verdict["allowed"]:
        doc = _media_col(db, uid).document()
        doc.set(
            {
                "storage_path": storage_path,
                "source": source,
                "moderation_status": STATUS_FLAGGED,
                "moderation_reason": verdict["reason"],
                "moderation_categories": verdict["categories"],
                "created_at": now,
            }
        )
        return {
            "media_id": doc.id,
            "moderation_status": STATUS_FLAGGED,
            "published": False,
            "reason": verdict["reason"],
            "attributes": None,
            "caption": "",
            "embedding": None,
        }

    embedding = media_embed.embed_image_bytes(image, mime)
    attributes = await photo_attrs.extract_attributes(image, mime)
    caption = await _caption(image, mime)

    doc = _media_col(db, uid).document()
    doc.set(
        {
            "storage_path": storage_path,
            "source": source,
            "moderation_status": STATUS_APPROVED,
            "moderation_reason": "",
            "embedding": Vector(embedding),
            "dim": len(embedding),
            "attributes": attributes,
            "caption": caption,
            "created_at": now,
        }
    )

    if source == "profile":
        db.collection("users").document(uid).collection("profile").document(
            "main"
        ).set({"photo_attrs": attributes}, merge=True)

    if caption and wiki_uids:
        source_id = f"photo-{doc.id}"
        shot_type = str(attributes.get(photo_attrs.SHOT_TYPE_FIELD, "") or "")
        match = ""
        if shot_type != "group":
            try:
                refs = deep_dive_images.reference_embeddings_for(db, uid)
                match = deep_dive_images.classify_face_match(embedding, refs)
            except Exception:  # noqa: BLE001
                match = ""
        text = caption_turn_text(caption, shot_type=shot_type, match=match)
        turn = [Turn(ROLE_USER, text)]
        for wuid in wiki_uids:
            try:
                persist_raw_turns(db, wuid, source_id, turn)
                await wiki_ingest(
                    db, wuid, source_id, turn,
                    force_visibility=wiki_visibility,
                )
            except Exception:  # noqa: BLE001
                logger.exception("photo caption ingest failed for %s", wuid)

    return {
        "media_id": doc.id,
        "moderation_status": STATUS_APPROVED,
        "published": True,
        "reason": "",
        "attributes": attributes,
        "caption": caption,
        "embedding": list(embedding),
    }
