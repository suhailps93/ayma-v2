"""User↔Ayma video + screen share (feedback item 13) — agent-side checks.

Offline checks only, in the style of test_agent.py: the capability
declaration constants the client gates its Video / Screen share toggles
on, the FLAG_SECURE black-frame detector the track watcher uses, and the
instruction block that tells Ayma to say she cannot see protected content
rather than guess.

Skipped unless the agent dependency set (requirements-agent.txt) is
installed — the Main API venv deliberately does not carry it.
"""

import pytest

pytest.importorskip("livekit.agents")

import agent  # noqa: E402


def test_vision_capability_states_are_the_client_contract():
    # The client's VoiceSessionController matches these exact strings on
    # the voice_status topic (vision_supported / vision_unsupported).
    assert agent.VOICE_STATUS_VISION_SUPPORTED == "vision_supported"
    assert agent.VOICE_STATUS_VISION_UNSUPPORTED == "vision_unsupported"
    assert agent.TOPIC_VISION_STATE == "vision_state"
    assert agent.TOPIC_VISION_CONTROL == "vision_control"
    assert agent.VISION_STATE_SECURE_CONTENT == "secure_content"
    assert agent.VISION_STATE_FRAMES_FLOWING == "frames_flowing"


def test_black_frame_detection_matches_the_copilot_threshold():
    # Pure black and near-black (mean <= 4.0) read as FLAG_SECURE black.
    assert agent.vision_frame_is_black(bytes([0, 0, 0] * 100)) is True
    assert agent.vision_frame_is_black(bytes([4, 4, 4] * 100)) is True
    assert agent.vision_frame_is_black(bytes([3, 4, 5] * 100)) is True
    # Any real content is not black (the check is a frame MEAN, like the
    # co-pilot's sampler, so a meaningful bright region lifts it clear),
    # and an empty frame is no evidence either way.
    assert agent.vision_frame_is_black(bytes([255, 255, 255] * 100)) is False
    assert agent.vision_frame_is_black(
        bytes([0, 0, 0] * 50 + [255, 255, 255] * 50)
    ) is False
    assert agent.vision_frame_is_black(b"") is False


def test_video_capability_matrix_is_catalog_driven():
    # The support matrix (founder addition, 2026-11-06) lives in ONE place —
    # voice_catalog, driven by CONFIG.voice_video_capable_providers —
    # mirroring provider_supports_accent. Realtime native-audio providers
    # perceive video; cascade stacks never do in livekit-agents 1.8.9,
    # whatever their components.
    import voice_catalog

    assert voice_catalog.provider_supports_video("gemini") is True
    assert voice_catalog.provider_supports_video("openai") is True
    assert voice_catalog.provider_supports_video("deepgram") is False
    assert voice_catalog.provider_supports_video("") is False

    gemini = voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_REALTIME,
        realtime_model_id=voice_catalog.REALTIME_GEMINI,
    )
    assert gemini.supports_video is True
    openai = voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_REALTIME,
        realtime_model_id=voice_catalog.REALTIME_OPENAI,
    )
    assert openai.supports_video is True
    cascade = voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_CASCADE, tts_id="fishaudio/s2.1-pro"
    )
    assert cascade.supports_video is False

    # The served catalog carries the flag on its realtime entries so the
    # Models screen reads the same truth the agent declares.
    catalog = voice_catalog._build_catalog()
    by_id = {m["id"]: m for m in catalog["realtime_models"]}
    assert by_id[voice_catalog.REALTIME_GEMINI]["supports_video"] is True

    # The saved-stack reader agrees with the default (Gemini Live) stack.
    assert voice_catalog.video_supported({}) is True
    assert (
        voice_catalog.video_supported({"ayma_voice_mode": "cascade"})
        is False
    )


def test_vision_instructions_carry_the_secure_content_rule():
    text = agent.VISION_INSTRUCTIONS
    assert "cannot see protected content" in text
    assert "never guess" in text
    # And the no-share honesty rule: never claim to see with no share live.
    assert "do not claim to see" in text
