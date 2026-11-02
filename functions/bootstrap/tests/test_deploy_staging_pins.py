"""Routing-audit W1: the staging deploy script applies env with a
full-replacement ``--set-env-vars`` from ``API_ENV_BASE`` / ``AGENT_ENV_BASE``.
Those bases MUST carry every ``LLM_PROVIDER_*=gemini`` pin (+ the global
``LLM_PROVIDER``) so a ``--full`` deploy can't silently wipe the pins and revert
a surface to Meta-direct (off LiveKit). They must also carry NO direct-provider
override (``FLAG_LLM_ROUTE_*=vertex`` / ``FLAG_VOICE_PROVIDER=google`` /
``FLAG_LLM_FALLBACK_TO_GOOGLE=true``), which would reroute off LiveKit.
"""

from __future__ import annotations

import re
from pathlib import Path


def _script_text() -> str:
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "scripts" / "deploy-staging.sh"
        if candidate.exists():
            return candidate.read_text()
    raise AssertionError("scripts/deploy-staging.sh not found above this test")


def _base(text: str, name: str) -> str:
    # The first assignment of the base (the authoritative definition).
    m = re.search(rf'^{name}="([^"]*)"', text, re.MULTILINE)
    assert m, f"{name} assignment not found"
    return m.group(1)


def test_api_base_pins_the_six_text_surfaces_and_global():
    api = _base(_script_text(), "API_ENV_BASE")
    for pin in (
        "LLM_PROVIDER=gemini",
        "LLM_PROVIDER_CHAT=gemini",
        "LLM_PROVIDER_MATCHING=gemini",
        "LLM_PROVIDER_REPORTS=gemini",
        "LLM_PROVIDER_PRACTICE=gemini",
        "LLM_PROVIDER_DM_COACH=gemini",
        "LLM_PROVIDER_TRANSLATE=gemini",
    ):
        assert pin in api, f"API_ENV_BASE missing {pin}"


def test_agent_base_pins_voice_and_global():
    agent = _base(_script_text(), "AGENT_ENV_BASE")
    assert "LLM_PROVIDER=gemini" in agent
    assert "LLM_PROVIDER_VOICE=gemini" in agent


def test_bases_carry_no_direct_provider_override():
    text = _script_text()
    api = _base(text, "API_ENV_BASE")
    agent = _base(text, "AGENT_ENV_BASE")
    for base in (api, agent):
        assert "FLAG_LLM_ROUTE" not in base
        assert "FLAG_VOICE_PROVIDER" not in base
        assert "FLAG_LLM_FALLBACK_TO_GOOGLE" not in base
        # No vendor pin to a direct provider via the bases.
        assert "=vertex" not in base
        assert "=meta" not in base
        assert "=open-weights" not in base


def test_bases_still_carry_the_other_critical_env():
    text = _script_text()
    api = _base(text, "API_ENV_BASE")
    agent = _base(text, "AGENT_ENV_BASE")
    for base in (api, agent):
        assert "USE_VERTEX=true" in base
        assert "GOOGLE_CLOUD_PROJECT=" in base
        assert "LIVEKIT_URL=" in base
    assert "STORAGE_BUCKET=" in api
    assert "VOICE_AGENT_CLOUD_DEFAULT=cloudrun" in api
    assert "OPEN_WEIGHTS_BASE_URL=" in api
