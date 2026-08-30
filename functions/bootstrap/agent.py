"""Ayma LiveKit voice agent worker (ARCHITECTURE §1.1, §10.1, §1.7 step 3).

A separate Cloud Run deployable from the Main API (`main.py`). It holds an
outbound connection to LiveKit Cloud waiting for job dispatch; on dispatch it
joins the room and bridges the participant's audio to a Gemini Live session and
back.

Step 13 is the minimal bridge only:

* base persona instructions (shared `persona.md`, same character as `/chat`),
* default voice from `config.py`,
* Gemini Live's native turn detection — no client/server VAD tuning.

Deferred to their own steps: transcription relay (§1.6, Step 15), recent-turns
/ wiki prompt seeding (§1.5 / §13.5, Steps 17 / 24), `/post-turn` persistence
(Step 19), barge-in playback handling (§1.3, Step 18).
"""

from __future__ import annotations

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

from livekit.agents import (  # noqa: E402 - must follow the dotenv load
    Agent,
    AgentSession,
    JobContext,
    WorkerOptions,
    cli,
)
from livekit.plugins.google.realtime import RealtimeModel  # noqa: E402

from config import CONFIG  # noqa: E402
from prompt import compose_system_prompt  # noqa: E402


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
    }
    if CONFIG.use_vertex:
        kwargs["vertexai"] = True
        if CONFIG.project_id:
            kwargs["project"] = CONFIG.project_id
        kwargs["location"] = CONFIG.vertex_location
    return RealtimeModel(**kwargs)


async def entrypoint(ctx: JobContext) -> None:
    """Join the dispatched room and run one Gemini Live voice session."""
    await ctx.connect()
    session = AgentSession(llm=build_realtime_model())
    await session.start(
        agent=Agent(instructions=compose_system_prompt()),
        room=ctx.room,
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
