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


def test_realtime_model_uses_a_valid_voice_preference(monkeypatch):
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model("Charon")
    assert captured["voice"] == "Charon"


def test_realtime_model_falls_back_for_an_unknown_voice(monkeypatch):
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model("NotARealPreset")
    assert captured["voice"] == CONFIG.gemini_live_voice


def test_room_seed_carries_the_voice_name():
    seed_json = json.dumps({
        "system_prompt": "p",
        "recent_turns": [],
        "uid": "u1",
        "session_id": "s1",
        "voice_name": "Zephyr",
    })

    class _Room:
        metadata = seed_json

    class _Ctx:
        room = _Room()

    assert agent._read_room_seed(_Ctx()).voice_name == "Zephyr"


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


def test_realtime_model_omits_context_compression_by_default(monkeypatch):
    """CONTEXT_OPT_LEVEL unset/0 = the exact pre-cost-program session config:
    no context_window_compression key at all."""
    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model()

    assert "context_window_compression" not in captured


def test_realtime_model_enables_sliding_window_compression_at_level_1(monkeypatch):
    """Phase 1 (cost program): with CONTEXT_OPT_LEVEL>=1 the Live session gets
    sliding-window context compression — trigger ~16k tokens, retained window
    ~8k — so the per-turn re-billed context stops growing unbounded."""
    from google.genai import types

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "1")
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model()

    cwc = captured["context_window_compression"]
    assert isinstance(cwc, types.ContextWindowCompressionConfig)
    assert cwc.trigger_tokens == 16000
    assert cwc.sliding_window.target_tokens == 8000


def test_compression_thresholds_are_env_tunable(monkeypatch):
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "1")
    monkeypatch.setenv("CONTEXT_OPT_VOICE_TRIGGER_TOKENS", "20000")
    monkeypatch.setenv("CONTEXT_OPT_VOICE_WINDOW_TOKENS", "10000")
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model()

    cwc = captured["context_window_compression"]
    assert cwc.trigger_tokens == 20000
    assert cwc.sliding_window.target_tokens == 10000


def test_compression_omitted_for_dev_api_3_1_preview(monkeypatch):
    """Root-cause fix (cost program 2026-09-26): even at CONTEXT_OPT_LEVEL>=1,
    the Dev-API `gemini-3.1-flash-live-preview` must NOT receive
    context_window_compression — it accepts but does not honor the sliding
    window (soft hint on audio; fatal 1007 on the text-seed path). Verified
    empirically against the live Dev API with the installed SDK."""
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "3")
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    monkeypatch.setattr(
        agent, "CONFIG",
        dataclasses.replace(
            CONFIG,
            gemini_live_use_dev_api=True,
            gemini_live_dev_model="gemini-3.1-flash-live-preview",
        ),
    )
    monkeypatch.setenv("GOOGLE_API_KEY", "test-key")
    agent.build_realtime_model()

    assert captured["model"] == "gemini-3.1-flash-live-preview"
    assert "context_window_compression" not in captured


def test_compression_present_for_compression_capable_model(monkeypatch):
    """The Vertex `gemini-live-2.5-flash-native-audio` launch model honors the
    sliding window, so compression stays ON there at level>=1 (guards against
    the model-aware gate over-reaching and disabling it everywhere)."""
    from google.genai import types

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "1")
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    monkeypatch.setattr(
        agent, "CONFIG",
        dataclasses.replace(
            CONFIG,
            gemini_live_use_dev_api=False,
            gemini_live_model="gemini-live-2.5-flash-native-audio",
        ),
    )
    agent.build_realtime_model()

    assert captured["model"] == "gemini-live-2.5-flash-native-audio"
    assert isinstance(
        captured["context_window_compression"],
        types.ContextWindowCompressionConfig,
    )


def test_compression_present_for_dev_api_3_8_live(monkeypatch):
    """`gemini-3.8-live` (the Dev-API default since the 2026-09-26 upgrade)
    DOES get context_window_compression at level>=1 — measured live against
    the real Dev API that day: per-turn prompt tokens sawtoothed 15,478 ->
    7,695 -> 15,593 -> 7,712 with trigger 16k / window 8k (a genuine, bounded
    eviction), and the text client-content path never closed with 1007."""
    from google.genai import types

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "1")
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    monkeypatch.setattr(
        agent, "CONFIG",
        dataclasses.replace(
            CONFIG,
            gemini_live_use_dev_api=True,
            gemini_live_dev_model="gemini-3.8-live",
        ),
    )
    monkeypatch.setenv("GOOGLE_API_KEY", "test-key")
    agent.build_realtime_model()

    assert captured["model"] == "gemini-3.8-live"
    cwc = captured["context_window_compression"]
    assert isinstance(cwc, types.ContextWindowCompressionConfig)
    assert cwc.trigger_tokens == 16000
    assert cwc.sliding_window.target_tokens == 8000


_TURN_DETECTION_ENVS = (
    "GEMINI_LIVE_TURN_DETECTION_TUNING",
    "GEMINI_LIVE_START_SENSITIVITY",
    "GEMINI_LIVE_END_SENSITIVITY",
    "GEMINI_LIVE_PREFIX_PADDING_MS",
    "GEMINI_LIVE_SILENCE_DURATION_MS",
)


def _clear_turn_detection_envs(monkeypatch):
    for name in _TURN_DETECTION_ENVS:
        monkeypatch.delenv(name, raising=False)


