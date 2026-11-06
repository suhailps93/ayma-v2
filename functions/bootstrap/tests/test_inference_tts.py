"""LiveKit Inference TTS over the gateway's ``/tts`` websocket (``inference_tts``).

A scripted in-process websocket server stands in for the gateway: it
asserts the plugin-identical message flow (``session.create`` →
``input_transcript`` → ``session.flush``), the Bearer auth, and the model
query param — then answers with ``output_audio`` frames + ``done``. Nothing
here touches the network beyond loopback.
"""

from __future__ import annotations

import asyncio
import base64
import dataclasses
import json
import wave

import pytest

import inference_tts
from config import CONFIG

_PCM = bytes(range(256)) * 4  # 1024 bytes of aqueous nonsense


def _wav_frames(payload: bytes) -> tuple[bytes, int]:
    import io

    with wave.open(io.BytesIO(payload), "rb") as w:
        assert w.getnchannels() == 1
        assert w.getsampwidth() == 2
        return w.readframes(w.getnframes()), w.getframerate()


def _scripted_server(*, script, seen):
    from websockets.asyncio.server import serve

    async def _handler(ws):
        seen["auth"] = ws.request.headers.get("Authorization", "")
        seen["path"] = ws.request.path
        creates, transcripts, flushes = [], [], []
        for raw in script.get("expect", []):
            msg = await ws.recv()
            data = json.loads(msg)
            if data["type"] == "session.create":
                creates.append(data)
            elif data["type"] == "input_transcript":
                transcripts.append(data)
            elif data["type"] == "session.flush":
                flushes.append(data)
        seen["creates"] = creates
        seen["transcripts"] = transcripts
        seen["flushes"] = flushes
        for reply in script.get("replies", []):
            if reply == "<sleep>":
                await asyncio.sleep(1.0)
            else:
                await ws.send(json.dumps(reply))

    return serve(_handler, "127.0.0.1", 0)


def _run(coro_factory, monkeypatch, *, script, port_holder=None):
    async def _main():
        from websockets.asyncio.server import ServerConnection  # noqa: F401

        seen: dict = {}
        server = await _scripted_server(script=script, seen=seen)
        port = server.sockets[0].getsockname()[1]
        if port_holder is not None:
            port_holder.append(port)
        monkeypatch.setattr(
            inference_tts, "CONFIG", dataclasses.replace(
                inference_tts.CONFIG,
                livekit_inference_url=f"http://127.0.0.1:{port}/v1",
            ),
        )
        monkeypatch.setenv("LIVEKIT_API_KEY", "test-key")
        monkeypatch.setenv("LIVEKIT_API_SECRET", "test-secret")
        try:
            return seen, await coro_factory()
        finally:
            server.close()
            await server.wait_closed()

    return asyncio.run(_main())


_EXPECT = ["create", "transcript", "flush"]


def test_synthesize_returns_spoken_wav(monkeypatch):
    seen, payload = _run(
        lambda: inference_tts.synthesize(
            "hello there", model="fishaudio/s2.1-pro", voice="Hannah"
        ),
        monkeypatch,
        script={
            "expect": _EXPECT,
            "replies": [
                {"type": "session.created", "session_id": "s1"},
                {"type": "output_audio", "audio": base64.b64encode(_PCM[:512]).decode()},
                {"type": "output_audio", "audio": base64.b64encode(_PCM[512:]).decode()},
                {"type": "output_alignment", "words": []},
                {"type": "done"},
            ],
        },
    )
    assert seen["auth"].startswith("Bearer ") and len(seen["auth"]) > 20
    assert seen["path"] == "/v1/tts?model=fishaudio%2Fs2.1-pro"
    create = seen["creates"][0]
    assert create["sample_rate"] == "24000"
    assert create["encoding"] == "pcm_s16le"
    assert create["voice"] == "Hannah"
    assert create["model"] == "fishaudio/s2.1-pro"
    assert seen["transcripts"][0]["transcript"] == "hello there"
    assert seen["flushes"]
    pcm, rate = _wav_frames(payload)
    assert pcm == _PCM
    assert rate == 24000


def test_synthesize_uses_config_defaults(monkeypatch):
    # Applied inside _run's replaced CONFIG via the live model default: the
    # point is the no-arg path reads config, asserted through the request.
    monkeypatch.setattr(
        inference_tts, "CONFIG", dataclasses.replace(
            CONFIG,
            async_voice_tts_model="inworld/inworld-tts-1",
            async_voice_tts_voice="",
        ),
    )
    seen, _ = _run(
        lambda: inference_tts.synthesize("hi"),
        monkeypatch,
        script={
            "expect": _EXPECT,
            "replies": [
                {"type": "output_audio",
                 "audio": base64.b64encode(b"\x00\x01").decode()},
                {"type": "done"},
            ],
        },
    )
    assert seen["path"] == "/v1/tts?model=inworld%2Finworld-tts-1"
    assert "voice" not in seen["creates"][0]
    assert seen["creates"][0]["model"] == "inworld/inworld-tts-1"


def test_gateway_error_raises(monkeypatch):
    with pytest.raises(inference_tts.InferenceTTSError, match="rate_limited"):
        _run(
            lambda: inference_tts.synthesize("hi"),
            monkeypatch,
            script={
                "expect": _EXPECT,
                "replies": [{"type": "error", "message": "rate_limited"}],
            },
        )


def test_empty_synthesis_raises(monkeypatch):
    with pytest.raises(inference_tts.InferenceTTSError, match="no audio"):
        _run(
            lambda: inference_tts.synthesize("hi"),
            monkeypatch,
            script={"expect": _EXPECT, "replies": [{"type": "done"}]},
        )


def test_empty_text_raises_without_connecting(monkeypatch):
    with pytest.raises(inference_tts.InferenceTTSError, match="empty text"):
        asyncio.run(inference_tts.synthesize("   "))


def test_timeout_raises(monkeypatch):
    with pytest.raises(inference_tts.InferenceTTSError, match="timed out"):
        _run(
            lambda: inference_tts.synthesize("hi", timeout=0.2),
            monkeypatch,
            script={"expect": _EXPECT, "replies": ["<sleep>"]},
        )


def test_pcm_to_wav_shape():
    payload = inference_tts.pcm_to_wav(b"\x01\x02\x03\x04")
    pcm, rate = _wav_frames(payload)
    assert pcm == b"\x01\x02\x03\x04"
    assert rate == 24000
