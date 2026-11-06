"""One-shot text-to-speech through the LiveKit Inference gateway.

This is the TTS leg of the async voice-message path (``async_voice.py``) —
and it speaks the SAME protocol as the TTS leg of a live voice call: the
gateway's ``/tts`` websocket endpoint, the same ``provider/model`` ids from
``config.py``, the same short-lived ``InferenceGrants`` JWT auth. The message
flow below mirrors ``livekit.agents.inference.TTS`` (livekit-agents 1.8.9,
the pinned agent stack — ``session.create`` → ``input_transcript`` →
``session.flush`` → ``output_audio`` frames → ``done``), minus the streaming
/ markup / fallback machinery a live call needs and a one-shot synthesis
does not.

Audio comes back as 16-bit mono PCM @ 24kHz (the plugin's defaults);
:func:`synthesize` wraps it in a WAV container so the stored reply clip
plays anywhere. A gateway ``error`` frame, an empty synthesis, or a
timeout raises :class:`InferenceTTSError` — the caller fails the job
honestly rather than delivering a silent clip.
"""

from __future__ import annotations

import asyncio
import base64
import io
import json
import logging
import wave
from urllib.parse import urlencode

import inference_llm
from config import CONFIG

logger = logging.getLogger("ayma.inference_tts")

# The plugin's TTS defaults (livekit-agents 1.8.9 inference/tts.py).
_SAMPLE_RATE = 24000
_ENCODING = "pcm_s16le"
_CHANNELS = 1
_SAMPLE_WIDTH = 2

_CONNECT_TIMEOUT_SECONDS = 10.0
# One frame bigger than this is never a legit TTS message.
_MAX_MESSAGE_BYTES = 8 * 1024 * 1024


class InferenceTTSError(RuntimeError):
    """The LiveKit Inference gateway refused or failed a TTS synthesis."""


def _ws_url(model: str) -> str:
    base = CONFIG.livekit_inference_url.rstrip("/")
    if base.startswith("http://"):
        base = "ws://" + base[len("http://"):]
    elif base.startswith("https://"):
        base = "wss://" + base[len("https://"):]
    return f"{base}/tts?{urlencode({'model': model})}"


def pcm_to_wav(pcm: bytes, sample_rate: int = _SAMPLE_RATE) -> bytes:
    """Wrap raw s16le mono PCM in a WAV container."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(_CHANNELS)
        w.setsampwidth(_SAMPLE_WIDTH)
        w.setframerate(sample_rate)
        w.writeframes(pcm)
    return buf.getvalue()


async def synthesize(
    text: str,
    *,
    model: str | None = None,
    voice: str | None = None,
    timeout: float | None = None,
) -> bytes:
    """Speak ``text`` through LiveKit Inference; return the reply as WAV bytes.

    ``model``/``voice`` default to the async-voice config (``config.py``;
    empty voice = the vendor default). ``timeout`` bounds the whole exchange
    (defaults to the shared Inference timeout). Raises
    :class:`InferenceTTSError` on any gateway failure.
    """
    text = (text or "").strip()
    if not text:
        raise InferenceTTSError("nothing to speak: empty text")
    model = model or CONFIG.async_voice_tts_model
    voice = voice if voice is not None else CONFIG.async_voice_tts_voice
    budget = timeout if timeout is not None else CONFIG.inference_timeout_seconds

    # Local import: `websockets` ships with the API image (requirements.txt)
    # but the module must stay importable where it isn't (agent venv tests).
    from websockets.asyncio.client import connect

    headers = {
        # Same grant the plugin mints (InferenceGrants perform=True) — the
        # shared minter already reads LIVEKIT_API_KEY/SECRET from the
        # environment at call time and never stores them.
        "Authorization": f"Bearer {inference_llm._mint_token()}",  # noqa: SLF001 - sibling module
    }
    url = _ws_url(model)
    session_create: dict = {
        "type": "session.create",
        "sample_rate": str(_SAMPLE_RATE),
        "encoding": _ENCODING,
        "extra": {},
        "model": model,
    }
    if voice:
        session_create["voice"] = voice
    generation_config: dict = {"model": model}
    if voice:
        generation_config["voice"] = voice

    async def _exchange() -> bytes:
        chunks: list[bytes] = []
        async with connect(
            url,
            additional_headers=headers,
            open_timeout=_CONNECT_TIMEOUT_SECONDS,
            max_size=_MAX_MESSAGE_BYTES,
        ) as ws:
            await ws.send(json.dumps(session_create))
            await ws.send(json.dumps({
                "type": "input_transcript",
                "transcript": text,
                "generation_config": generation_config,
                "extra": {},
            }))
            await ws.send(json.dumps({"type": "session.flush"}))
            while True:
                msg = await ws.recv()
                if isinstance(msg, bytes):
                    continue  # the gateway answers in JSON text frames
                try:
                    data = json.loads(msg)
                except ValueError:
                    continue
                mtype = data.get("type")
                if mtype == "output_audio":
                    try:
                        chunks.append(base64.b64decode(data.get("audio") or ""))
                    except ValueError:
                        continue
                elif mtype == "done":
                    break
                elif mtype == "error":
                    raise InferenceTTSError(
                        f"LiveKit Inference TTS error: {msg}"
                    )
                # session.created / output_alignment carry nothing a
                # one-shot synthesis needs.
        pcm = b"".join(chunks)
        if not pcm:
            raise InferenceTTSError(
                "LiveKit Inference TTS returned no audio"
            )
        return pcm_to_wav(pcm)

    try:
        return await asyncio.wait_for(_exchange(), timeout=budget)
    except asyncio.TimeoutError as exc:
        raise InferenceTTSError(
            f"LiveKit Inference TTS timed out after {budget:.0f}s"
        ) from exc