def test_realtime_model_tunes_server_turn_detection_by_default(monkeypatch):
    """Anti-false-trigger VAD tuning (2026-09-26): by default the session
    setup carries realtime_input_config with start sensitivity LOW, 300ms
    prefix padding, 700ms end-of-speech silence — and nothing else: no
    `disabled`, no `activity_handling` (barge-in must keep working), and end
    sensitivity left to the server default."""
    from google.genai import types

    _clear_turn_detection_envs(monkeypatch)
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model()

    ric = captured["realtime_input_config"]
    assert isinstance(ric, types.RealtimeInputConfig)
    assert ric.activity_handling is None
    assert ric.turn_coverage is None
    aad = ric.automatic_activity_detection
    assert aad.disabled is None  # server turn detection stays ON
    assert aad.start_of_speech_sensitivity == (
        types.StartSensitivity.START_SENSITIVITY_LOW
    )
    assert aad.end_of_speech_sensitivity is None
    assert aad.prefix_padding_ms == 300
    assert aad.silence_duration_ms == 700


def test_turn_detection_knobs_are_env_tunable(monkeypatch):
    from google.genai import types

    _clear_turn_detection_envs(monkeypatch)
    monkeypatch.setenv("GEMINI_LIVE_START_SENSITIVITY", "high")
    monkeypatch.setenv("GEMINI_LIVE_END_SENSITIVITY", "low")
    monkeypatch.setenv("GEMINI_LIVE_PREFIX_PADDING_MS", "150")
    monkeypatch.setenv("GEMINI_LIVE_SILENCE_DURATION_MS", "1000")
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model()

    aad = captured["realtime_input_config"].automatic_activity_detection
    assert aad.start_of_speech_sensitivity == (
        types.StartSensitivity.START_SENSITIVITY_HIGH
    )
    assert aad.end_of_speech_sensitivity == (
        types.EndSensitivity.END_SENSITIVITY_LOW
    )
    assert aad.prefix_padding_ms == 150
    assert aad.silence_duration_ms == 1000


def test_turn_detection_tuning_kill_switch(monkeypatch):
    """GEMINI_LIVE_TURN_DETECTION_TUNING=off restores the exact pre-tuning
    session config: no realtime_input_config key at all."""
    _clear_turn_detection_envs(monkeypatch)
    monkeypatch.setenv("GEMINI_LIVE_TURN_DETECTION_TUNING", "off")
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model()

    assert "realtime_input_config" not in captured


def test_turn_detection_all_defaults_sends_no_config(monkeypatch):
    """Every knob set to \"default\" leaves all fields unset — then no
    realtime_input_config is sent at all (same as the kill switch)."""
    _clear_turn_detection_envs(monkeypatch)
    monkeypatch.setenv("GEMINI_LIVE_START_SENSITIVITY", "default")
    monkeypatch.setenv("GEMINI_LIVE_END_SENSITIVITY", "default")
    monkeypatch.setenv("GEMINI_LIVE_PREFIX_PADDING_MS", "default")
    monkeypatch.setenv("GEMINI_LIVE_SILENCE_DURATION_MS", "default")
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model()

    assert "realtime_input_config" not in captured


def test_turn_detection_invalid_env_values_fall_back(monkeypatch):
    """Garbage env values must never take voice down: bad choice/int values
    fall back to the shipped defaults (with a warning), not raise."""
    from google.genai import types

    _clear_turn_detection_envs(monkeypatch)
    monkeypatch.setenv("GEMINI_LIVE_START_SENSITIVITY", "verylow")
    monkeypatch.setenv("GEMINI_LIVE_PREFIX_PADDING_MS", "abc")
    monkeypatch.setenv("GEMINI_LIVE_SILENCE_DURATION_MS", "-5")
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    agent.build_realtime_model()

    aad = captured["realtime_input_config"].automatic_activity_detection
    assert aad.start_of_speech_sensitivity == (
        types.StartSensitivity.START_SENSITIVITY_LOW
    )
    assert aad.prefix_padding_ms == 300
    assert aad.silence_duration_ms == 700


def test_realtime_model_omits_native_audio_flags_by_default(monkeypatch):
    """Both native-audio-only flags default OFF and must NOT be passed to the
    Live model — passing them takes voice down on the model we run."""
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    monkeypatch.setattr(
        agent, "CONFIG",
        dataclasses.replace(
            CONFIG, gemini_live_affective_dialog=False,
            gemini_live_proactivity=False,
        ),
    )
    agent.build_realtime_model()

    assert "enable_affective_dialog" not in captured
    assert "proactivity" not in captured


def test_realtime_model_passes_native_audio_flags_when_enabled(monkeypatch):
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    monkeypatch.setattr(
        agent, "CONFIG",
        dataclasses.replace(
            CONFIG, gemini_live_affective_dialog=True,
            gemini_live_proactivity=True,
        ),
    )
    agent.build_realtime_model()

    assert captured["enable_affective_dialog"] is True
    assert captured["proactivity"] is True


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


def test_relay_agent_state_publishes_speaking_state():
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
            published.append((topic, json.loads(payload)))

    class _FakeCtx:
        class room:  # noqa: N801
            local_participant = _FakeLocalParticipant()

    class _StateEv:
        def __init__(self, new_state):
            self.new_state = new_state

    async def _run():
        agent.relay_agent_state(_FakeCtx(), _FakeSession())
        handlers["agent_state_changed"](_StateEv("speaking"))
        handlers["agent_state_changed"](_StateEv("listening"))
        await asyncio.sleep(0.05)

    asyncio.run(_run())

    assert published == [
        ("agent_state", {"state": "speaking"}),
        ("agent_state", {"state": "listening"}),
    ]


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
            CONFIG, use_vertex=True, gemini_live_location="us-central1"
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


