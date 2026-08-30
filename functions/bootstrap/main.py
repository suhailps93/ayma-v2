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

from fastapi import Depends, FastAPI  # noqa: E402  - must follow the dotenv load
from pydantic import BaseModel, Field  # noqa: E402

from fastapi import HTTPException  # noqa: E402

from auth import require_uid  # noqa: E402
from config import CONFIG  # noqa: E402
import gemini  # noqa: E402
from livekit_token import (  # noqa: E402
    LiveKitConfigError,
    mint_access_token,
    room_name_for,
)
from prompt import compose_system_prompt  # noqa: E402

app = FastAPI(title="Ayma Main API", version=CONFIG.version)


@app.get("/health")
def health() -> dict[str, str]:
    """Liveness probe.

    Intentionally unauthenticated — the ID-token middleware added in a later
    step (§10.4) explicitly exempts this route.
    """
    return {"status": "ok", "service": "ayma-api", "version": CONFIG.version}


@app.post("/bootstrap")
async def bootstrap(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Session bootstrap (§1.7 step 3, §1.1).

    Step 12: mints the short-lived, room-scoped LiveKit access token the client
    uses to join its voice room, alongside the (still hardcoded) ``session_mode``
    from Step 6. Real ``session_mode`` derivation lands in Step 34 (§3.3); the
    agent worker that seeds the room's Gemini Live session is Step 13.
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


@app.post("/chat")
async def chat(
    req: ChatRequest, uid: str = Depends(require_uid)
) -> dict[str, str]:
    """Text chat turn (§1.7 step 2).

    Step 11: a real single-turn Gemini call seeded with the base persona
    (§13.1/§13.4). No wiki memory yet (Step 24), no session_mode scoping yet
    (Step 33).
    """
    try:
        reply = await gemini.generate_reply(
            req.message, system_prompt=compose_system_prompt()
        )
    except Exception as exc:  # noqa: BLE001 - surface any model/transport failure as 502
        raise HTTPException(
            status_code=502, detail=f"Gemini call failed: {exc}"
        ) from exc
    return {"reply": reply}
