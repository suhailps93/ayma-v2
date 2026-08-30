"""Ayma LiveKit voice agent worker (ARCHITECTURE §1.1, §10.1, §1.7 step 3).

A separate Cloud Run deployable from the Main API (`main.py`). It holds an
outbound connection to LiveKit Cloud waiting for job dispatch; on dispatch it
joins the room and bridges the participant's audio to a Gemini Live session and
back.

Current scope:

* base persona instructions (shared `persona.md`, same character as `/chat`),
* default voice from `config.py`,
* Gemini Live's native turn detection — no client/server VAD tuning,
* Step 15: native input/output transcription, relayed to the client as
  ``user_transcript`` / ``agent_transcript`` data-channel events (§1.6).

Deferred to their own steps: recent-turns / wiki prompt seeding (§1.5 / §13.5,
Steps 17 / 24), `/post-turn` persistence (Step 19), barge-in playback handling
(§1.3, Step 18).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys

# Local dev only: load repo-root .env files before anything reads the
# environment (AGENTS.md §"Data & credentials"). Skipped under pytest and a
# no-op in the deployed container, which has no .env file.
if "pytest" not in sys.modules:  # pragma: no cover - dev/deploy only
    from pathlib import Path

    from dotenv import load_dotenv

    for _parent in Path(__file__).resolve().parents:
        if (_parent / ".env.local").exists() or (_parent / ".env").exists():
            load_dotenv(_parent / ".env.local")
            load_dotenv(_parent / ".env")
            break

from google.genai import types  # noqa: E402
from livekit.agents import (  # noqa: E402 - must follow the dotenv load
    Agent,
    AgentSession,
    ConversationItemAddedEvent,
    JobContext,
    RoomOutputOptions,
    UserInputTranscribedEvent,
    WorkerOptions,
    cli,
)
from livekit.plugins.google.realtime import RealtimeModel  # noqa: E402

from config import CONFIG  # noqa: E402
from prompt import compose_system_prompt  # noqa: E402

logger = logging.getLogger("ayma.agent")

# Data-channel topics the client listens on for the unified transcript (§1.6).
TOPIC_USER_TRANSCRIPT = "user_transcript"
TOPIC_AGENT_TRANSCRIPT = "agent_transcript"


def build_realtime_model() -> RealtimeModel:
    """Construct the Gemini Live model.

    Auth mirrors the Main API (`gemini.py`): Vertex AI with the Cloud Run
    runtime identity when ``USE_VERTEX`` is set, otherwise the Gemini Developer
    API with ``GOOGLE_API_KEY`` from the environment. The model id and default
    voice come only from ``config.py`` (AGENTS.md).
    """
    kwargs: dict[str, object] = {
        "model": CONFIG.gemini_live_model,
        "voice": CONFIG.gemini_live_voice,
        "temperature": 0.9,
        # Native Gemini Live transcription of both sides of the call (§1.6,
        # §1.7 step 11) — explicit rather than relying on the plugin default.
        "input_audio_transcription": types.AudioTranscriptionConfig(),
        "output_audio_transcription": types.AudioTranscriptionConfig(),
    }
    if CONFIG.use_vertex:
        kwargs["vertexai"] = True
        if CONFIG.project_id:
            kwargs["project"] = CONFIG.project_id
        kwargs["location"] = CONFIG.vertex_location
    return RealtimeModel(**kwargs)


def _publish_transcript(
    ctx: JobContext, topic: str, text: str, is_final: bool
) -> None:
    """Fire-and-forget a transcript segment onto the room data channel."""
    text = text.strip()
    if not text:
        return
    payload = json.dumps({"text": text, "is_final": is_final}).encode()

    async def _send() -> None:
        try:
            await ctx.room.local_participant.publish_data(
                payload, reliable=True, topic=topic
            )
        except Exception:  # noqa: BLE001 - a dropped segment must not kill the call
            logger.exception("failed to publish %s segment", topic)

    asyncio.create_task(_send())


def relay_transcripts(ctx: JobContext, session: AgentSession) -> None:
    """Relay Gemini Live's native transcription to the client as
    ``user_transcript`` / ``agent_transcript`` data-channel events (§1.6).

    The framework's built-in transcription forwarding is turned off in
    ``session.start`` so the client has exactly one delivery path to parse
    (§1.7 step 12).
    """

    @session.on("user_input_transcribed")
    def _on_user(ev: UserInputTranscribedEvent) -> None:
        _publish_transcript(
            ctx, TOPIC_USER_TRANSCRIPT, ev.transcript, ev.is_final
        )

    @session.on("conversation_item_added")
    def _on_item(ev: ConversationItemAddedEvent) -> None:
        if ev.item.role != "assistant":
            return
        _publish_transcript(
            ctx, TOPIC_AGENT_TRANSCRIPT, ev.item.text_content or "", True
        )


async def entrypoint(ctx: JobContext) -> None:
    """Join the dispatched room and run one Gemini Live voice session."""
    await ctx.connect()
    session = AgentSession(llm=build_realtime_model())
    relay_transcripts(ctx, session)
    await session.start(
        agent=Agent(instructions=compose_system_prompt()),
        room=ctx.room,
        room_output_options=RoomOutputOptions(transcription_enabled=False),
    )


def worker_options() -> WorkerOptions:
    return WorkerOptions(
        entrypoint_fnc=entrypoint,
        # Cloud Run assigns the container port ($PORT); the worker's health
        # server must bind it so the startup probe passes. Falls back to the
        # livekit-agents default when run outside Cloud Run.
        port=int(os.getenv("PORT", "8081")),
        # Scale-to-zero service — keep the pre-forked job pool tiny.
        num_idle_processes=1,
        drain_timeout=int(os.getenv("AGENT_DRAIN_TIMEOUT", "30")),
    )


if __name__ == "__main__":
    cli.run_app(worker_options())