def test_realtime_model_dev_api_uses_the_dev_model_and_key(monkeypatch):
    captured = {}

    class _FakeRealtimeModel:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    monkeypatch.setattr(agent, "RealtimeModel", _FakeRealtimeModel)
    monkeypatch.setattr(
        agent,
        "CONFIG",
        dataclasses.replace(
            CONFIG, use_vertex=True, gemini_live_use_dev_api=True
        ),
    )
    monkeypatch.setenv("GOOGLE_API_KEY", "k-123")

    agent.build_realtime_model()
    assert captured["model"] == CONFIG.gemini_live_dev_model
    assert captured["api_key"] == "k-123"
    assert captured["vertexai"] is False
    assert "location" not in captured

    # missing key is a hard error, not a silent Vertex fallback
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    with pytest.raises(RuntimeError):
        agent.build_realtime_model()


def test_worker_options_binds_cloud_run_port(monkeypatch):
    monkeypatch.setenv("PORT", "8080")
    opts = agent.worker_options()
    assert opts.port == 8080


class _NullRoom:
    class local_participant:  # noqa: N801
        @staticmethod
        async def publish_data(*a, **k):
            pass


class _NullCtx:
    room = _NullRoom()


def test_session_tools_come_from_the_shared_registry():
    from livekit.agents import llm

    import skills
    from skills import app_control

    assert agent._session_tools(_NullCtx(), "") == []  # no uid -> no tools

    tools = agent._session_tools(_NullCtx(), "u1")
    # The shared text registry plus the voice-only screen-awareness tools.
    assert len(tools) == len(skills.all_skills()) + len(app_control.VOICE_SKILLS)
    assert all(llm.is_function_tool(t) for t in tools)


def test_voice_tools_include_recall_only_at_level_3(monkeypatch):
    """Cost-program Phase 3: the recall(topic) tool is registered on the Live
    voice session's tool set at CONTEXT_OPT_LEVEL>=3, and absent below."""
    def _names(tools):
        return {t.info.name for t in tools}

    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    assert "recall" not in _names(agent._session_tools(_NullCtx(), "u1"))

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "3")
    tools = agent._session_tools(_NullCtx(), "u1")
    assert "recall" in _names(tools)


# --- tool_used data-channel events (§1.7 step 3) --------------------------


def test_publish_tool_event_uses_the_working_and_settled_labels():
    import asyncio

    from tool_labels import tool_label, working_label

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            published.append((topic, json.loads(payload), reliable))

    class _Room:
        local_participant = _Participant()

    class _Ctx:
        room = _Room()

    async def _run():
        agent._publish_tool_event(_Ctx(), "start", "deep_dive")
        agent._publish_tool_event(_Ctx(), "end", "deep_dive")
        await asyncio.sleep(0.05)  # let the fire-and-forget tasks run

    asyncio.run(_run())

    assert published == [
        (
            "tool_used",
            {"name": "deep_dive", "label": working_label("deep_dive"), "phase": "start"},
            True,
        ),
        (
            "tool_used",
            {"name": "deep_dive", "label": tool_label("deep_dive"), "phase": "end"},
            True,
        ),
    ]


def test_publish_tool_event_swallows_a_publish_failure():
    import asyncio

    class _FailingParticipant:
        @staticmethod
        async def publish_data(*a, **k):
            raise RuntimeError("data channel closed")

    class _Room:
        local_participant = _FailingParticipant()

    class _Ctx:
        room = _Room()

    async def _run():
        agent._publish_tool_event(_Ctx(), "start", "deep_dive")
        await asyncio.sleep(0.05)

    asyncio.run(_run())  # must not raise


def test_session_tools_wire_every_tool_call_to_a_tool_used_event(monkeypatch):
    """agent._session_tools passes an on_call hook into
    skills.make_livekit_tools; verify it publishes a matching start/end
    tool_used event for whichever tool actually calls it — exercising the
    real wiring end to end without needing a live LiveKit tool invocation."""
    import asyncio

    import skills
    from tool_labels import tool_label, working_label

    captured = {}

    def _fake_make_livekit_tools(db, uid, *, on_call=None):
        captured["on_call"] = on_call
        return ["tool-stub"]

    monkeypatch.setattr(skills, "make_livekit_tools", _fake_make_livekit_tools)

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            published.append((topic, json.loads(payload)))

    class _Room:
        local_participant = _Participant()

    class _Ctx:
        room = _Room()

    tools = agent._session_tools(_Ctx(), "u1")
    assert tools == ["tool-stub"]
    on_call = captured["on_call"]
    assert on_call is not None

    async def _run():
        on_call("start", "record_feedback")
        on_call("end", "record_feedback")
        await asyncio.sleep(0.05)

    asyncio.run(_run())

    assert [p[1]["phase"] for p in published] == ["start", "end"]
    assert published[0][1] == {
        "name": "record_feedback",
        "label": working_label("record_feedback"),
        "phase": "start",
    }
    assert published[1][1] == {
        "name": "record_feedback",
        "label": tool_label("record_feedback"),
        "phase": "end",
    }


class _FakeRoom:
    def __init__(self, metadata):
        self.metadata = metadata


class _FakeCtx:
    def __init__(self, metadata):
        self.room = _FakeRoom(metadata)


def test_read_room_seed_builds_chat_ctx_and_ids():
    raw = json.dumps(
        {
            "system_prompt": "PERSONA + history",
            "uid": "u1",
            "session_id": "sess-abc",
            "recent_turns": [
                {"role": "user", "text": "started by voice"},
                {"role": "ayma", "text": "keep going"},
            ],
        }
    )
    seed = agent._read_room_seed(_FakeCtx(raw))

    assert seed.system_prompt == "PERSONA + history"
    assert seed.uid == "u1"
    assert seed.session_id == "sess-abc"
    assert [m.role for m in seed.chat_ctx.items] == ["user", "assistant"]
    assert [t.role for t in seed.seed_turns] == ["user", "ayma"]


