"""Cached voice previews for the voice picker (ARCHITECTURE §13.3).

One short spoken sample ("Hi, I'm Ayma…") per voice the app offers, so a user
can hear a voice before choosing it. Clips live in the app's Storage bucket at
``voice_previews/{voice_id}.wav`` and are served from cache only.

In-request generation is DISABLED (founder rule 2026-11-04 — see
``docs/DIRECT_GOOGLE_KILL_AUDIT.md`` item 5): the old Gemini TTS path needed
the direct-Google model, which the LiveKit gateway does not serve. The
preview LIBRARY is built out of band instead: the built-in Gemini presets'
clips were recorded once, and every other catalog voice (the cascade TTS
providers) is synthesized by ``scripts/generate_voice_previews.py`` through
the LiveKit Inference route ONLY and uploaded to the same prefix. A catalog
voice with no clip yet raises :class:`PreviewNotRecordedError` — the picker
shows its honest "no preview recorded" state rather than a wrong sample.

The sample script lives in ``prompts/voice_preview.txt`` (AGENTS.md — no
prompt/script text inline in code); model ids come only from ``config.py``
and the voice catalog (AGENTS.md).
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


class PreviewNotRecordedError(LookupError):
    """A real catalog voice with no recorded sample in the library yet.
    Distinct from an unknown voice (``ValueError``) and from a storage
    failure, so the endpoint can answer an honest 404 for it."""


def is_previewable_voice(voice_id: str) -> bool:
    """True when a preview can ever exist for ``voice_id``: a built-in Gemini
    preset, or a named voice in the voice catalog
    (:func:`voice_catalog.find_catalog_voice`)."""
    if voices.is_valid_voice(voice_id):
        return True
    import voice_catalog

    return voice_catalog.find_catalog_voice(voice_id) is not None


async def preview_url(voice_name: str) -> str:
    """Return a download URL for ``voice_name``'s spoken sample, from the
    cached library. Raises ``ValueError`` for a name that is not a known
    voice (so it can't be used to spend tokens on arbitrary strings) and
    :class:`PreviewNotRecordedError` for a catalog voice whose clip has not
    been recorded yet. Uncached Gemini presets still route to the DISABLED
    :func:`_synthesize`, which fails honestly."""
    if voices.is_valid_voice(voice_name):
        cached = await asyncio.to_thread(_cached_url, voice_name)
        if cached:
            return cached
        wav_bytes = await _synthesize(voice_name)
        url = await asyncio.to_thread(_store, voice_name, wav_bytes)
        logger.info(
            "generated voice preview for %s (%d bytes)", voice_name, len(wav_bytes)
        )
        return url

    import voice_catalog

    if voice_catalog.find_catalog_voice(voice_name) is None:
        raise ValueError(f"unknown voice: {voice_name!r}")
    cached = await asyncio.to_thread(_cached_url, voice_name)
    if cached:
        return cached
    raise PreviewNotRecordedError(voice_name)
