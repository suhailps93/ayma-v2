"""Founder decision Nov 17: the per-user voice routing opt-out is removed.
Every voice room runs on LiveKit; a room with no explicit mark defaults to
LiveKit. These pin that the setting, its readers, and its endpoint are gone, and
that an unmarked room routes to LiveKit (not Cloud Run as before)."""

import pytest

import livekit_token
import main
import schema


def test_unmarked_room_defaults_to_livekit():
    # agent.py needs the LiveKit worker SDK; skip where it isn't installed
    # (CI has it — test_agent.py also importorskips it).
    pytest.importorskip("livekit.agents")
    import agent

    # The dispatch guard's room-target default flipped from cloudrun → livekit.
    assert agent._room_target_cloud(None) == "livekit"
    assert agent._room_target_cloud("") == "livekit"
    assert agent._room_target_cloud("{not json") == "livekit"
    assert agent._room_target_cloud('{"voice_agent_cloud": "livekit"}') == "livekit"
    # An explicit legacy "cloudrun" marker is still parsed as-is (the value set
    # survives for the watcher), but nothing writes it any more.
    assert agent._room_target_cloud('{"voice_agent_cloud": "cloudrun"}') == "cloudrun"


def test_voice_cloud_is_a_single_livekit_constant():
    assert schema.VOICE_AGENT_CLOUD == "livekit"


def test_the_per_user_setting_and_its_readers_are_gone():
    assert not hasattr(schema, "PF_AYMA_VOICE_CLOUD")
    assert not hasattr(schema, "VOICE_AGENT_CLOUDS")
    assert not hasattr(schema, "VOICE_AGENT_CLOUD_DEFAULT")
    assert not hasattr(livekit_token, "resolve_voice_agent_cloud")
    assert not hasattr(main, "_voice_agent_cloud")


def test_the_agent_cloud_endpoint_is_gone():
    paths = {r.path for r in main.app.routes if hasattr(r, "path")}
    assert "/voice/agent-cloud" not in paths
