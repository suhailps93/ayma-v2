"""DM message → wiki ingestion (ARCHITECTURE.md §6.8, §6.11 step 10).

Every DM message becomes a ``raw_turns`` entry for *both* participants. Photos
get a vision caption, voice notes get transcribed; both become text the
standard ingest pipeline processes. Wiki content derived from DM images / voice
defaults to ``visibility: ai_only`` — the user already holds the raw content in
their thread. Face-embedding still runs on DM images (§2.5).
"""

from __future__ import annotations

import logging

import gemini
import media_embed
import photo_pipeline
from post_turn import persist_raw_turns
from transcript import ROLE_USER, Turn
from wiki_ingest import ingest as wiki_ingest

logger = logging.getLogger("ayma.dm")

_CAPTION_SCHEMA = {
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"],
}


async def _photo_caption(image: bytes, mime: str) -> str:
    result = await gemini.generate_json(
        "Caption what this photo shows in one or two plain sentences.",
        system_prompt="You describe images factually and briefly.",
        response_schema=_CAPTION_SCHEMA,
        image=(image, mime),
    )
    return (result or {}).get("text", "").strip() if isinstance(result, dict) else ""


async def _voice_transcript(audio: bytes, mime: str) -> str:
    result = await gemini.generate_json(
        "Transcribe this voice message verbatim.",
        system_prompt="You transcribe audio accurately.",
        response_schema=_CAPTION_SCHEMA,
        image=(audio, mime),  # generate_json's part builder handles any media
    )
    return (result or {}).get("text", "").strip() if isinstance(result, dict) else ""


async def _message_text(db, sender_uid: str, msg_type: str, body: str) -> str:
    if msg_type == "text":
        return body.strip()
    if msg_type == "photo":
        # Full §8.5 pipeline: moderation → embed → attributes → caption. A
        # flagged image returns no caption, so nothing enters the wiki.
        try:
            result = await photo_pipeline.process(
                db, sender_uid, body, "dm"
            )
        except Exception:  # noqa: BLE001
            logger.exception("DM photo pipeline failed for %s", body)
            return ""
        return result.get("caption", "") if result.get("published") else ""
    if msg_type == "voice":
        try:
            data, mime = await _to_thread(media_embed.download_bytes, body)
        except Exception:  # noqa: BLE001
            logger.exception("could not fetch DM voice %s", body)
            return ""
        return await _voice_transcript(data, mime)
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
) -> None:
    """Best-effort: raw_turns for both participants + a wiki pass for both."""
    text = await _message_text(db, sender_uid, msg_type, body)
    if not text:
        return

    force = "ai_only" if msg_type in ("photo", "voice") else None
    source_id = f"dm-{thread_id}-{message_id}"
    turn = [Turn(ROLE_USER, text)]

    for uid in (sender_uid, other_uid):
        try:
            persist_raw_turns(db, uid, source_id, turn)
            await wiki_ingest(db, uid, source_id, turn, force_visibility=force)
        except Exception:  # noqa: BLE001
            logger.exception("DM ingest failed for %s", uid)
