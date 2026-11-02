"""Staging/prod agent dispatch guard by room-name prefix (ARCHITECTURE §1.1a).

Staging and prod share one funded LiveKit project ("Aimma"), so LiveKit offers
every room to BOTH agent workers. The only signal separating a staging room
from a prod room is its NAME (staging names rooms ``ayma-staging-*``; prod
``ayma-*``). On 2026-11-01 the prod agent, offered a staging room, joined it and
wrote an app_command into PROD Firestore. ``livekit_token.room_env_mismatch`` is
the decision the dispatch seam (``agent._request_fnc``) uses to DECLINE a
foreign-environment room before it accepts the job — tested here without the
agent dependency set, which the Main API venv does not carry.

The dispatch seam itself (``_request_fnc`` actually calling ``reject`` before
any room join or Firestore write, including the Nov-1 prod-grabs-staging
specimen) is covered in ``test_agent.py`` and runs where ``livekit.agents`` is
installed.
"""

import dataclasses

import livekit_token
from config import CONFIG


def _with_prefix(monkeypatch, prefix):
    """Point the module's CONFIG (frozen) at a copy with the given room prefix,
    simulating that worker's ``LIVEKIT_ROOM_PREFIX`` env."""
    monkeypatch.setattr(
        livekit_token,
        "CONFIG",
        dataclasses.replace(CONFIG, livekit_room_prefix=prefix),
    )


# (i) STAGING-configured agent: serves ONLY ayma-staging-* rooms.
def test_staging_agent_accepts_staging_room_rejects_prod(monkeypatch):
    _with_prefix(monkeypatch, "ayma-staging-")
    assert livekit_token.this_agent_serves_staging() is True
    # Accepts its own staging room (no mismatch => dispatch guard accepts).
    assert livekit_token.room_env_mismatch("ayma-staging-abc") is False
    # Rejects a prod room (ayma-*) and any non-prefixed room.
    assert livekit_token.room_env_mismatch("ayma-me-xyz") is True
    assert livekit_token.room_env_mismatch("prod-room-1") is True


# (ii) PROD-configured agent: the Nov-1 specimen — MUST reject the staging room.
def test_prod_agent_rejects_staging_room_accepts_prod(monkeypatch):
    _with_prefix(monkeypatch, "ayma-")  # prod default
    assert livekit_token.this_agent_serves_staging() is False
    # The 2026-11-01 specimen: prod offered a staging room must DECLINE it.
    assert livekit_token.room_env_mismatch("ayma-staging-abc") is True
    # Normal prod rooms are served exactly as before.
    assert livekit_token.room_env_mismatch("ayma-me-xyz") is False
    assert livekit_token.room_env_mismatch("prod-room-1") is False


# (iii) Ambiguous/missing env => default-safe: a prod context never serves a
# staging room.
def test_missing_or_ambiguous_env_never_serves_staging_from_prod(monkeypatch):
    for prefix in ("", "ayma-", "something-else-"):
        _with_prefix(monkeypatch, prefix)
        assert livekit_token.this_agent_serves_staging() is False
        # Whatever the ambiguous prefix, a staging room is declined.
        assert livekit_token.room_env_mismatch("ayma-staging-abc") is True


# Blank/unparsable room name is treated as a prod room (served by prod, declined
# by staging) — never mis-served as staging from a prod context.
def test_blank_room_name_is_treated_as_prod(monkeypatch):
    _with_prefix(monkeypatch, "ayma-")
    assert livekit_token.room_env_mismatch(None) is False
    assert livekit_token.room_env_mismatch("") is False
    _with_prefix(monkeypatch, "ayma-staging-")
    assert livekit_token.room_env_mismatch(None) is True


def test_staging_prefix_is_not_confused_with_prod_prefix():
    # ayma-staging- deliberately starts with ayma-, so the guard must match the
    # staging prefix explicitly, not a bare ayma- startswith.
    assert livekit_token.is_staging_room_name("ayma-staging-abc") is True
    assert livekit_token.is_staging_room_name("ayma-me-xyz") is False
    assert livekit_token.STAGING_ROOM_PREFIX.startswith("ayma-")
