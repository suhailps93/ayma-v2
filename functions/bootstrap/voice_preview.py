"""Cached Gemini TTS previews for the voice-preset picker (ARCHITECTURE §13.3).

One short spoken sample per built-in voice preset ("Hi, I'm Ayma…") so a user
can hear a preset before choosing it. Generated on first request and then cached
forever in the app's Storage bucket at ``voice_previews/{voice_name}.wav`` —
cheap: at most one Gemini TTS call per preset, ever.

The sample script lives in ``prompts/voice_preview.txt`` (AGENTS.md — no
prompt/script text inline in code); the TTS model id comes only from
``config.py`` (AGENTS.md).
"""

from __future__ import annotations

import asyncio
import io
import logging
import uuid
import wave
from functools import lru_cache
from pathlib import Path
from urllib.parse import quote

from google.genai import types

import gemini
import voices
from config import CONFIG

logger = logging.getLogger("ayma.voice_preview")

_PROMPT_PATH = Path(__file__).parent / "prompts" / "voice_preview.txt"
_STORAGE_PREFIX = "voice_previews"

# Gemini TTS returns single-channel signed-16-bit little-endian PCM at 24 kHz;
# it needs a WAV container to be playable in the app.
_PCM_RATE = 24_000
_PCM_CHANNELS = 1
_PCM_SAMPLE_WIDTH = 2  # bytes (16-bit)


@lru_cache(maxsize=1)
def preview_script() -> str:
    """The fixed sample line, loaded from ``prompts/voice_preview.txt``."""
    text = _PROMPT_PATH.read_text(encoding="utf-8").strip()
    if not text:
        raise RuntimeError(f"empty voice preview script at {_PROMPT_PATH}")
    return text


def _rate_from_mime(mime: str | None) -> int:
    """Pull the sample rate out of a ``audio/L16;codec=pcm;rate=24000`` mime,
    falling back to the documented 24 kHz."""
    for part in (mime or "").split(";"):
        part = part.strip()
        if part.startswith("rate="):
            try:
                return int(part[len("rate=") :])
            except ValueError:
                break
    return _PCM_RATE


def _pcm_to_wav(pcm: bytes, rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(_PCM_CHANNELS)
        wav.setsampwidth(_PCM_SAMPLE_WIDTH)
        wav.setframerate(rate)
        wav.writeframes(pcm)
    return buf.getvalue()


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
    """Run the Gemini TTS model for ``voice_name`` and return playable WAV
    bytes. Reuses ``gemini``'s Vertex/dev client + backed-off retry wrapper."""
    response = await gemini._generate(
        gemini._client(),
        model=CONFIG.gemini_tts_model,
        contents=preview_script(),
        config=types.GenerateContentConfig(
            response_modalities=["AUDIO"],
            speech_config=types.SpeechConfig(
                voice_config=types.VoiceConfig(
                    prebuilt_voice_config=types.PrebuiltVoiceConfig(
                        voice_name=voice_name
                    )
                )
            ),
        ),
    )
    try:
        inline = response.candidates[0].content.parts[0].inline_data
        audio = inline.data
    except (AttributeError, IndexError, TypeError) as exc:
        raise RuntimeError("Gemini TTS returned no audio part") from exc
    if not audio:
        raise RuntimeError("Gemini TTS returned empty audio")

    mime = (getattr(inline, "mime_type", "") or "").lower()
    if "wav" in mime:
        return audio
    return _pcm_to_wav(audio, _rate_from_mime(mime))


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
