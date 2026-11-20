"""Prod-safety pins for scripts/deploy-agent-livekit.sh (the LiveKit Cloud
Agents deploy).

`lk agent deploy` picks the TARGET agent from the staged livekit.toml's
``agent.id`` — NOT from the script's env vars. So AGENT_TARGET_ENV=staging must
stage a SEPARATE staging livekit.toml (ayma-lk-stg = CA_v9j5RgwMwHSD), or a
staging deploy would silently land on the PROD agent (ayma-lk =
CA_bJMNunTLpVqk). These tests pin that routing + the fail-closed id assertion so
the trap (founder/Astro, 2026-11-20) can never come back.
"""

from __future__ import annotations

import re
from pathlib import Path

PROD_ID = "CA_bJMNunTLpVqk"   # ayma-lk
STAGING_ID = "CA_v9j5RgwMwHSD"  # ayma-lk-stg


def _root() -> Path:
    here = Path(__file__).resolve()
    for parent in here.parents:
        if (parent / "scripts" / "deploy-agent-livekit.sh").exists():
            return parent
    raise AssertionError("repo root with scripts/deploy-agent-livekit.sh not found")


def _script() -> str:
    return (_root() / "scripts" / "deploy-agent-livekit.sh").read_text()


def _toml_id(rel: str) -> str:
    text = (_root() / "functions" / "bootstrap" / rel).read_text()
    m = re.search(r'^\s*id\s*=\s*"([^"]*)"', text, re.MULTILINE)
    assert m, f"no agent.id in {rel}"
    return m.group(1)


# --- the two toml targets --------------------------------------------------


def test_prod_toml_keeps_the_prod_agent_id():
    # The repo livekit.toml is the PROD target and must never be repointed.
    assert _toml_id("livekit.toml") == PROD_ID


def test_staging_toml_exists_and_carries_the_staging_agent_id():
    staging = _root() / "functions" / "bootstrap" / "livekit.staging.toml"
    assert staging.exists(), "functions/bootstrap/livekit.staging.toml is missing"
    assert _toml_id("livekit.staging.toml") == STAGING_ID
    # Same LiveKit project subdomain, DIFFERENT agent resource from prod.
    assert 'subdomain = "aimma-wt34nu3l"' in staging.read_text()
    assert _toml_id("livekit.staging.toml") != _toml_id("livekit.toml")
    # And the staging toml must not carry the prod id anywhere.
    assert PROD_ID not in staging.read_text()


# --- the script routes each env to its own toml + id -----------------------


def test_script_stages_the_env_specific_toml_not_a_hardcoded_one():
    s = _script()
    # The build dir's livekit.toml is copied from the per-env TARGET_LIVEKIT_TOML,
    # never a hardcoded "$SRC/livekit.toml".
    assert 'cp "$SRC/$TARGET_LIVEKIT_TOML" "$STAGE/livekit.toml"' in s
    assert 'cp "$SRC/livekit.toml" "$STAGE/livekit.toml"' not in s


def test_staging_env_block_selects_the_staging_toml_and_id():
    s = _script()
    assert 'TARGET_LIVEKIT_TOML="${TARGET_LIVEKIT_TOML:-livekit.staging.toml}"' in s
    assert f'TARGET_AGENT_ID="${{TARGET_AGENT_ID:-{STAGING_ID}}}"' in s


def test_prod_env_block_selects_the_prod_toml_and_id():
    s = _script()
    assert 'TARGET_LIVEKIT_TOML="${TARGET_LIVEKIT_TOML:-livekit.toml}"' in s
    assert f'TARGET_AGENT_ID="${{TARGET_AGENT_ID:-{PROD_ID}}}"' in s


def test_script_fails_closed_if_staged_id_mismatches_target():
    s = _script()
    # The staged toml's id is extracted and compared to TARGET_AGENT_ID, aborting
    # (non-zero) on any mismatch BEFORE a build — so staging can never deploy the
    # prod id and vice-versa.
    assert 'staged_id=' in s
    assert '[[ "$staged_id" != "$TARGET_AGENT_ID" ]]' in s
    assert 'exit 3' in s
