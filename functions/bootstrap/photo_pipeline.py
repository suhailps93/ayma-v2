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

import asyncio
import logging
from datetime import datetime, timezone
from pathlib import Path

from prompt import load_prompt_file
import biometric_consent
import deep_dive
import face_match
import gemini
import media_embed
import photo_attrs
import photo_moderation
import schema
import token_ledger
from post_turn import persist_raw_turns
from transcript import ROLE_USER, Turn
from wiki_ingest import ingest as wiki_ingest

logger = logging.getLogger("ayma.media")

_CAPTION_SCHEMA = {
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"],
}

_PROMPT_PATH = Path(__file__).with_name("prompts") / "photo_context_note.md"

# How each source reads in the composer's "where it came from" line — kept
# short and human, not the raw ``source`` value the rest of the pipeline uses.
_SOURCE_LABELS = {
    "profile": "added to their profile",
    "chat": "shared in chat with Ayma",
    "dm": "sent in a DM",
}

# Canonical values live in schema.py so photo_ops can gate the grid on the
# same constant it's written with.
STATUS_APPROVED = schema.MEDIA_STATUS_APPROVED
STATUS_FLAGGED = schema.MEDIA_STATUS_FLAGGED


async def _caption(
    image: bytes,
    mime: str,
    *,
    name: str = "",
    match: str = "",
    source: str = "",
    accompanying_text: str = "",
    uid: str | None = None,
) -> str:
    """A short, natural note for this photo's private gallery entry (also
    what gets folded into the wiki narrative, via :func:`caption_turn_text`).

    Name-and-context-aware, not a blind visual description: when ``match``
    confirms this is the account owner, the composer is told their ``name``
    and whatever ``accompanying_text``/``source`` context is available, and
    is instructed to write like the person describing their own photo rather
    than cataloguing what's in the frame. Falls back to a plain factual
    description — the genuinely blind case — whenever identity isn't
    confirmed or there's simply nothing else to go on.
    """
    lines: list[str] = []
    if match == "self" and name:
        lines.append(f"Confirmed identity: this is {name}, the account owner.")
    elif match == "not_self":
        lines.append(
            "Identity: confirmed NOT to be the account owner — do not name "
            "anyone or assume who this is."
        )
    else:
        lines.append(
            "Identity: not confirmed — no reliable match to compare against, "
            "so do not name or guess who this is."
        )
    label = _SOURCE_LABELS.get(source, "")
    if label:
        lines.append(f"Source: {label}.")
    text = (accompanying_text or "").strip()
    if text:
        lines.append(f'What they said when sharing it: "{text}"')
    lines.append("Write the private photo-log note for this photo now.")

    try:
        result = await gemini.generate_json(
            "\n".join(lines),
            system_prompt=load_prompt_file(_PROMPT_PATH),
            response_schema=_CAPTION_SCHEMA,
            image=(image, mime),
            uid=uid,
            feature=token_ledger.FEATURE_PHOTO_CAPTION,
            enforce_cap=False,
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


async def _enrich(
    db,
    uid: str,
    media_id: str,
    image: bytes,
    mime: str,
    source: str,
    storage_path: str,
    *,
    face_verdict: str = "",
    attributes: dict,
    wiki_uids: list[str] | None,
    wiki_visibility: str | None,
    accompanying_text: str,
    embedding: list[float] | None = None,
) -> str:
    """Caption the photo and fold it into the gallery note and the wiki, for an
    already-stored, approved photo. Reuses the face-match verdict and attributes already
    computed. Runs inline for chat/DM and off the request path as a background task for
    profile uploads. Never raises — a failure here must not undo a stored, approved
    photo. Returns the caption (``""`` if none)."""
    try:
        shot_type = str((attributes or {}).get(photo_attrs.SHOT_TYPE_FIELD, "") or "")
        match = ""
        if shot_type != "group":
            match = face_verdict or ""

        name = ""
        if match == "self":
            try:
                name = deep_dive.profile_full_name(db, uid)
            except Exception:  # noqa: BLE001
                name = ""

        caption = await _caption(
            image, mime,
            name=name, match=match, source=source,
            accompanying_text=accompanying_text,
            uid=uid,
        )
        if not caption:
            return ""

        _media_col(db, uid).document(media_id).set(
            {"caption": caption}, merge=True
        )

        # Fold the caption into this photo's own gallery note (§ photo_notes
        # ``context``) — additive to, and independent of, the wiki fold below.
        # Best-effort; never lets a note-write problem fail the enrichment.
        try:
            import photo_notes
            import public_profile

            url = public_profile._photo_url(storage_path)
            if url:
                is_user_val = "yes" if match == "self" else ("no" if match == "not_self" else "")
                photo_notes.set_context(db, uid, url, context=caption, is_user=is_user_val)
        except Exception:  # noqa: BLE001
            logger.warning(
                "photo_pipeline: gallery note update failed for %s/%s",
                uid, storage_path, exc_info=True,
            )

        if wiki_uids:
            source_id = f"photo-{media_id}"
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

        return caption
    except Exception:  # noqa: BLE001
        logger.exception(
            "photo_pipeline: enrichment failed for %s/%s", uid, media_id
        )
        return ""


async def process(
    db,
    uid: str,
    storage_path: str,
    source: str,
    *,
    wiki_uids: list[str] | None = None,
    wiki_visibility: str | None = None,
    accompanying_text: str = "",
    background=None,
    defer_enrichment: bool = False,
) -> dict:
    """Run the full pipeline for one image. Returns a status dict:
    ``{media_id, moderation_status, published, reason, attributes, caption,
    embedding}`` — ``embedding`` is the already-computed face-embedding
    vector (``None`` on a moderation reject), passed to
    ``auto_analysis.analyse_photo`` by every caller so it never has to
    re-derive it.

    ``accompanying_text`` is whatever the user typed alongside this photo
    (a chat message sent with it, a DM caption) — may be empty, and always is
    for a profile-grid upload (nothing is "said" when adding one). Folded
    into the caption composer below; never required.

    Moderation always blocks (the safety gate — a flagged photo stops here and
    is never embedded or published). When ``defer_enrichment`` is set and a
    FastAPI ``background`` tasks object is supplied, the captioning + gallery
    note + wiki fold run *after* the response instead of on the request path:
    the approved photo, its embedding and its attributes are all persisted
    synchronously first (so the grid add and the Appearance pipeline see them),
    only the caption-dependent enrichment is deferred. Callers that need the
    caption available immediately (chat/DM, so Ayma can reference the photo in
    the same turn) leave ``defer_enrichment`` off and get it inline.
    """
    now = datetime.now(timezone.utc)
    image, mime = media_embed.download_bytes(storage_path)

    verdict = await photo_moderation.moderate(image, mime, uid=uid)
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

    # Attribute extraction (non-fatal, degrades gracefully to blank attributes).
    try:
        attributes = await photo_attrs.extract_attributes(image, mime, uid=uid)
    except Exception:
        logger.warning(
            "photo_pipeline: attribute extraction failed for %s; continuing with blank attributes",
            uid,
            exc_info=True,
        )
        attributes = photo_attrs._blank()

    # Face match upload check (founder requirement Nov 8, 2026):
    # Compares the new picture against the comparison set on the SAME account
    # (verification selfie plus pictures already uploaded on that account).
    # Stored on the image record as per-image context Ayma can see.
    face_verdict = "unknown"
    if biometric_consent.has_consent_fresh(db, uid):
        try:
            check_res = await face_match.classify_photo(
                db, uid, (image, mime), cand_path=storage_path
            )
            face_verdict = check_res.get("verdict") or "unknown"
        except Exception:
            logger.warning("photo_pipeline: face check failed for %s", uid, exc_info=True)
            face_verdict = "unknown"

    is_user_val = "yes" if face_verdict == "self" else ("no" if face_verdict == "not_self" else "")

    doc = _media_col(db, uid).document()
    doc_payload = {
        "storage_path": storage_path,
        "source": source,
        "moderation_status": STATUS_APPROVED,
        "moderation_reason": "",
        "attributes": attributes,
        "face_verdict": face_verdict,
        "is_user": is_user_val,
        "created_at": now,
    }
    doc.set(doc_payload)

    if source == "profile":
        db.collection("users").document(uid).collection("profile").document(
            "main"
        ).set({"photo_attrs": attributes}, merge=True)

    enrich_args = (db, uid, doc.id, image, mime, source, storage_path)
    enrich_kwargs = dict(
        face_verdict=face_verdict,
        attributes=attributes,
        wiki_uids=wiki_uids,
        wiki_visibility=wiki_visibility,
        accompanying_text=accompanying_text,
    )

    if defer_enrichment and background is not None:
        # Caption + gallery note + wiki fold run after the response.
        background.add_task(_enrich, *enrich_args, **enrich_kwargs)
        caption = ""
    else:
        caption = await _enrich(*enrich_args, **enrich_kwargs)

    return {
        "media_id": doc.id,
        "moderation_status": STATUS_APPROVED,
        "published": True,
        "reason": "",
        "attributes": attributes,
        "caption": caption,
        "face_verdict": face_verdict,
        "is_user": is_user_val,
        "embedding": None,
        "embedding_missing": False,
    }
