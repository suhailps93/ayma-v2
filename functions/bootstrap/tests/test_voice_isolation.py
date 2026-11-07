"""Agent-side voice isolation (agent.py _voice_isolation_filter).

Founder rule (2026-11-06): where the stack supports LiveKit voice
isolation and the LiveKit plan covers it, it is on by default — the funded
project is on Scale, whose included voice-isolation minutes cover Krisp
VIVA and ai-coustics QUAIL_VF (verified 2026-11-06). The filter runs in
the agent on the user's inbound audio (RoomInputOptions), never in the
frontend, and VOICE_ISOLATION switches provider or turns it off
without restricting the user's model choice.
"""

import pytest

pytest.importorskip("livekit.agents")
pytest.importorskip("livekit.plugins.krisp")
pytest.importorskip("livekit.plugins.ai_coustics")

import agent  # noqa: E402
import config  # noqa: E402


def test_off_returns_none():
    assert agent._voice_isolation_filter("off") is None


def test_krisp_builds_viva_filter():
    from livekit.plugins.krisp import KrispVivaFilterFrameProcessor

    filt = agent._voice_isolation_filter("krisp")
    assert isinstance(filt, KrispVivaFilterFrameProcessor)


def test_aicoustics_builds_quail_vf_s_enhancer():
    from livekit.plugins.ai_coustics import AICousticsAudioEnhancer

    filt = agent._voice_isolation_filter("aicoustics")
    assert isinstance(filt, AICousticsAudioEnhancer)


def test_unknown_provider_returns_none():
    assert agent._voice_isolation_filter("bogus") is None


def test_room_input_options_carry_the_filter():
    from livekit.plugins.krisp import KrispVivaFilterFrameProcessor

    opts = agent._room_input_options()
    assert isinstance(opts.noise_cancellation, KrispVivaFilterFrameProcessor)


def test_config_default_is_krisp(monkeypatch):
    monkeypatch.delenv("VOICE_ISOLATION", raising=False)
    assert config._load().voice_isolation == "krisp"


def test_config_accepts_off_and_aicoustics(monkeypatch):
    monkeypatch.setenv("VOICE_ISOLATION", "off")
    assert config._load().voice_isolation == "off"
    monkeypatch.setenv("VOICE_ISOLATION", "aicoustics")
    assert config._load().voice_isolation == "aicoustics"


def test_config_rejects_unknown_provider(monkeypatch):
    monkeypatch.setenv("VOICE_ISOLATION", "bogus")
    with pytest.raises(ValueError):
        config._load()
