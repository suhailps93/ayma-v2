"""Cached voice previews for the "Ayma's models" stack picker (ARCHITECTURE
§13.3, §13.9).

One short spoken sample per selectable voice ("Hi, I'm Ayma…") so a user can
hear a voice before saving it. Covers the **current** voice catalog the stack
picker offers, not just the old Gemini presets:

* **Gemini Live realtime voices** (the ``voices.VOICE_PRESETS`` names) are
  synthesized with the Gemini TTS model (``config.gemini_tts_model``), the same
  model the hot-swappable Gemini Live voice uses.
* **Cascade TTS voices** (every LiveKit-Inference TTS voice — e.g.
  ``fishaudio/s2.1-pro`` → Hannah, the post-Qloo default) are synthesized
  through ``livekit.agents.inference.TTS`` — the **same TTS path the live
  cascade call uses** (``agent.build_cascade_session``) — so the sample is the
  real voice, not a stand-in.

Samples are generated on first request and cached in the app's Storage bucket
(Gemini: ``voice_previews/{voice}.wav``; cascade:
``voice_previews/cascade/{tts}/{voice}.wav``) — at most one TTS call per
(stack, voice), ever.

OpenAI Realtime voices have no server-side synthesis path here (they are a
speech-to-speech model, not a TTS) and raise :class:`PreviewUnsupported`; the
provider is flag-gated off and inert without a key, so it is not offered in
practice — see the follow-up note in ``docs/TODO_QUEUE.md``.

The sample script lives in ``prompts/voice_preview.txt`` (AGENTS.md — no
prompt/script text inline in code); every model/voice id comes only from
``config.py`` / the live catalog (AGENTS.md).
"""

from __future__ import annotations

import asyncio
import io
import logging
import re
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

MODE_REALTIME = "realtime"
MODE_CASCADE = "cascade"

# Gemini TTS returns single-channel signed-16-bit little-endian PCM at 24 kHz;
# it needs a WAV container to be playable in the app.
_PCM_RATE = 24_000
_PCM_CHANNELS = 1
_PCM_SAMPLE_WIDTH = 2  # bytes (16-bit)


class PreviewUnsupported(Exception):
    """A selectable voice that has no server-side preview synthesis path (today
    only OpenAI Realtime voices). Surfaced to the client as a 422 so the picker
    shows a quiet "no sample for this voice" instead of a hard error."""


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


def _pcm_to_wav(pcm: bytes, rate: int, channels: int = _PCM_CHANNELS) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(_PCM_SAMPLE_WIDTH)
        wav.setframerate(rate)
        wav.writeframes(pcm)
    return buf.getvalue()


def _bucket():
    from firebase_admin import storage

    return storage.bucket(CONFIG.storage_bucket)


def _slug(text: str) -> str:
    """A storage-path-safe segment for a model id (``inworld/inworld-tts-1`` ->
    ``inworld_inworld-tts-1``)."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", text) or "default"


def _gemini_blob_name(voice_name: str) -> str:
    return f"{_STORAGE_PREFIX}/{voice_name}.wav"


def _cascade_blob_name(tts_id: str, voice_id: str) -> str:
    return f"{_STORAGE_PREFIX}/cascade/{_slug(tts_id)}/{_slug(voice_id or '_default')}.wav"


def _blob_for(name: str):
    return _bucket().blob(name)


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


def _cached_url(blob_name: str) -> str | None:
    blob = _blob_for(blob_name)
    if not blob.exists():
        return None
    blob.reload()
    return _download_url(blob)


def _store(blob_name: str, wav_bytes: bytes) -> str:
    blob = _blob_for(blob_name)
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


async def _synthesize_cascade(tts_id: str, voice_id: str) -> bytes:
    """Synthesize the sample line through ``livekit.agents.inference.TTS`` — the
    SAME path the live cascade call builds (``agent.build_cascade_session`` →
    ``inference.TTS(model=tts_id, voice=…)``), so the preview is the real voice.

    Authenticates against the LiveKit Inference gateway with the project's
    ``LIVEKIT_API_KEY``/``SECRET`` (already in the Cloud Run env); needs no
    running agent job. Returns playable WAV bytes."""
    from livekit.agents import inference

    kwargs: dict[str, object] = {"model": tts_id}
    if voice_id:
        kwargs["voice"] = voice_id
    tts = inference.TTS(**kwargs)
    try:
        frame = await tts.synthesize(preview_script()).collect()
    finally:
        await tts.aclose()
    wav = frame.to_wav_bytes()
    if not wav:
        raise RuntimeError("LiveKit TTS returned no audio")
    return wav


async def preview_url(
    voice_name: str,
    *,
    mode: str = MODE_REALTIME,
    tts_id: str = "",
    realtime_model_id: str = "",
) -> str:
    """A download URL for the spoken sample of the voice ``voice_name`` on the
    given stack, generated and cached on first request.

    ``mode`` selects the stack (``realtime``/``cascade``), matching the picker's
    selection; ``tts_id`` (cascade) / ``realtime_model_id`` (realtime) name the
    component the voice belongs to, so the right synthesis path is used and the
    voice is validated against the live catalog (an arbitrary string can't spend
    tokens). Raises ``ValueError`` for a voice/model not in the catalog and
    :class:`PreviewUnsupported` for a selectable voice with no server-side
    synthesis path (OpenAI Realtime)."""
    if (mode or MODE_REALTIME).strip() == MODE_CASCADE:
        return await _cascade_preview_url(tts_id.strip(), voice_name.strip())
    return await _realtime_preview_url(realtime_model_id.strip(), voice_name.strip())


async def _realtime_preview_url(realtime_model_id: str, voice_name: str) -> str:
    import voice_catalog

    model_id = realtime_model_id or voice_catalog.REALTIME_GEMINI
    if model_id != voice_catalog.REALTIME_GEMINI:
        # OpenAI Realtime (the only other realtime option) is a speech-to-speech
        # model, not a TTS we can sample server-side.
        raise PreviewUnsupported(f"no preview path for realtime model {model_id!r}")
    # The Gemini Live realtime voices ARE ``VOICE_PRESETS``; an empty pick means
    # the configured default voice.
    name = voice_name or CONFIG.gemini_live_voice
    if not voices.is_valid_voice(name):
        raise ValueError(f"unknown voice preset: {name!r}")

    blob_name = _gemini_blob_name(name)
    cached = await asyncio.to_thread(_cached_url, blob_name)
    if cached:
        return cached

    wav_bytes = await _synthesize(name)
    url = await asyncio.to_thread(_store, blob_name, wav_bytes)
    logger.info("generated Gemini voice preview for %s (%d bytes)", name, len(wav_bytes))
    return url


async def _cascade_preview_url(tts_id: str, voice_id: str) -> str:
    import voice_catalog

    if not tts_id or not voice_catalog.is_valid_tts(tts_id):
        raise ValueError(f"unknown cascade TTS model: {tts_id!r}")
    if voice_id and voice_id not in voice_catalog.tts_voice_ids(tts_id):
        raise ValueError(f"voice {voice_id!r} not available for TTS {tts_id!r}")

    blob_name = _cascade_blob_name(tts_id, voice_id)
    cached = await asyncio.to_thread(_cached_url, blob_name)
    if cached:
        return cached

    wav_bytes = await _synthesize_cascade(tts_id, voice_id)
    url = await asyncio.to_thread(_store, blob_name, wav_bytes)
    logger.info(
        "generated cascade voice preview for %s:%s (%d bytes)",
        tts_id,
        voice_id or "<default>",
        len(wav_bytes),
    )
    return url
