"""Ayma Main API — Cloud Run service (see ``docs/ARCHITECTURE.md`` §10.1).

Step 1 scaffolding: a single unauthenticated health-check route. The real
endpoint surface (§10.2) and the shared auth / cron middleware (§10.4, §10.5)
land in later steps per ``PLAN.md``.
"""

from __future__ import annotations

import sys

# Local dev only: load config/secrets from the gitignored repo-root .env files,
# at the top of the entrypoint, before anything reads the environment
# (AGENTS.md §"Data & credentials"). Skipped under pytest so tests stay
# isolated from the developer's local environment. Deployed environments have
# no .env file — Cloud Run injects real env vars / mounted secrets.
if "pytest" not in sys.modules:  # pragma: no cover - deployment/dev only
    from pathlib import Path

    from dotenv import load_dotenv

    # Walk up from this file looking for the repo-root .env files. In the
    # deployed container there is no such file and this loop is a no-op.
    for _parent in Path(__file__).resolve().parents:
        if (_parent / ".env.local").exists() or (_parent / ".env").exists():
            load_dotenv(_parent / ".env.local")
            load_dotenv(_parent / ".env")
            break

import logging  # noqa: E402
from typing import Literal  # noqa: E402

from fastapi import (  # noqa: E402 - must follow the dotenv load
    BackgroundTasks,
    Body,
    Depends,
    FastAPI,
)
from pydantic import BaseModel, Field  # noqa: E402

from fastapi import HTTPException  # noqa: E402

from auth import require_uid  # noqa: E402
from config import CONFIG  # noqa: E402
import gemini  # noqa: E402
from livekit_token import (  # noqa: E402
    LiveKitConfigError,
    build_room_seed,
    mint_access_token,
    room_name_for,
    seed_room_context,
)
from db import get_db  # noqa: E402
from post_turn import persist_raw_turns  # noqa: E402
from prompt import compose_system_prompt  # noqa: E402
from skills import (  # noqa: E402
    make_session_tool_fns,
    session_tool_declarations,
)
from transcript import ROLE_AYMA, ROLE_USER, Turn  # noqa: E402
from wiki_ingest import ingest as wiki_ingest  # noqa: E402

logger = logging.getLogger("ayma.api")

# Cap on the recent-turns window a client may send (§1.5 — it is bounded
# client-side; the server enforces its own ceiling regardless).
_MAX_RECENT_TURNS = 200

# A client-owned id, stable for the lifetime of one chat screen (voice + text
# interleaved land in the same session doc). Optional on the wire; when absent
# the turn simply isn't persisted.
_SESSION_ID = Field(default="", max_length=128, pattern=r"^[A-Za-z0-9_-]*$")


class TurnModel(BaseModel):
    role: Literal["user", "ayma"]
    text: str = Field(min_length=1, max_length=4000)


def _to_turns(models: list[TurnModel]) -> list[Turn]:
    return [Turn(role=m.role, text=m.text) for m in models]


def _persist_session(uid: str, session_id: str, turns: list[Turn]) -> None:
    """Best-effort raw_turns upsert — never fails the request it rides on."""
    try:
        persist_raw_turns(get_db(), uid, session_id, turns)
    except Exception:  # noqa: BLE001
        logger.exception("failed to persist raw_turns for %s/%s", uid, session_id)


async def _run_ingest(uid: str, session_id: str, turns: list[Turn]) -> None:
    """Wiki ingest (§2.3), run after the response is sent. Best-effort."""
    try:
        written = await wiki_ingest(get_db(), uid, session_id, turns)
        if written:
            logger.info("wiki ingest wrote %d page(s) for %s", written, uid)
    except Exception:  # noqa: BLE001
        logger.exception("wiki ingest failed for %s", uid)

app = FastAPI(title="Ayma Main API", version=CONFIG.version)


@app.get("/health")
def health() -> dict[str, str]:
    """Liveness probe.

    Intentionally unauthenticated — the ID-token middleware added in a later
    step (§10.4) explicitly exempts this route.
    """
    return {"status": "ok", "service": "ayma-api", "version": CONFIG.version}