def _forty_turn_seed_json():
    return json.dumps(
        {
            "system_prompt": "PERSONA",
            "uid": "u1",
            "session_id": "sess-abc",
            "recent_turns": [
                {
                    "role": "user" if i % 2 == 0 else "ayma",
                    "text": f"voice turn {i}",
                }
                for i in range(40)
            ],
        }
    )


def test_read_room_seed_trims_the_chat_ctx_at_level_2(monkeypatch):
    """Cost-program Phase 2 voice seed diet: the Live model's chat context is
    seeded with only the last CONTEXT_OPT_VOICE_TAIL_TURNS turns, while
    seed_turns — the raw_turns persistence base — still carries the full
    window (shrinking it would overwrite the session doc with less history)."""
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")
    seed = agent._read_room_seed(_FakeCtx(_forty_turn_seed_json()))
    assert len(seed.chat_ctx.items) == 10
    assert seed.chat_ctx.items[-1].text_content == "voice turn 39"
    assert seed.chat_ctx.items[0].text_content == "voice turn 30"
    assert len(seed.seed_turns) == 40  # persistence base untouched


def test_read_room_seed_keeps_the_full_chat_ctx_at_level_0(monkeypatch):
    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    seed = agent._read_room_seed(_FakeCtx(_forty_turn_seed_json()))
    assert len(seed.chat_ctx.items) == 40
    assert len(seed.seed_turns) == 40


def test_read_room_seed_falls_back_without_metadata():
    seed = agent._read_room_seed(_FakeCtx(None))
    assert seed.chat_ctx is None
    assert seed.system_prompt and not seed.uid

    seed2 = agent._read_room_seed(_FakeCtx("not json"))
    assert seed2.chat_ctx is None
    assert seed2.system_prompt


# --- shutdown-persist skipped for a room nothing new was said in ----------


def test_has_new_turns_false_when_window_is_only_the_seed():
    """A room a client never really connected to (e.g. an ICE-handshake
    timeout, or an abandoned retry) still has `window` seeded from
    `/bootstrap`'s `recent_turns` — this must read as "nothing new" so
    `entrypoint`'s shutdown hook skips re-ingesting already-persisted history."""
    from transcript import ROLE_AYMA, ROLE_USER, Turn

    seed_turns = [Turn(ROLE_USER, "hi"), Turn(ROLE_AYMA, "hey there")]
    window = list(seed_turns)
    assert agent._has_new_turns(window, len(seed_turns)) is False

    # A real turn actually exchanged in this room's own conversation flips it.
    window.append(Turn(ROLE_USER, "actually said something this time"))
    assert agent._has_new_turns(window, len(seed_turns)) is True


def test_has_new_turns_true_from_a_fresh_room_with_no_seed():
    from transcript import ROLE_USER, Turn

    window: list[Turn] = []
    assert agent._has_new_turns(window, 0) is False
    window.append(Turn(ROLE_USER, "first thing ever said"))
    assert agent._has_new_turns(window, 0) is True


# --- leaked tool-call artifact stripped from the spoken transcript --------


def test_strip_leaked_tool_artifact_removes_the_glued_prefix():
    # The exact founder-reported garble: a real, verbatim tool name
    # (read_dm_thread) glued into unrelated tokens, immediately followed by
    # Ayma's real, intended reply with no separator.
    leaked = (
        "activalerts_read_dm_threadactivationspeech Ah, you know, my voice "
        "is more for talking, not singing. I wouldn't want to scare you off."
    )
    cleaned = agent._strip_leaked_tool_artifact(leaked)
    assert cleaned == (
        "Ah, you know, my voice is more for talking, not singing. I "
        "wouldn't want to scare you off."
    )


def test_strip_leaked_tool_artifact_leaves_genuine_text_alone():
    normal = "Ah, you know, my voice is more for talking, not singing."
    assert agent._strip_leaked_tool_artifact(normal) == normal
    # A long leading word alone isn't enough — it must also contain a real
    # registered tool name, or genuine text could get clipped by mistake.
    long_word = "supercalifragilisticexpialidocious is a fun word to say."
    assert agent._strip_leaked_tool_artifact(long_word) == long_word


def test_strip_leaked_tool_artifact_removes_the_structured_prefix():
    # The exact founder-reported garble: a structured "key:value" narration
    # of the function call/response, punctuated rather than one glued word.
    leaked = (
        "response:set_voice_preference{output:saved default voice:Ah, "
        "okay! My ears are playing tricks on me. What's up, though?"
    )
    cleaned = agent._strip_leaked_tool_artifact(leaked)
    assert cleaned == (
        "Ah, okay! My ears are playing tricks on me. What's up, though?"
    )


def test_strip_leaked_tool_artifact_structured_needs_a_real_tool_name():
    # Same colon-then-capital shape, but no registered tool name in it —
    # must be left alone (a genuine reply could plausibly look like this).
    normal = "quick note:Something worth flagging for later."
    assert agent._strip_leaked_tool_artifact(normal) == normal


