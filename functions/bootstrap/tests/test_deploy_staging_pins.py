"""Routing-audit W1: the staging deploy script applies env with a
full-replacement ``--set-env-vars`` from ``API_ENV_BASE`` / ``AGENT_ENV_BASE``.
Those bases MUST carry every ``LLM_PROVIDER_*=gemini`` pin (+ the global
``LLM_PROVIDER``) so a ``--full`` deploy can't silently wipe the pins and revert
a surface to Meta-direct (off LiveKit). They must also carry NO direct-provider
override (``FLAG_LLM_ROUTE_*=vertex`` / ``FLAG_VOICE_PROVIDER=google`` /
``FLAG_LLM_FALLBACK_TO_GOOGLE=true``), which would reroute off LiveKit.

Staging repoint 2026-11-03: the bases must also reproduce the LIVE staging
config exactly — the funded Aimma LiveKit project on both services — so a
``--full`` deploy can't flip staging back to the unfunded staging project.
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
    assert "VOICE_AGENT_CLOUD_DEFAULT=livekit" in api
    assert "AGENT_NAME_LIVEKIT=ayma-lk-staging" in api
    assert "OPEN_WEIGHTS_BASE_URL=" in api


# Live staging runs on the funded Aimma LiveKit project (verified 2026-11-03
# via gcloud run services describe on both staging services).
_LIVEKIT_URL = "LIVEKIT_URL=wss://aimma-wt34nu3l.livekit.cloud"
_LIVEKIT_PROJECT_ID = "LIVEKIT_PROJECT_ID=p_4jk3pqz7u9r"
_LIVEKIT_ROOM_PREFIX = "LIVEKIT_ROOM_PREFIX=ayma-staging-"


def test_bases_pin_the_funded_livekit_project():
    text = _script_text()
    api = _base(text, "API_ENV_BASE")
    agent = _base(text, "AGENT_ENV_BASE")
    for base in (api, agent):
        assert _LIVEKIT_URL in base
        assert _LIVEKIT_PROJECT_ID in base
        assert _LIVEKIT_ROOM_PREFIX in base
        # The old unfunded staging project must not come back via the script.
        assert "ayma-staging-cyofszqr" not in base
        assert "p_484u2zjk8ob" not in base


def test_bases_enable_cartesia_on_staging():
    # Staging-first Cartesia: both services carry the credited-providers
    # override (the committed default set + cartesia) so the staging catalog
    # (API) and the set_stt/set_tts skills (agent) offer it.
    text = _script_text()
    m = re.search(
        r'^CARTESIA_CREDITED_PROVIDERS="([^"]*)"', text, re.MULTILINE
    )
    assert m, "CARTESIA_CREDITED_PROVIDERS assignment not found"
    providers = m.group(1).split(",")
    assert providers[-1] == "cartesia"
    # Union corrected 2026-11-06: live staging list (deepgram, elevenlabs,
    # openai, google, cartesia, inworld, fishaudio, rime, gradium) plus the
    # previously committed assemblyai — no entries dropped.
    assert providers[:-1] == [
        "inworld", "deepgram", "fishaudio", "assemblyai", "rime",
        "gradium", "google", "elevenlabs", "openai",
    ]
    for base in (_base(text, "API_ENV_BASE"), _base(text, "AGENT_ENV_BASE")):
        assert "VOICE_CREDITED_PROVIDERS=" in base
        assert "${CARTESIA_CREDITED_PROVIDERS}" in base


def test_livekit_secrets_use_the_staging_names():
    text = _script_text()
    api_secrets = _base(text, "API_SECRETS")
    agent_secrets = _base(text, "AGENT_SECRETS")
    for secrets in (api_secrets, agent_secrets):
        assert "LIVEKIT_API_KEY=LIVEKIT_API_KEY_STAGING:latest" in secrets
        assert "LIVEKIT_API_SECRET=LIVEKIT_API_SECRET_STAGING:latest" in secrets


def test_api_base_and_secrets_carry_web_search():
    text = _script_text()
    api_env = _base(text, "API_ENV_BASE")
    api_secrets = _base(text, "API_SECRETS")
    assert "GEMINI_WEB_SEARCH=true" in api_env
    assert "WEB_SEARCH_DAILY_CAP=100" in api_env
    assert "WEB_SEARCH_API_KEY=WEB_SEARCH_API_KEY:latest" in api_secrets
    assert "WEB_SEARCH_CSE_ID=WEB_SEARCH_CSE_ID:latest" in api_secrets
    assert "WEB_SEARCH_API_KEY" in text
    assert "WEB_SEARCH_CSE_ID" in text

