"""Meta voice-cascade cases — the hackathon-new ``test_agent.py`` cascade tests.

Extracted from Ayma's private ``tests/test_agent.py``. In the private suite these
run against the full voice-agent worker (``agent.py``); here they run against the
cascade **excerpt** ``agent_meta_cascade.py`` (the only new-work functions —
``build_meta_cascade_session`` / ``relay_cascade_usage``). The rest of that suite
(room-seed parsing, ``relay_practice_coach``, Gemini-Live path, mute control,
idle watchdog, …) tests private-worker plumbing that is not part of this public
repo and is therefore not included.

These need the voice dependencies (``livekit-agents`` + ``livekit-plugins-openai``,
in ``requirements-voice.txt``). When they are not installed the module is skipped
— it is **not** part of the always-green self-contained run; see README →
"What runs standalone".
"""

import pytest

pytest.importorskip("livekit.agents", reason="voice deps not installed")
pytest.importorskip("livekit.plugins.openai", reason="voice deps not installed")

import agent_meta_cascade as agent  # noqa: E402
from config import CONFIG  # noqa: E402


def _install_fake_cascade_plugins(monkeypatch):
    """Patch the livekit openai plugin + inference module the cascade builder
    imports, plus ``AgentSession``, with constructor-recording fakes."""
    from livekit.plugins import openai as lk_openai
    from livekit.agents import inference

    captured: dict = {}

    class _FakeSTT:
        def __init__(self, **kwargs):
            captured["stt"] = kwargs

    class _FakeLLM:
        def __init__(self, **kwargs):
            captured["llm"] = kwargs

    class _FakeTTS:
        def __init__(self, **kwargs):
            captured["tts"] = kwargs

    class _FakeVAD:
        def __init__(self, **kwargs):
            captured["vad"] = kwargs

    class _FakeSession:
        def __init__(self, **kwargs):
            captured["session"] = kwargs

    monkeypatch.setattr(lk_openai, "STT", _FakeSTT)
    monkeypatch.setattr(lk_openai, "LLM", _FakeLLM)
    monkeypatch.setattr(inference, "TTS", _FakeTTS)
    monkeypatch.setattr(inference, "VAD", _FakeVAD)
    monkeypatch.setattr(agent, "AgentSession", _FakeSession)
    return captured


def test_meta_cascade_requires_the_api_key(monkeypatch):
    monkeypatch.delenv("META_API_KEY", raising=False)
    with pytest.raises(RuntimeError, match="META_API_KEY"):
        agent.build_meta_cascade_session()


def test_meta_cascade_wires_config_models_and_reasoning(monkeypatch):
    monkeypatch.setenv("META_API_KEY", "test-key")
    captured = _install_fake_cascade_plugins(monkeypatch)

    agent.build_meta_cascade_session()

    # STT + LLM point at the Meta Model API with the config model ids (no
    # hardcoded strings) and the real key; never Gemini.
    assert captured["stt"]["model"] == CONFIG.meta_transcribe_model
    assert captured["stt"]["base_url"] == CONFIG.meta_api_base_url
    assert captured["stt"]["api_key"] == "test-key"
    assert captured["llm"]["model"] == CONFIG.meta_chat_model
    assert captured["llm"]["base_url"] == CONFIG.meta_api_base_url
    assert captured["llm"]["api_key"] == "test-key"
    # Muse Spark is reasoning-only — minimal effort must be passed or replies
    # come back empty.
    assert captured["llm"]["reasoning_effort"] == CONFIG.meta_reasoning_effort
    # TTS vendor + VAD come from config, so the flag can reach them.
    assert captured["tts"]["model"] == CONFIG.meta_cascade_tts_model
    assert captured["vad"]["model"] == CONFIG.meta_cascade_vad_model
    # A full cascade: STT + LLM + TTS + VAD, not a RealtimeModel.
    assert set(captured["session"]) == {
        "stt", "llm", "tts", "vad", "allow_interruptions"
    }


def test_meta_cascade_adds_tts_voice_only_when_configured(monkeypatch):
    import config

    monkeypatch.setenv("META_API_KEY", "test-key")
    captured = _install_fake_cascade_plugins(monkeypatch)

    # CONFIG is a frozen dataclass — reload it from env and swap agent.CONFIG.
    monkeypatch.delenv("META_CASCADE_TTS_VOICE", raising=False)
    monkeypatch.setattr(agent, "CONFIG", config._load())
    agent.build_meta_cascade_session()
    assert "voice" not in captured["tts"]

    monkeypatch.setenv("META_CASCADE_TTS_VOICE", "Ashley")
    monkeypatch.setattr(agent, "CONFIG", config._load())
    agent.build_meta_cascade_session()
    assert captured["tts"]["voice"] == "Ashley"


def test_relay_cascade_usage_meters_llm_turns(monkeypatch):
    import token_ledger
    from livekit.agents.metrics import LLMMetrics

    recorded: dict = {}

    def _fake_add(uid, feature, tokens, **kwargs):
        recorded.update(
            uid=uid, feature=feature, tokens=tokens,
            model=kwargs.get("model"), session_id=kwargs.get("session_id"),
        )

    monkeypatch.setattr(token_ledger, "add", _fake_add)

    handlers: dict = {}

    class _FakeSession:
        def on(self, name):
            def _reg(fn):
                handlers[name] = fn
                return fn
            return _reg

    agent.relay_cascade_usage(
        _FakeSession(), "viewer_uid", session_id="s-practice", model="muse-spark-x",
    )

    class _Ev:
        metrics = LLMMetrics(
            type="llm_metrics", label="meta", request_id="r1",
            timestamp=0.0, duration=0.1, ttft=0.05, cancelled=False,
            completion_tokens=12, prompt_tokens=30, prompt_cached_tokens=0,
            total_tokens=42, tokens_per_second=10.0,
        )

    handlers["metrics_collected"](_Ev())
    assert recorded["feature"] == token_ledger.FEATURE_VOICE
    assert recorded["tokens"] == 42
    assert recorded["model"] == "muse-spark-x"
    assert recorded["session_id"] == "s-practice"
