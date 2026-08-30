"""Agent worker wiring checks (Step 13).

The live audio round-trip (worker joins a LiveKit room, audio flows both ways
with Gemini Live) needs a real-time client and is verified manually per the
PLAN Step 13 test line. These checks cover only what can run offline: that the
worker is importable, its entrypoint is async, and the Gemini Live model id +
voice come from ``config.py`` rather than a hardcoded literal (AGENTS.md).

Skipped unless the agent dependency set (``requirements-agent.txt``) is
installed — the Main API venv deliberately does not carry it.
"""

import dataclasses
import inspect
import json

import pytest

pytest.importorskip("livekit.agents")
pytest.importorskip("livekit.plugins.google.realtime")

import agent  # noqa: E402
from config import CONFIG  # noqa: E402


def test_entrypoint_is_async():
    assert inspect.iscoroutinefunction(agent.entrypoint)


def test_realtime_model_uses_config_model_id(monkeypatch):
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model()

    assert captured["model"] == CONFIG.gemini_live_model
    assert captured["voice"] == CONFIG.gemini_live_voice


def test_realtime_model_enables_both_transcriptions(monkeypatch):
    from google.genai import types

    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model()

    assert isinstance(
        captured["input_audio_transcription"], types.AudioTranscriptionConfig
    )
    assert isinstance(
        captured["output_audio_transcription"], types.AudioTranscriptionConfig
    )


def test_relay_transcripts_publishes_named_data_events():
    import asyncio

    handlers = {}
    published = []

    class _FakeSession:
        def on(self, name):
            def _register(fn):
                handlers[name] = fn
                return fn

            return _register

    class _FakeLocalParticipant:
        async def publish_data(self, payload, *, reliable, topic):
            published.append((topic, json.loads(payload), reliable))

    class _FakeRoom:
        local_participant = _FakeLocalParticipant()

    class _FakeCtx:
        room = _FakeRoom()

    class _Item:
        role = "assistant"
        text_content = "hello there"

    class _UserEv:
        transcript = "hi ayma"
        is_final = True

    class _ItemEv:
        item = _Item()

    async def _run():
        agent.relay_transcripts(_FakeCtx(), _FakeSession())
        handlers["user_input_transcribed"](_UserEv())
        handlers["conversation_item_added"](_ItemEv())
        await asyncio.sleep(0.05)  # let the fire-and-forget tasks run

    asyncio.run(_run())

    topics = {t for t, _, _ in published}
    assert topics == {"user_transcript", "agent_transcript"}
    user = next(p for t, p, _ in published if t == "user_transcript")
    assert user == {"text": "hi ayma", "is_final": True}


def test_realtime_model_vertex_auth_toggles_with_config(monkeypatch):
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)

    monkeypatch.setattr(
        agent,
        "CONFIG",
        dataclasses.replace(
            CONFIG, use_vertex=True, vertex_location="us-central1"
        ),
    )
    agent.build_realtime_model()
    assert captured.get("vertexai") is True
    assert captured.get("location") == "us-central1"

    captured.clear()
    monkeypatch.setattr(
        agent, "CONFIG", dataclasses.replace(CONFIG, use_vertex=False)
    )
    agent.build_realtime_model()
    assert "vertexai" not in captured


def test_worker_options_binds_cloud_run_port(monkeypatch):
    monkeypatch.setenv("PORT", "8080")
    opts = agent.worker_options()
    assert opts.port == 8080