def test_relay_transcripts_strips_a_leaked_tool_artifact_before_relay():
    import asyncio

    handlers = {}
    published = []

    class _FakeSession:
        def on(self, name):
            def _reg(fn):
                handlers[name] = fn
                return fn

            return _reg

    class _FakeLocalParticipant:
        async def publish_data(self, payload, *, reliable, topic):
            published.append((topic, json.loads(payload)))

    class _FakeRoom:
        local_participant = _FakeLocalParticipant()

    class _FakeCtx:
        room = _FakeRoom()

    class _Item:
        role = "assistant"
        text_content = (
            "activalerts_read_dm_threadactivationspeech Ah, you know, my "
            "voice is more for talking, not singing."
        )

    class _ItemEv:
        item = _Item()

    collected: list = []

    async def _run():
        agent.relay_transcripts(_FakeCtx(), _FakeSession(), collector=collected)
        handlers["conversation_item_added"](_ItemEv())
        await asyncio.sleep(0.01)

    asyncio.run(_run())

    expected = "Ah, you know, my voice is more for talking, not singing."
    payload = next(p for t, p in published if t == "agent_transcript")
    assert payload["text"] == expected
    assert "read_dm_thread" not in payload["text"]
    assert [t.text for t in collected] == [expected]


# --- "shut up" muting -------------------------------------------------


@pytest.mark.parametrize(
    "text",
    [
        "shut up",
        "Ayma shut up",
        "shut up please",
        "be quiet",
        "stay quiet",
        "quiet please",
        "stop talking",
        "stop talking now",
        "stop speaking",
        "stop responding",
        "go silent",
        "silence",
        "shush",
        "shhh",
        "hush",
        "zip it",
        "could you please just stop talking now",  # 7 words, still short
    ],
)
def test_is_mute_trigger_matches_short_imperatives(text):
    assert agent._is_mute_trigger(text) is True


@pytest.mark.parametrize(
    "text",
    [
        "",
        "   ",
        "I need some quiet time at home this weekend",
        "I told him to shut up but he wouldn't listen to me at all",
        "what's your favorite quiet place to relax",
        "hello there",
        "tell me about silent movies from the 1920s",
    ],
)
def test_is_mute_trigger_ignores_unrelated_or_long_sentences(text):
    assert agent._is_mute_trigger(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "Ayma",
        "ayma",
        "AYMA are you there",
        "okay Ayma you can talk now",
        "sorry, Ayma, are you there?",
        "hey ayma",
        "Aima",
        "okay Aimma you can talk now",
        "Aymar are you there",
        "aimar",
        "aymma",
        "hey ayema",
        "ayuma",
        "amya come back",
        "a ima, you can talk",
        "hey ima",
        "ay ma can you hear me",
        "Emma, you can talk now",
        "ema",
        "amma",
    ],
)
def test_addresses_ayma_matches_direct_mentions(text):
    assert agent._addresses_ayma(text) is True


@pytest.mark.parametrize(
    "text",
    [
        "",
        "hello there",
        "what time is it",
        "aymara is a language spoken in the Andes",  # substring, not the word
        "I aim to send an image of my mama",
        "she said I'm a man",
        "that is a map of the area",
        "ok please be quiet for a while",
    ],
)
def test_addresses_ayma_ignores_non_mentions(text):
    assert agent._addresses_ayma(text) is False


class _FakeSpeechHandle:
    def __init__(self):
        self.interrupted = False
        self.interrupt_calls = []

    def interrupt(self, *, force=False):
        self.interrupted = True
        self.interrupt_calls.append(force)
        return self


class _SpeechCreatedEv:
    def __init__(self, speech_handle):
        self.speech_handle = speech_handle


class _UserFinalEv:
    def __init__(self, transcript, is_final=True):
        self.transcript = transcript
        self.is_final = is_final


class _FakeMuteSession:
    def __init__(self):
        self._handlers = {}

    def on(self, name):
        def _register(fn):
            self._handlers[name] = fn
            return fn

        return _register

    def user_turn(self, transcript, is_final=True):
        self._handlers["user_input_transcribed"](_UserFinalEv(transcript, is_final))

    def speech_created(self):
        handle = _FakeSpeechHandle()
        self._handlers["speech_created"](_SpeechCreatedEv(handle))
        return handle


def test_relay_mute_control_mutes_on_trigger_and_suppresses_the_reply():
    state = agent.MuteState()
    session = _FakeMuteSession()
    agent.relay_mute_control(session, state)

    session.user_turn("Ayma, shut up")
    assert state.muted is True

    handle = session.speech_created()
    assert handle.interrupted is True
    assert handle.interrupt_calls == [True]


def test_relay_mute_control_unmutes_only_on_direct_callout():
    state = agent.MuteState()
    session = _FakeMuteSession()
    agent.relay_mute_control(session, state)

    session.user_turn("shut up")
    assert state.muted is True

    # An unrelated turn while muted stays muted and its reply is suppressed.
    session.user_turn("what's the weather like")
    assert state.muted is True
    handle = session.speech_created()
    assert handle.interrupted is True

    # Calling her out by name unmutes.
    session.user_turn("okay Ayma, you there?")
    assert state.muted is False

    # The unmuting turn's own reply is NOT suppressed.
    handle2 = session.speech_created()
    assert handle2.interrupted is False


def test_relay_mute_control_ignores_interim_transcripts():
    state = agent.MuteState()
    session = _FakeMuteSession()
    agent.relay_mute_control(session, state)

    session.user_turn("shut", is_final=False)
    assert state.muted is False


def test_relay_mute_control_normal_conversation_is_never_touched():
    """No trigger, never muted: speech_created must not be interrupted —
    normal (non-muted) voice behavior is completely unaffected."""
    state = agent.MuteState()
    session = _FakeMuteSession()
    agent.relay_mute_control(session, state)

    session.user_turn("hey Ayma, how's it going")
    assert state.muted is False
    handle = session.speech_created()
    assert handle.interrupted is False
    assert handle.interrupt_calls == []


