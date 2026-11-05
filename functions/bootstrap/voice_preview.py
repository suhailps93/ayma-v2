"""Cached Gemini TTS previews for the voice-preset picker (ARCHITECTURE §13.3).

One short spoken sample per built-in voice preset ("Hi, I'm Ayma…") so a user
can hear a preset before choosing it. Generated on first request and then cached
forever in the app's Storage bucket at ``voice_previews/{voice_name}.wav``.

Generation is DISABLED (founder rule 2026-11-04 — see
``docs/DIRECT_GOOGLE_KILL_AUDIT.md`` item 5): TTS previews need the
direct-Google TTS model, which the LiveKit gateway does not serve.
:func:`preview_url` still serves already-cached clips; an uncached preset
fails honestly (the endpoint maps it to a 502).

The sample script lives in ``prompts/voice_preview.txt`` (AGENTS.md — no
prompt/script text inline in code); the TTS model id comes only from
``config.py`` (AGENTS.md).
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from urllib.parse import quote

import llm_routing
import voices
from config import CONFIG

logger = logging.getLogger("ayma.voice_preview")

_STORAGE_PREFIX = "voice_previews"


def _bucket():
    from firebase_admin import storage

    return storage.bucket(CONFIG.storage_bucket)


def _blob_for(voice_name: str):
    return _bucket().blob(f"{_STORAGE_PREFIX}/{voice_name}.wav")


def _download_url(blob) -> str:
    """A Firebase Storage download URL for ``blob``. Token-based, so it streams
    from a plain ``GET`` with no auth header — all the picker needs — and it is
    stable across future requests for the same cached object."""
    token = (blob.metadata or {}).get("firebaseStorageDownloadTokens")
    if not token:
        token = str(uuid.uuid4())
        blob.metadata = {
            **(blob.metadata or {}),
            "firebaseStorageDownloadTokens": token,
        }
        blob.patch()
    return (
        "https://firebasestorage.googleapis.com/v0/b/"
        f"{blob.bucket.name}/o/{quote(blob.name, safe='')}"
        f"?alt=media&token={token.split(',')[0]}"
    )


def _cached_url(voice_name: str) -> str | None:
    blob = _blob_for(voice_name)
    if not blob.exists():
        return None
    blob.reload()
    return _download_url(blob)


def _store(voice_name: str, wav_bytes: bytes) -> str:
    blob = _blob_for(voice_name)
    blob.metadata = {"firebaseStorageDownloadTokens": str(uuid.uuid4())}
    blob.upload_from_string(wav_bytes, content_type="audio/wav")
    return _download_url(blob)


async def _synthesize(voice_name: str) -> bytes:
    """DISABLED: generating a new TTS preview needs the direct-Google TTS
    model, which the LiveKit gateway does not serve. Raises instead of
    calling Google (cached clips still serve via :func:`preview_url`)."""
    raise llm_routing.DirectGoogleDisabledError(
        "voice preview generation is unavailable: TTS needs direct Google, "
        "which is disabled — all inference goes through LiveKit"
    )


async def preview_url(voice_name: str) -> str:
    """Return a download URL for ``voice_name``'s spoken sample, generating and
    caching it on first request. Raises ``ValueError`` for a name that is not a
    known preset (so it can't be used to spend tokens on arbitrary strings)."""
    if not voices.is_valid_voice(voice_name):
        raise ValueError(f"unknown voice preset: {voice_name!r}")

    cached = await asyncio.to_thread(_cached_url, voice_name)
    if cached:
        return cached

    wav_bytes = await _synthesize(voice_name)
    url = await asyncio.to_thread(_store, voice_name, wav_bytes)
    logger.info("generated voice preview for %s (%d bytes)", voice_name, len(wav_bytes))
    return url
