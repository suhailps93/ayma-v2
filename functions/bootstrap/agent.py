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

Deferred to their own steps: wiki prompt seeding (§13.5, Step 24) and memory
extraction into ``wiki_pages`` (§2.3, Step 21).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
from dataclasses import dataclass, field

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
    AgentStateChangedEvent,
    ConversationItemAddedEvent,
    JobContext,
    RoomOutputOptions,
    UserInputTranscribedEvent,
    WorkerOptions,
    cli,
    function_tool,
    llm,
)
from livekit.plugins.google.realtime import RealtimeModel  # noqa: E402

from config import CONFIG  # noqa: E402
from db import get_db  # noqa: E402
from post_turn import persist_raw_turns  # noqa: E402
from prompt import compose_system_prompt  # noqa: E402
from skills import FOLLOWUP_DESCRIPTION, make_add_followup_question  # noqa: E402
from transcript import ROLE_AYMA, ROLE_USER, Turn  # noqa: E402

logger = logging.getLogger("ayma.agent")

# Data-channel topics the client listens on.
TOPIC_USER_TRANSCRIPT = "user_transcript"  # §1.6
TOPIC_AGENT_TRANSCRIPT = "agent_transcript"  # §1.6
TOPIC_AGENT_STATE = "agent_state"  # §1.3 — drives the client's speaking/barge-in UI


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


def relay_transcripts(
    ctx: JobContext,
    session: AgentSession,
    collector: list[Turn] | None = None,
) -> None:
    """Relay Gemini Live's native transcription to the client as
    ``user_transcript`` / ``agent_transcript`` data-channel events (§1.6), and
    (when ``collector`` is given) record each finalized turn for the session's
    ``raw_turns`` persistence on shutdown (§1.7 step 8).

    The framework's built-in transcription forwarding is turned off in
    ``session.start`` so the client has exactly one delivery path to parse
    (§1.7 step 12).
    """

    @session.on("user_input_transcribed")
    def _on_user(ev: UserInputTranscribedEvent) -> None:
        _publish_transcript(
            ctx, TOPIC_USER_TRANSCRIPT, ev.transcript, ev.is_final
        )
        if collector is not None and ev.is_final and ev.transcript.strip():
            collector.append(Turn(ROLE_USER, ev.transcript.strip()))

    @session.on("conversation_item_added")
    def _on_item(ev: ConversationItemAddedEvent) -> None:
        if ev.item.role != "assistant":
            return
        text = (ev.item.text_content or "").strip()
        _publish_transcript(ctx, TOPIC_AGENT_TRANSCRIPT, text, True)
        if collector is not None and text:
            collector.append(Turn(ROLE_AYMA, text))


def relay_agent_state(ctx: JobContext, session: AgentSession) -> None:
    """Publish the agent's speaking/listening/thinking state to the client
    (§1.3). This is the authoritative signal for the client's "Ayma is
    speaking" indicator and its barge-in playback stop (§1.7 step 10): when
    Gemini Live's native turn-detection interrupts a reply, the state leaves
    ``speaking`` and the client clears buffered agent audio at once. No custom
    VAD anywhere — interruption is entirely Gemini Live's (§1.7 step 9)."""

    @session.on("agent_state_changed")
    def _on_state(ev: AgentStateChangedEvent) -> None:
        payload = json.dumps({"state": ev.new_state}).encode()

        async def _send() -> None:
            try:
                await ctx.room.local_participant.publish_data(
                    payload, reliable=True, topic=TOPIC_AGENT_STATE
                )
            except Exception:  # noqa: BLE001
                logger.exception("failed to publish agent_state")

        asyncio.create_task(_send())


@dataclass
class RoomSeed:
    system_prompt: str
    chat_ctx: "llm.ChatContext | None" = None
    uid: str = ""
    session_id: str = ""
    seed_turns: list[Turn] = field(default_factory=list)


def _read_room_seed(ctx: JobContext) -> RoomSeed:
    """Pull the system prompt, recent-turns window and persistence ids that
    ``POST /bootstrap`` left on the room metadata (§1.4, §1.5, §1.7 step 8).
    Falls back to the base persona and no history when metadata is absent or
    unreadable."""
    raw = (ctx.room.metadata or "").strip()
    if not raw:
        return RoomSeed(system_prompt=compose_system_prompt())
    try:
        seed = json.loads(raw)
    except ValueError:
        logger.warning("unparseable room metadata; using base persona")
        return RoomSeed(system_prompt=compose_system_prompt())

    turns = [
        Turn(role=str(t.get("role", "")), text=str(t.get("text", "")))
        for t in seed.get("recent_turns", [])
        if str(t.get("text", "")).strip()
    ]
    system_prompt = seed.get("system_prompt") or compose_system_prompt(
        recent_turns=turns
    )

    chat_ctx: llm.ChatContext | None = None
    if turns:
        chat_ctx = llm.ChatContext.empty()
        for turn in turns:
            chat_ctx.add_message(
                role="assistant" if turn.role == ROLE_AYMA else "user",
                content=turn.text,
            )
    return RoomSeed(
        system_prompt=system_prompt,
        chat_ctx=chat_ctx,
        uid=str(seed.get("uid", "")),
        session_id=str(seed.get("session_id", "")),
        seed_turns=turns,
    )


def _session_tools(uid: str) -> list:
    """Shared agent tools bound to this session (§13.6). Step 22: just
    ``add_followup_question``."""
    if not uid:
        return []
    fn = make_add_followup_question(get_db(), uid)
    return [
        function_tool(
            fn,
            name="add_followup_question",
            description=FOLLOWUP_DESCRIPTION,
        )
    ]


async def entrypoint(ctx: JobContext) -> None:
    """Join the dispatched room and run one Gemini Live voice session."""
    await ctx.connect()
    seed = _read_room_seed(ctx)

    # The full session window = the turns carried in from /bootstrap plus every
    # finalized voice turn from here on. Written to raw_turns on shutdown.
    window: list[Turn] = list(seed.seed_turns)

    async def _persist_on_shutdown() -> None:
        if not seed.uid or not seed.session_id or not window:
            return
        try:
            persist_raw_turns(get_db(), seed.uid, seed.session_id, window)
        except Exception:  # noqa: BLE001 - shutdown must not raise
            logger.exception("raw_turns persist failed for %s", seed.session_id)

    ctx.add_shutdown_callback(_persist_on_shutdown)

    # allow_interruptions defaults on; stated here so the "no custom VAD, native
    # turn-detection only" decision (§1.7 step 9) is visible at the call site.
    session = AgentSession(llm=build_realtime_model(), allow_interruptions=True)
    relay_transcripts(ctx, session, collector=window)
    relay_agent_state(ctx, session)
    tools = _session_tools(seed.uid)
    agent_kwargs: dict = {"instructions": seed.system_prompt, "tools": tools}
    if seed.chat_ctx is not None:
        agent_kwargs["chat_ctx"] = seed.chat_ctx
    agent = Agent(**agent_kwargs)
    await session.start(
        agent=agent,
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
