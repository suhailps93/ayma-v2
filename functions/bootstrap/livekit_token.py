"""LiveKit access-token minting for ``POST /bootstrap`` (ARCHITECTURE §1.1, §3.4).

The client never sees the LiveKit API secret. ``/bootstrap`` verifies the
Firebase ID token first, then calls :func:`mint_access_token` to produce a
short-lived, room-scoped LiveKit JWT. Secret values (``LIVEKIT_API_KEY`` /
``LIVEKIT_API_SECRET``) are read from the environment at call time and never
stored in the repo (AGENTS.md §"Data & credentials").
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import secrets
import time
from datetime import timedelta

from livekit import api

import schema
from config import CONFIG
from transcript import Turn

logger = logging.getLogger("ayma.livekit_token")


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


# --- staging/prod agent dispatch guard (ARCHITECTURE §1.1a) -----------------
# Staging and prod share one funded LiveKit project ("Aimma"), so LiveKit offers
# every room in that project to BOTH the staging and the prod agent worker. The
# only thing that distinguishes a staging room from a prod room is its NAME:
# staging names every room ``ayma-staging-*`` (its LIVEKIT_ROOM_PREFIX), prod
# uses ``ayma-*``. On 2026-11-01 the prod agent, offered a staging room, joined
# it and wrote an app_command into PROD Firestore. These helpers let each worker
# decline rooms that belong to the OTHER environment BEFORE it accepts the job.
STAGING_ROOM_PREFIX = "ayma-staging-"


def is_staging_room_name(name: str | None) -> bool:
    """Whether ``name`` is a staging room (its name starts with the staging
    prefix). ``ayma-staging-`` deliberately also starts with the prod prefix
    ``ayma-``, so a plain ``startswith('ayma-')`` can never separate the two —
    the staging prefix is matched explicitly here."""
    return (name or "").startswith(STAGING_ROOM_PREFIX)


def this_agent_serves_staging() -> bool:
    """Whether THIS worker process is the staging agent, decided solely by the
    room prefix it is configured with (``LIVEKIT_ROOM_PREFIX`` →
    ``CONFIG.livekit_room_prefix``). Default-safe: only an explicit
    ``ayma-staging-`` prefix counts as staging; the prod default ``ayma-`` and
    any blank/other value are NOT staging, so a prod — or ambiguously
    configured — worker is never treated as staging."""
    return CONFIG.livekit_room_prefix.startswith(STAGING_ROOM_PREFIX)


def room_env_mismatch(name: str | None) -> bool:
    """Whether this worker must DECLINE ``name`` because it belongs to the other
    environment: a staging room may be served only by the staging agent, and a
    non-staging (prod) room only by a non-staging agent. Default-safe — a blank
    or unparsable name is treated as a prod room, so the prod agent still serves
    it while the staging agent (which serves only ``ayma-staging-`` rooms)
    declines it, and the prod agent never joins a staging room no matter how its
    env is set."""
    return is_staging_room_name(name) != this_agent_serves_staging()


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
    voice_accent: str = "",
    greeting_instructions: str = "",
    practice: bool = False,
    practice_return: bool = False,
    persona_name: str = "",
    persona_gender: str = "",
    target_uid: str = "",
    voice_mode: str = "",
    realtime_model_id: str = "",
    brain_id: str = "",
    stt_id: str = "",
    tts_id: str = "",
    tts_voice: str = "",
    voice_agent_cloud: str = "cloudrun",
) -> str:
    """JSON the agent worker reads from room metadata: the caller's system
    prompt + recent-turns window (§1.4, §1.5), the ids it needs to persist the
    session's ``raw_turns`` on shutdown (§1.7 step 8), and the user's
    ``ayma_voice_name`` / ``ayma_voice_language`` preferences (§13.3).

    ``practice`` (Practice Date voice, hackathon B) flags a *simulated-match*
    room: ``system_prompt`` is then the persona prompt
    (``practice_date.compose_persona_prompt``) and the agent runs the practice
    path (no Ayma tools, no memory flush/wiki ingest, a side-channel live
    coach) instead of a normal Ayma call. ``persona_name`` / ``persona_gender`` /
    ``target_uid`` let the agent drive the live coach (with the right pronouns),
    pick a gender-matched TTS voice, and persist the practice transcript for the
    debrief, WITHOUT ever re-reading the target's profile (the persona prompt
    already carries only the viewer-visible, never-load-filtered facts)."""
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
            # Dedicated free-text ACCENT (``ayma_voice_accent``, §13.9): fed to an
            # accent-capable provider at session boot (``agent._accent_block``).
            "voice_accent": voice_accent,
            # Per-user MAIN-voice STACK selection (§13.9). Empty ``voice_mode`` =
            # use the deploy-time CONFIG.llm_provider_voice_main default; set it
            # ("realtime"/"cascade") and the component ids override it for this
            # call only (``agent._run_session``).
            "voice_mode": voice_mode,
            "realtime_model_id": realtime_model_id,
            "brain_id": brain_id,
            "stt_id": stt_id,
            "tts_id": tts_id,
            "tts_voice": tts_voice,
            "greeting_instructions": greeting_instructions,
            "practice": practice,
            # This session is the debrief that opened right after a practice call
            # ended (``/bootstrap practice_return_session_id``). The agent must not
            # let it auto-launch another practice/sim (the practice-restart loop,
            # prod feedback SNzmb0u51H8khJenNntn) — see ``agent`` + ``voice_actions
            # .verdict_to_command(is_practice_return=...)``.
            "practice_return": practice_return,
            "persona_name": persona_name,
            "persona_gender": persona_gender,
            "target_uid": target_uid,
            # Dual-cloud agent dispatch marker (§1.1): which cloud's worker
            # should serve this room. The Cloud Run worker (automatic dispatch,
            # which LiveKit still offers EVERY room including explicitly-routed
            # ones) reads this in its ``request_fnc`` and declines a room marked
            # ``livekit`` so the two deployments never both join; "" / absent /
            # ``cloudrun`` is served by Cloud Run exactly as today.
            "voice_agent_cloud": voice_agent_cloud or "cloudrun",
        }
    )


async def seed_room_context(
    room: str, seed_json: str, agent_name: str | None = None
) -> None:
    """Attach ``seed_json`` to the LiveKit room as metadata before the client
    joins, so the dispatched agent (§1.2) can read it in ``entrypoint``.

    ``agent_name`` picks the dispatch model for this room (§1.1, dual-cloud
    agent):

    * ``None`` — the room is created with NO explicit agent dispatch, so
      LiveKit's AUTOMATIC dispatch hands it to the Cloud Run worker. Used for
      ``cloudrun``-routed rooms (an explicit user opt-out, or the failure-only
      fallback in :func:`watch_hosted_dispatch`).
    * a name (e.g. ``"ayma-lk"``) — the room is created with EXPLICIT dispatch
      to that agent, so the LiveKit-Cloud-hosted worker (registered under that
      ``agent_name``) serves it. The Cloud Run worker is still offered the room
      by automatic dispatch and declines it via its ``request_fnc`` guard
      (``agent._should_serve``), so the two never both join.

    Best-effort: a failure here must not block a voice session from starting —
    the agent falls back to the base persona with no history.
    """
    lk = api.LiveKitAPI()
    try:
        create = api.CreateRoomRequest(
            name=room,
            metadata=seed_json,
            empty_timeout=CONFIG.livekit_room_empty_timeout_seconds,
            departure_timeout=CONFIG.livekit_room_departure_timeout_seconds,
        )
        if agent_name:
            # Explicit agent dispatch: attach the named agent at room creation
            # so the LiveKit-hosted worker is dispatched the moment the room
            # exists (same trigger point as today's automatic dispatch).
            create.agents.append(api.RoomAgentDispatch(agent_name=agent_name))
        try:
            await lk.room.create_room(create)
        except api.TwirpError:
            pass  # room already exists — the update below carries the metadata
        await lk.room.update_room_metadata(
            api.UpdateRoomMetadataRequest(room=room, metadata=seed_json)
        )
    finally:
        await lk.aclose()


def resolve_voice_agent_cloud(db, uid: str) -> str:
    """Which cloud serves this user's next voice call (§1.1, dual-cloud
    agent): ``"livekit"`` (the default — the hosted ``ayma-lk`` worker) or
    ``"cloudrun"`` (the user's explicit opt-out pref, ``PF_AYMA_VOICE_CLOUD``).
    Any unknown/absent value falls back to ``schema.VOICE_AGENT_CLOUD_DEFAULT``
    (the one authoritative default). Shared by ``POST /bootstrap`` and
    Practice Date voice so every voice room resolves its target cloud the
    same way (Practice Date originally skipped the resolution entirely and
    always landed on Cloud Run)."""
    try:
        snap = schema.profile_doc(db, uid).get()
        val = str(
            (snap.to_dict() or {}).get(schema.PF_AYMA_VOICE_CLOUD, "")
        ).strip()
    except Exception:  # noqa: BLE001 - never block a voice start on this read
        logger.exception("could not read voice_agent_cloud for %s", uid)
        return schema.VOICE_AGENT_CLOUD_DEFAULT
    return val if val in schema.VOICE_AGENT_CLOUDS else schema.VOICE_AGENT_CLOUD_DEFAULT


# --- hosted-dispatch failure DETECTION (§1.1) ------------------------------
#
# Founder policy: all voice runs on the LiveKit-Cloud hosted worker
# (``ayma-lk``). The GCP Cloud Run workers (``ayma-agent`` / ``ayma-agent-staging``)
# were DELETED on 2026-11-06 ("move voice to the hosted LiveKit worker"), so
# there is no Cloud Run worker to fall back to. This watcher therefore only
# DETECTS the one failure signal worth surfacing — a room routed to the hosted
# worker where no agent participant joins within the window — and logs it, so a
# "couldn't hear Ayma" incident leaves a server-side trail (prod feedback
# RFLpFWkaaCuDC0ew1MUT, 2026-11-14: an active voice session produced no agent
# speech, with no backend signal). It never flips the room's ``voice_agent_cloud``
# marker: flipping a slow room to ``cloudrun`` used to re-dispatch to the Cloud
# Run worker, but with that worker gone the flip only makes the hosted worker's
# ``request_fnc`` guard DECLINE the room on any re-offer — turning a slow join
# into permanent silence. Every other outcome — agent joined, room closed
# because the caller hung up, LiveKit API unreachable — leaves the room exactly
# as routed. (The per-user ``cloudrun`` opt-out and the unmarked-room guard
# default are a separate, deliberately-tested path whose Cloud Run target is
# also now gone; resolving them is a founder architecture decision, not this
# watcher's job.)

_HOSTED_DISPATCH_TIMEOUT_SECONDS = 15.0
_HOSTED_DISPATCH_POLL_SECONDS = 2.0
_AGENT_PARTICIPANT_KIND = 4  # ParticipantInfo.Kind.AGENT


async def _agent_joined(lk, room: str) -> bool | None:
    """True: an agent participant is in ``room``. False: the room exists but
    no agent has joined yet. None: the room no longer exists. A ``not_found``
    from the room service is the room-gone signal; any other error propagates
    so the caller can treat it as transient."""
    try:
        resp = await lk.room.list_participants(
            api.ListParticipantsRequest(room=room)
        )
    except api.TwirpError as exc:
        if exc.code == "not_found" or "not found" in str(exc).lower():
            return None
        raise
    return any(p.kind == _AGENT_PARTICIPANT_KIND for p in resp.participants)


async def _room_is_hosted_routed(lk, room: str) -> bool:
    """True iff ``room`` still exists and its ``voice_agent_cloud`` marker is
    ``livekit`` — i.e. the hosted worker is the one that was supposed to join.
    A missing/``cloudrun``/unparseable marker returns False, so the watcher
    never warns about a room the hosted worker was never meant to serve."""
    rooms = await lk.room.list_rooms(api.ListRoomsRequest(names=[room]))
    if not rooms.rooms:
        return False
    raw = (rooms.rooms[0].metadata or "").strip()
    try:
        seed = json.loads(raw) if raw else {}
    except ValueError:
        return False
    return seed.get("voice_agent_cloud") == "livekit"


async def watch_hosted_dispatch(
    room: str,
    *,
    timeout_seconds: float = _HOSTED_DISPATCH_TIMEOUT_SECONDS,
    poll_seconds: float = _HOSTED_DISPATCH_POLL_SECONDS,
) -> bool:
    """Detection-only watcher for one livekit-routed room (see the section
    comment above): returns True iff the hosted agent did not join within the
    window (logged as a warning), False otherwise. Never changes the room and
    never dispatches. Designed to run as a ``BackgroundTasks`` task — never
    raises."""
    try:
        lk = api.LiveKitAPI()
    except Exception:  # noqa: BLE001 - unconfigured LiveKit: nothing to watch
        logger.exception("hosted-dispatch watch could not start for room %s", room)
        return False
    try:
        deadline = time.monotonic() + timeout_seconds
        while True:
            try:
                joined = await _agent_joined(lk, room)
            except Exception:  # noqa: BLE001 - transient API error: keep waiting
                joined = False
            if joined is None:
                return False  # room already closed — caller gone, nothing to flag
            if joined:
                return False
            if time.monotonic() >= deadline:
                break
            await asyncio.sleep(poll_seconds)
        # Deadline passed with no agent. Only flag rooms the hosted worker was
        # actually meant to serve (defence-in-depth — the watcher is armed only
        # for livekit-routed rooms), and re-check the join one last time so a
        # merely-slow agent that arrived during this read is not falsely flagged.
        if not await _room_is_hosted_routed(lk, room):
            return False
        if await _agent_joined(lk, room):
            return False
        logger.warning(
            "hosted agent did not join room %s within %.0fs — caller heard no "
            "agent audio (no Cloud Run fallback exists; hosted-only since "
            "2026-11-06)",
            room,
            timeout_seconds,
        )
        return True
    except Exception:  # noqa: BLE001 - a watcher must never take voice down
        logger.exception("hosted-dispatch watch failed for room %s", room)
        return False
    finally:
        await lk.aclose()
