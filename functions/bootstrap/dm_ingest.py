"""DM message → wiki ingestion (ARCHITECTURE.md §6.8, §6.11 step 10).

Every DM message becomes a ``raw_turns`` entry for *both* participants. Photos
get a vision caption, voice notes get transcribed; both become text the
standard ingest pipeline processes. Wiki content derived from DM images / voice
defaults to ``visibility: ai_only`` — the user already holds the raw content in
their thread. Face-embedding still runs on DM images (§2.5).
"""

from __future__ import annotations

import logging

import backfill_ops
import gemini
import media_embed
import photo_pipeline
import token_ledger
from post_turn import persist_raw_turns
from transcript import ROLE_USER, Turn
from wiki_ingest import ingest as wiki_ingest

logger = logging.getLogger("ayma.dm")

_CAPTION_SCHEMA = {
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"],
}


async def _photo_caption(image: bytes, mime: str, uid: str | None = None) -> str:
    result = await gemini.generate_json(
        "Caption what this photo shows in one or two plain sentences.",
        system_prompt="You describe images factually and briefly.",
        response_schema=_CAPTION_SCHEMA,
        image=(image, mime),
        uid=uid,
        feature=token_ledger.FEATURE_DM_INGEST,
        enforce_cap=False,
    )
    return (result or {}).get("text", "").strip() if isinstance(result, dict) else ""


async def _voice_transcript(audio: bytes, mime: str, uid: str | None = None) -> str:
    result = await gemini.generate_json(
        "Transcribe this voice message verbatim.",
        system_prompt="You transcribe audio accurately.",
        response_schema=_CAPTION_SCHEMA,
        image=(audio, mime),  # generate_json's part builder handles any media
        uid=uid,
        feature=token_ledger.FEATURE_DM_INGEST,
        enforce_cap=False,
    )
    return (result or {}).get("text", "").strip() if isinstance(result, dict) else ""


def _photo_match_verdict(db, sender_uid: str, result: dict) -> tuple[str, str]:
    """``(shot_type, match)`` for an already-run pipeline ``result`` — the
    same face-match verdict :func:`photo_pipeline.caption_turn_text` uses to
    phrase "of user" vs. "other" in the wiki turn. Best-effort; ``match`` is
    ``""`` (renders as the plain, unqualified phrasing) on any failure."""
    attrs = result.get("attributes") or {}
    shot_type = str(attrs.get("shot_type", "") or "")
    if shot_type == "group":
        return shot_type, ""
    match = result.get("face_verdict") or ""
    if match in ("self", "not_self"):
        return shot_type, match
    return shot_type, ""


async def _message_text(
    db,
    sender_uid: str,
    msg_type: str,
    body: str,
    attachment_path: str = "",
    *,
    pipeline_result: dict | None = None,
) -> str:
    if msg_type == "text":
        return body.strip()
    if msg_type in ("photo", "image"):
        # ``photo`` carries the path in ``body``; ``image`` carries it in
        # ``attachment_path`` and keeps ``body`` for an optional caption.
        path = attachment_path or body
        caption = body.strip() if msg_type == "image" else ""
        # Full §8.5 pipeline: moderation → embed → attributes → caption. A
        # flagged image returns no caption, so nothing enters the wiki.
        # ``pipeline_result`` lets a caller (``ingest_dm_message``) that
        # already ran the pipeline — to feed auto-analysis — hand the result
        # straight over instead of running it twice.
        result = pipeline_result
        if result is None:
            try:
                result = await photo_pipeline.process(
                    db, sender_uid, path, "dm", accompanying_text=caption,
                )
            except Exception:  # noqa: BLE001
                logger.exception("DM photo pipeline failed for %s", path)
                return caption
        if not result.get("published"):
            return caption
        vision = result.get("caption", "")
        if not vision:
            return caption
        shot_type, match = _photo_match_verdict(db, sender_uid, result)
        note = photo_pipeline.caption_turn_text(
            vision, shot_type=shot_type, match=match
        )
        if caption:
            return f"Shared an image (caption: {caption}). {note}"
        return note
    if msg_type == "voice":
        try:
            data, mime = await _to_thread(media_embed.download_bytes, body)
        except Exception:  # noqa: BLE001
            logger.exception("could not fetch DM voice %s", body)
            return ""
        return await _voice_transcript(data, mime, sender_uid)
    if msg_type == "file":
        # No content extraction for arbitrary files — keep the caption plus a
        # note that a file was shared, so Ayma at least knows it happened.
        caption = body.strip()
        return f"Shared a file (caption: {caption})." if caption else ""
    return ""  # shared_profile etc. — nothing to ingest


async def _to_thread(fn, *args):
    import asyncio

    return await asyncio.to_thread(fn, *args)


async def ingest_dm_message(
    db,
    thread_id: str,
    message_id: str,
    sender_uid: str,
    other_uid: str,
    msg_type: str,
    body: str,
    attachment_path: str = "",
) -> None:
    """Best-effort: raw_turns for both participants + a wiki pass for both."""
    photo_path = attachment_path or body if msg_type == "image" else body
    # ``photo`` carries the path in ``body`` (no caption slot); ``image``
    # carries the path in ``attachment_path`` and keeps ``body`` free for an
    # optional caption typed alongside it — same split ``_message_text`` uses.
    photo_caption = body.strip() if msg_type == "image" else ""
    pipeline_result: dict | None = None
    if msg_type in ("photo", "image") and photo_path:
        # Full §8.5 pipeline — moderation → embed → attributes → caption —
        # run once here so both auto-analysis and the wiki-caption fold below
        # reuse the same embedding/attributes/caption instead of each
        # re-deriving them.
        try:
            pipeline_result = await photo_pipeline.process(
                db, sender_uid, photo_path, "dm", accompanying_text=photo_caption,
            )
        except Exception:  # noqa: BLE001
            logger.exception("DM photo pipeline failed for %s", photo_path)
            pipeline_result = None
        # Auto-analysis (§ auto analysis): the sender's own photo -> face/body
        # read into the sender's private skill-memory pages. Only the account
        # owner is ever analysed, never the other participant. Never raises.
        try:
            import auto_analysis

            await auto_analysis.analyse_photo(
                db, sender_uid, photo_path,
                embedding=(pipeline_result or {}).get("embedding"),
                attributes=(pipeline_result or {}).get("attributes"),
            )
        except Exception:  # noqa: BLE001
            logger.exception("DM auto-analysis failed for %s", sender_uid)

    text = await _message_text(
        db, sender_uid, msg_type, body, attachment_path,
        pipeline_result=pipeline_result,
    )
    if not text:
        return

    force = "ai_only" if msg_type in ("photo", "voice", "image") else None
    source_id = f"dm-{thread_id}-{message_id}"
    turn = [Turn(ROLE_USER, text)]

    for uid in (sender_uid, other_uid):
        try:
            persist_raw_turns(db, uid, source_id, turn)
            await wiki_ingest(db, uid, source_id, turn, force_visibility=force)
        except token_ledger.TokenCapExceeded:
            # Out of credits — re-ingest this DM on a later top-up / the
            # nightly sweep (§15).
            backfill_ops.mark_pending(db, uid, source_id)
        except Exception:  # noqa: BLE001
            logger.exception("DM ingest failed for %s", uid)