def test_relay_mute_control_long_sentence_containing_trigger_words_does_not_mute():
    state = agent.MuteState()
    session = _FakeMuteSession()
    agent.relay_mute_control(session, state)

    session.user_turn("I told him to shut up but he wouldn't listen to me at all")
    assert state.muted is False


def test_relay_transcripts_collects_finalized_turns():
    import asyncio

    handlers = {}

    class _FakeSession:
        def on(self, name):
            def _reg(fn):
                handlers[name] = fn
                return fn

            return _reg

    class _FakeCtx:
        class room:  # noqa: N801
            class local_participant:  # noqa: N801
                @staticmethod
                async def publish_data(*a, **k):
                    pass

    class _UserEv:
        def __init__(self, transcript, is_final):
            self.transcript = transcript
            self.is_final = is_final

    class _Item:
        role = "assistant"
        text_content = "hi from ayma"

    class _ItemEv:
        item = _Item()

    collected: list = []

    async def _run():
        agent.relay_transcripts(_FakeCtx(), _FakeSession(), collector=collected)
        handlers["user_input_transcribed"](_UserEv("partial", False))
        handlers["user_input_transcribed"](_UserEv("hey ayma", True))
        handlers["conversation_item_added"](_ItemEv())
        await asyncio.sleep(0.01)

    asyncio.run(_run())

    assert [(t.role, t.text) for t in collected] == [
        ("user", "hey ayma"),
        ("ayma", "hi from ayma"),
    ]


# --- §F3 mid-call credit cap (founder cost bug, 2026-09-21) ----------------
#
# Root cause: credits were checked only once, at /bootstrap (session token
# mint) — nothing during the live call ever checked again, so a call that
# started in the black could run unbounded once usage crossed into zero/
# negative mid-call. `relay_token_usage` now re-checks the same
# `token_ledger.check` every other credit-gated call site already uses, right
# after each turn's usage is recorded, and fires `on_credits_exhausted` once.


class _FakeAggValue:
    def __init__(self, n):
        self.value = n


class _FakeEventsCol:
    """The `users/{uid}/spend_events` subcollection slice token_ledger.add
    touches: add(), count().get(), order_by().limit().stream()."""

    def __init__(self):
        self.added = []

    def add(self, data):
        self.added.append(dict(data))

    def count(self):
        col = self

        class _Agg:
            def get(self):
                return [[_FakeAggValue(len(col.added))]]

        return _Agg()

    def order_by(self, *_a, **_k):
        return self

    def limit(self, _n):
        return self

    def stream(self):
        return iter(())


class _FakeDocRef:
    def __init__(self):
        self.sets = []
        self.events = _FakeEventsCol()

    def set(self, payload, merge=False):  # noqa: FBT002 - matches real API
        self.sets.append((payload, merge))

    def collection(self, _name):
        return self.events


class _FakeCollRef:
    def __init__(self):
        self.doc = _FakeDocRef()

    def document(self, _uid):
        return self.doc


class _FakeDb:
    """Stands in for the Firestore client in these tests — the real ledger
    write inside `relay_token_usage` (now `token_ledger.add`) is exercised in
    test_token_ledger; here we only need it to not touch the network while we
    drive the credit-cap trigger via a monkeypatched `token_ledger.check`.
    Patched onto BOTH `agent.get_db` and `token_ledger.get_db` since the
    per-turn write goes through token_ledger.add."""

    def __init__(self):
        self.coll = _FakeCollRef()

    def collection(self, _name):
        return self.coll


def _fake_metrics(*, total=150, input_tokens=100, output_tokens=50):
    from livekit.agents.metrics import RealtimeModelMetrics

    return RealtimeModelMetrics(
        request_id="r1",
        timestamp=0.0,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=total,
        input_token_details=RealtimeModelMetrics.InputTokenDetails(),
        output_token_details=RealtimeModelMetrics.OutputTokenDetails(),
    )


class _FakeMetricsSession:
    def __init__(self):
        self._handlers = {}

    def on(self, name):
        def _register(fn):
            self._handlers[name] = fn
            return fn

        return _register

    def fire(self, metrics):
        class _Ev:
            pass

        ev = _Ev()
        ev.metrics = metrics
        self._handlers["metrics_collected"](ev)


def test_relay_token_usage_triggers_callback_once_credits_are_exhausted(
    monkeypatch,
):
    import asyncio

    import token_ledger

    _db = _FakeDb()
    monkeypatch.setattr(agent, "get_db", lambda: _db)
    monkeypatch.setattr(token_ledger, "get_db", lambda: _db)

    def _raise_capped(_uid):
        raise token_ledger.TokenCapExceeded("out of credits (uid=u1)")

    monkeypatch.setattr(token_ledger, "check", _raise_capped)

    session = _FakeMetricsSession()
    calls = []

    async def _on_exhausted():
        calls.append(True)

    agent.relay_token_usage(
        session, "u1", on_credits_exhausted=_on_exhausted
    )

    async def _run():
        session.fire(_fake_metrics())
        # A second turn landing before the async callback above is awaited
        # elsewhere must not fire it again.
        session.fire(_fake_metrics())
        await asyncio.sleep(0.05)

    asyncio.run(_run())

    assert calls == [True]


def test_relay_token_usage_does_not_trigger_while_credits_remain(monkeypatch):
    import asyncio

    import token_ledger

    _db = _FakeDb()
    monkeypatch.setattr(agent, "get_db", lambda: _db)
    monkeypatch.setattr(token_ledger, "get_db", lambda: _db)
    monkeypatch.setattr(token_ledger, "check", lambda _uid: None)

    session = _FakeMetricsSession()
    calls = []

    async def _on_exhausted():
        calls.append(True)

    agent.relay_token_usage(
        session, "u1", on_credits_exhausted=_on_exhausted
    )

    async def _run():
        session.fire(_fake_metrics())
        await asyncio.sleep(0.05)

    asyncio.run(_run())

    assert calls == []


