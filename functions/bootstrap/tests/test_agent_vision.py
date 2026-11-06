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


def test_vision_instructions_carry_the_secure_content_rule():
    text = agent.VISION_INSTRUCTIONS
    assert "cannot see protected content" in text
    assert "never guess" in text
    # And the no-share honesty rule: never claim to see with no share live.
    assert "do not claim to see" in text
