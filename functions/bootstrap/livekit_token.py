"""LiveKit access-token minting for ``POST /bootstrap`` (ARCHITECTURE §1.1, §3.4).

The client never sees the LiveKit API secret. ``/bootstrap`` verifies the
Firebase ID token first, then calls :func:`mint_access_token` to produce a
short-lived, room-scoped LiveKit JWT. Secret values (``LIVEKIT_API_KEY`` /
``LIVEKIT_API_SECRET``) are read from the environment at call time and never
stored in the repo (AGENTS.md §"Data & credentials").
"""

from __future__ import annotations

import json
import os
import secrets
from datetime import timedelta

from livekit import api

from config import CONFIG
from transcript import Turn


class LiveKitConfigError(RuntimeError):
    """Raised when LiveKit URL or signing credentials are absent from the env."""


def room_name_for(uid: str) -> str:
    """A fresh voice room name for one call: ``<prefix><uid>-<nonce>``.

    The agent worker is auto-dispatched only when LiveKit *creates* a room.
    A per-user name reused across calls meant a call started within the
    room's departure timeout of the previous one (a quick hang-up and
    redial, or a retry after "Ayma didn't pick up") joined the still-open
    old room, so no new agent job was ever dispatched and the caller sat in
    an empty room until the client gave up (2026-10-25, founder's phone:
    three back-to-back attempts kept that room alive and none got an
    agent). A new name per call always creates a new room and a new job."""
    return f"{CONFIG.livekit_room_prefix}{uid}-{secrets.token_urlsafe(8)}"


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


def build_room_seed(
    system_prompt: str,
    recent_turns: list[Turn],
    uid: str,
    session_id: str,
    voice_name: str = "",
    voice_language: str = "",
    greeting_instructions: str = "",
) -> str:
    """JSON the agent worker reads from room metadata: the caller's system
    prompt + recent-turns window (§1.4, §1.5), the ids it needs to persist the
    session's ``raw_turns`` on shutdown (§1.7 step 8), and the user's
    ``ayma_voice_name`` / ``ayma_voice_language`` preferences (§13.3)."""
    return json.dumps(
        {
            "system_prompt": system_prompt,
            "recent_turns": [
                {"role": t.role, "text": t.text} for t in recent_turns
            ],
            "uid": uid,
            "session_id": session_id,
            "voice_name": voice_name,
            "voice_language": voice_language,
            "greeting_instructions": greeting_instructions,
        }
    )


async def seed_room_context(room: str, seed_json: str) -> None:
    """Attach ``seed_json`` to the LiveKit room as metadata before the client
    joins, so the auto-dispatched agent (§1.2) can read it in ``entrypoint``.

    Best-effort: a failure here must not block a voice session from starting —
    the agent falls back to the base persona with no history.
    """
    lk = api.LiveKitAPI()
    try:
        try:
            await lk.room.create_room(
                api.CreateRoomRequest(
                    name=room,
                    metadata=seed_json,
                    empty_timeout=CONFIG.livekit_room_empty_timeout_seconds,
                    departure_timeout=CONFIG.livekit_room_departure_timeout_seconds,
                )
            )
        except api.TwirpError:
            pass  # room already exists — the update below carries the metadata
        await lk.room.update_room_metadata(
            api.UpdateRoomMetadataRequest(room=room, metadata=seed_json)
        )
    finally:
        await lk.aclose()