def test_relay_token_usage_without_callback_is_unaffected(monkeypatch):
    """No `on_credits_exhausted` passed (e.g. the pre-sign-in welcome room,
    which never carries a uid) — same as before this change, no crash."""
    import asyncio

    import token_ledger

    _db = _FakeDb()
    monkeypatch.setattr(agent, "get_db", lambda: _db)
    monkeypatch.setattr(token_ledger, "get_db", lambda: _db)

    session = _FakeMetricsSession()
    agent.relay_token_usage(session, "u1")

    async def _run():
        session.fire(_fake_metrics())
        await asyncio.sleep(0.05)

    asyncio.run(_run())  # must not raise


def test_relay_token_usage_records_each_turn_through_the_ledger_with_session_id(
    monkeypatch,
):
    """Each Live turn's write goes through token_ledger.add carrying this
    call's session_id and the actual Live model — that's what groups a voice
    call's spend events into one "Voice call" row on the Credits screen's
    Real money tab (founder request 2026-09-26)."""
    import asyncio

    import token_ledger

    recorded = []
    monkeypatch.setattr(
        token_ledger, "add",
        lambda uid, feature, tokens, **kw: recorded.append(
            (uid, feature, tokens, kw)
        ),
    )

    session = _FakeMetricsSession()
    agent.relay_token_usage(session, "u1", session_id="room-42")

    async def _run():
        session.fire(
            _fake_metrics(total=150, input_tokens=100, output_tokens=50)
        )
        await asyncio.sleep(0.01)

    asyncio.run(_run())

    assert recorded == [(
        "u1", token_ledger.FEATURE_VOICE, 150,
        {
            "input_tokens": 100,
            "output_tokens": 50,
            "model": token_ledger.live_model_id(),
            "session_id": "room-42",
        },
    )]


def test_publish_call_ending_sends_the_reason():
    import asyncio

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            published.append((topic, json.loads(payload), reliable))

    class _Room:
        local_participant = _Participant()

    class _Ctx:
        room = _Room()

    asyncio.run(agent._publish_call_ending(_Ctx(), "out_of_credits"))

    assert published == [
        ("call_ending", {"reason": "out_of_credits"}, True)
    ]


def test_publish_call_ending_swallows_a_publish_failure():
    import asyncio

    class _FailingParticipant:
        @staticmethod
        async def publish_data(*a, **k):
            raise RuntimeError("data channel closed")

    class _Room:
        local_participant = _FailingParticipant()

    class _Ctx:
        room = _Room()

    asyncio.run(agent._publish_call_ending(_Ctx(), "out_of_credits"))  # no raise


def test_out_of_credits_instructions_match_the_shared_text_chat_wording():
    """Voice's spoken goodbye reuses the exact same sentence the text-chat
    `showOutOfCreditsSnack`/out-of-credits surfaces already use, instead of a
    separately hand-typed line that could drift from it."""
    import token_ledger

    expected = token_ledger.out_of_credits_message(token_ledger.CONTEXT_CHAT)
    assert expected in agent._OUT_OF_CREDITS_INSTRUCTIONS


# --- SessionFlush (exactly-once memory write) + end_call_out_of_credits ---


def test_session_flush_calls_persist_and_ingest_exactly_once(monkeypatch):
    import asyncio

    from transcript import ROLE_USER, Turn

    calls = []

    async def _fake_persist_and_ingest(db, uid, session_id, turns):
        calls.append((db, uid, session_id, list(turns)))

    monkeypatch.setattr(agent, "persist_and_ingest", _fake_persist_and_ingest)

    window = [Turn(ROLE_USER, "hi")]
    flush = agent.SessionFlush(object(), "u1", "sess-1", window)

    async def _run():
        await flush.run()
        await flush.run()  # second call is a no-op — no second LLM spend

    asyncio.run(_run())

    assert len(calls) == 1
    assert calls[0][1:3] == ("u1", "sess-1")
    assert flush.done is True


def test_session_flush_is_a_noop_without_uid_session_or_turns(monkeypatch):
    import asyncio

    calls = []

    async def _fake_persist_and_ingest(*a, **k):
        calls.append(a)

    monkeypatch.setattr(agent, "persist_and_ingest", _fake_persist_and_ingest)

    asyncio.run(agent.SessionFlush(object(), "", "sess-1", []).run())
    asyncio.run(agent.SessionFlush(object(), "u1", "", []).run())
    asyncio.run(agent.SessionFlush(object(), "u1", "sess-1", []).run())

    assert calls == []


def test_end_call_out_of_credits_flushes_speaks_signals_then_shuts_down(
    monkeypatch,
):
    """The founder-required sequence (2026-09-21): memory write -> spoken
    goodbye -> tell the client why -> disconnect. Never an abrupt cutoff."""
    import asyncio

    order = []

    async def _flush():
        order.append("flush")

    class _FakeHandle:
        def __await__(self):
            async def _impl():
                order.append("goodbye_played")
                return self

            return _impl().__await__()

    class _FakeSession:
        def generate_reply(self, *, instructions, allow_interruptions):
            order.append(("generate_reply", allow_interruptions))
            assert "out of credits" in instructions.lower()
            return _FakeHandle()

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            order.append("call_ending_published")
            published.append((topic, json.loads(payload), reliable))

    class _Room:
        local_participant = _Participant()

    class _FakeCtx:
        room = _Room()

        @staticmethod
        def shutdown(reason):
            order.append(("shutdown", reason))

    asyncio.run(
        agent.end_call_out_of_credits(_FakeCtx(), _FakeSession(), "u1", _flush)
    )

    assert order == [
        "flush",
        ("generate_reply", False),
        "goodbye_played",
        "call_ending_published",
        ("shutdown", "out_of_credits"),
    ]
    assert published == [("call_ending", {"reason": "out_of_credits"}, True)]


