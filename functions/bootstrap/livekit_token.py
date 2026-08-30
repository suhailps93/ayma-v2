"""LiveKit access-token minting for ``POST /bootstrap`` (ARCHITECTURE §1.1, §3.4).

The client never sees the LiveKit API secret. ``/bootstrap`` verifies the
Firebase ID token first, then calls :func:`mint_access_token` to produce a
short-lived, room-scoped LiveKit JWT. Secret values (``LIVEKIT_API_KEY`` /
``LIVEKIT_API_SECRET``) are read from the environment at call time and never
stored in the repo (AGENTS.md §"Data & credentials").
"""

from __future__ import annotations

import os
from datetime import timedelta

from livekit import api

from config import CONFIG


class LiveKitConfigError(RuntimeError):
    """Raised when LiveKit URL or signing credentials are absent from the env."""


def room_name_for(uid: str) -> str:
    """Deterministic per-user voice room name — a user has one voice session at
    a time, and the agent worker (Step 13) is dispatched by room name."""
    return f"{CONFIG.livekit_room_prefix}{uid}"


def mint_access_token(uid: str, room: str) -> str:
    """Return a signed LiveKit JWT granting ``uid`` join access to ``room``.

    Raises :class:`LiveKitConfigError` if the signing credentials are missing so
    the caller can surface a clear 503 rather than emitting an unsigned token.
    """
    api_key = os.getenv("LIVEKIT_API_KEY")
    api_secret = os.getenv("LIVEKIT_API_SECRET")
    if not api_key or not api_secret:
        raise LiveKitConfigError(
            "LIVEKIT_API_KEY / LIVEKIT_API_SECRET are not set in the environment."
        )

    grants = api.VideoGrants(
        room_join=True,
        room=room,
        can_publish=True,
        can_subscribe=True,
        can_publish_data=True,
    )
    token = (
        api.AccessToken(api_key, api_secret)
        .with_identity(uid)
        .with_name(uid)
        .with_grants(grants)
        .with_ttl(timedelta(seconds=CONFIG.livekit_token_ttl_seconds))
    )
    return token.to_jwt()