class BootstrapRequest(BaseModel):
    session_id: str = _SESSION_ID
    recent_turns: list[TurnModel] = Field(
        default_factory=list, max_length=_MAX_RECENT_TURNS
    )


@app.post("/bootstrap")
async def bootstrap(
    uid: str = Depends(require_uid),
    req: BootstrapRequest | None = Body(default=None),
) -> dict[str, object]:
    """Session bootstrap (§1.7 step 3, §1.1, §1.5).

    Mints the short-lived, room-scoped LiveKit token, and — when the client
    sends its recent-turns window — attaches the composed system prompt + that
    window to the room metadata so the auto-dispatched agent seeds its Gemini
    Live session with the same context ``/chat`` sees (Step 17). ``session_mode``
    is still the Step 6 stub; real derivation is Step 34.
    """
    if not CONFIG.livekit_url:
        raise HTTPException(
            status_code=503, detail="LIVEKIT_URL is not configured."
        )
    room = room_name_for(uid)
    try:
        token = mint_access_token(uid, room)
    except LiveKitConfigError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    turns = _to_turns(req.recent_turns) if req else []
    session_id = req.session_id if req else ""
    system_prompt = compose_system_prompt(recent_turns=turns)
    try:
        await seed_room_context(
            room, build_room_seed(system_prompt, turns, uid, session_id)
        )
    except Exception:  # noqa: BLE001 - seeding is best-effort, never blocks voice
        logger.exception("failed to seed room context for %s", room)

    if session_id and turns:
        _persist_session(uid, session_id, turns)

    return {
        "session_mode": CONFIG.bootstrap_stub_session_mode,
        "uid": uid,
        "livekit": {
            "token": token,
            "url": CONFIG.livekit_url,
            "room": room,
        },
    }


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)
    session_id: str = _SESSION_ID
    recent_turns: list[TurnModel] = Field(
        default_factory=list, max_length=_MAX_RECENT_TURNS
    )


@app.post("/chat")
async def chat(
    req: ChatRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, str]:
    """Text chat turn (§1.7 step 2, §1.5).

    The reply is seeded with the base persona plus the client's recent-turns
    window (§13.5), so a thought started by voice and finished by text is
    answered with full context (Step 17). On turn complete it persists the
    session's ``raw_turns`` and runs wiki ingest (§2.3) in the background. No
    wiki memory *read* yet (Step 24), no ``session_mode`` scoping yet (Step 33).
    """
    window = _to_turns(req.recent_turns)
    system_prompt = compose_system_prompt(recent_turns=window)
    try:
        reply = await gemini.generate_reply(
            req.message,
            system_prompt=system_prompt,
            tool_declarations=session_tool_declarations(),
            tool_fns=make_session_tool_fns(get_db(), uid),
        )
    except Exception as exc:  # noqa: BLE001 - surface any model/transport failure as 502
        raise HTTPException(
            status_code=502, detail=f"Gemini call failed: {exc}"
        ) from exc

    if req.session_id:
        full_window = window + [
            Turn(ROLE_USER, req.message),
            Turn(ROLE_AYMA, reply),
        ]
        _persist_session(uid, req.session_id, full_window)
        background.add_task(_run_ingest, uid, req.session_id, full_window)
    return {"reply": reply}


class PostTurnRequest(BaseModel):
    session_id: str = Field(max_length=128, pattern=r"^[A-Za-z0-9_-]+$")
    recent_turns: list[TurnModel] = Field(
        default_factory=list, max_length=_MAX_RECENT_TURNS
    )


@app.post("/post-turn")
async def post_turn(
    req: PostTurnRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Session-end persistence of the raw turn window (§1.7 step 8) + wiki
    ingest (§2.3, Step 21).

    The client calls this when a chat screen closes / a voice session ends;
    ``/chat`` also persists and ingests inline per turn.
    """
    turns = _to_turns(req.recent_turns)
    _persist_session(uid, req.session_id, turns)
    if turns:
        background.add_task(_run_ingest, uid, req.session_id, turns)
    return {"ok": True, "persisted": len(turns)}