def test_end_call_out_of_credits_still_ends_the_call_if_the_goodbye_fails(
    monkeypatch,
):
    """A stuck/failed TTS goodbye must never leave a broke user's call
    running — the call still ends and the client still gets told why."""
    import asyncio

    class _FakeSession:
        def generate_reply(self, **_kwargs):
            raise RuntimeError("Live session already closing")

    published = []

    class _Participant:
        @staticmethod
        async def publish_data(payload, *, reliable, topic):
            published.append((topic, json.loads(payload), reliable))

    class _Room:
        local_participant = _Participant()

    shutdown_calls = []

    class _FakeCtx:
        room = _Room()

        @staticmethod
        def shutdown(reason):
            shutdown_calls.append(reason)

    flushed = []

    async def _flush():
        flushed.append(True)

    asyncio.run(
        agent.end_call_out_of_credits(_FakeCtx(), _FakeSession(), "u1", _flush)
    )

    assert flushed == [True]
    assert shutdown_calls == ["out_of_credits"]
    assert published == [("call_ending", {"reason": "out_of_credits"}, True)]


def test_end_call_out_of_credits_still_ends_the_call_if_the_flush_fails():
    """A failed memory write is logged, not fatal — the call must still end
    rather than hang open because Firestore hiccupped."""
    import asyncio

    async def _flush():
        raise RuntimeError("firestore write failed")

    class _FakeHandle:
        def __await__(self):
            async def _impl():
                return self

            return _impl().__await__()

    class _FakeSession:
        def generate_reply(self, **_kwargs):
            return _FakeHandle()

    class _Participant:
        @staticmethod
        async def publish_data(*a, **k):
            pass

    class _Room:
        local_participant = _Participant()

    shutdown_calls = []

    class _FakeCtx:
        room = _Room()

        @staticmethod
        def shutdown(reason):
            shutdown_calls.append(reason)

    asyncio.run(
        agent.end_call_out_of_credits(_FakeCtx(), _FakeSession(), "u1", _flush)
    )

    assert shutdown_calls == ["out_of_credits"]


class _OpenerSession(_FakeMuteSession):
    def __init__(self):
        super().__init__()
        self.replies = []

    async def generate_reply(self, instructions=None):
        self.replies.append(instructions)


class _StateEv:
    def __init__(self, new_state):
        self.new_state = new_state


def _opener_seed(**kw):
    return agent.RoomSeed(system_prompt="p", **kw)


async def _run_opener(session, seed, window, user_event=None):
    import asyncio

    task = asyncio.create_task(
        agent.maybe_open_conversation(
            session, seed, window=window, grace_seconds=0.05
        )
    )
    await asyncio.sleep(0.01)
    if user_event:
        user_event()
    return await task


def test_opener_fires_when_user_is_silent():
    import asyncio

    s = _OpenerSession()
    assert asyncio.run(_run_opener(s, _opener_seed(), [])) is True
    assert len(s.replies) == 1 and s.replies[0]


def test_opener_suppressed_when_user_speaks_first_by_vad():
    import asyncio

    s = _OpenerSession()
    fired = asyncio.run(
        _run_opener(s, _opener_seed(), [],
                    lambda: s._handlers["user_state_changed"](_StateEv("speaking")))
    )
    assert fired is False and s.replies == []


def test_opener_suppressed_when_user_transcript_arrives_first():
    import asyncio

    s = _OpenerSession()
    fired = asyncio.run(
        _run_opener(s, _opener_seed(), [], lambda: s.user_turn("hey", is_final=False))
    )
    assert fired is False and s.replies == []


def test_opener_skipped_for_welcome_greeting():
    import asyncio

    s = _OpenerSession()
    seed = _opener_seed(greeting_instructions="say hi")
    assert asyncio.run(_run_opener(s, seed, [])) is False
    assert s.replies == []


def test_opener_skipped_when_resuming_mid_turn():
    import asyncio

    s = _OpenerSession()
    turns = [agent.Turn(role=agent.ROLE_USER, text="so about")]
    seed = _opener_seed(seed_turns=turns)
    assert asyncio.run(_run_opener(s, seed, list(turns))) is False
    assert s.replies == []


def test_opener_skipped_when_someone_already_spoke():
    import asyncio

    s = _OpenerSession()
    window = []

    async def go():
        import asyncio as a

        t = a.create_task(
            agent.maybe_open_conversation(
                s, _opener_seed(), window=window, grace_seconds=0.05
            )
        )
        await a.sleep(0.01)
        window.append(agent.Turn(role=agent.ROLE_AYMA, text="hi"))
        return await t

    assert asyncio.run(go()) is False
    assert s.replies == []


def test_opener_disabled_by_zero_grace():
    import asyncio

    s = _OpenerSession()

    async def go():
        return await agent.maybe_open_conversation(
            s, _opener_seed(), window=[], grace_seconds=0
        )

    assert asyncio.run(go()) is False


def test_opener_swallows_generate_failure():
    import asyncio

    s = _OpenerSession()

    async def boom(instructions=None):
        raise RuntimeError("x")

    s.generate_reply = boom
    assert asyncio.run(_run_opener(s, _opener_seed(), [])) is False
