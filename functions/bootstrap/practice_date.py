"""Practice Date — rehearse talking to a match against a simulated persona.

Hackathon deliverable B. This module is the HTTP layer (the ``/practice/*``
FastAPI router); the fastapi-free domain logic — persona context (the privacy
boundary), prompt composition, the model calls, and the session store — lives
in ``practice_core.py`` and is re-exported here so the feature's public surface
is a single import. The split exists so the LiveKit voice agent worker
(``agent.py``), whose runtime carries no web stack, can import the practice
primitives from ``practice_core`` to run the simulated-persona voice session and
its live coach (see :func:`practice_voice_start`). The provider seam is
``practice_llm.py``; the prompts are the three ``prompts/practice_*.md`` files.

What it does: on a match's / Explore profile the user opens a clearly-labelled
*simulator* conversation (text or voice) where Ayma plays a persona built from
THAT person. The user practises their opener and banter; a live coach surfaces a
nudge after each of their messages; an end-of-session debrief says what worked,
what to say next, and what to avoid.

PRIVACY IS THE HEADLINE (judging asset). The persona is built ONLY from the
viewer-visible profile via :func:`practice_core.build_persona_context`; it reads
NOTHING from any ``NEVER_LOAD`` category (see ``practice_core`` and
``tests/test_practice_extraction.py``). The voice path crosses that boundary
exactly once, here, server-side: the seeded persona prompt is the same
:func:`compose_persona_prompt` output the text path uses.
"""

from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException
from firebase_admin import storage
from pydantic import BaseModel, Field

import age_gate
import agent_wake
import token_ledger
from auth import Caller, require_caller, require_uid
from config import CONFIG
from db import get_db
from livekit_token import (
    LiveKitConfigError,
    build_room_seed,
    mint_access_token,
    room_name_for,
    seed_room_context,
)

# Domain core (fastapi-free; also imported by the voice agent worker). Re-export
# the names the API endpoints, tests and scripts reference from this module.
from practice_core import (  # noqa: F401 - re-exported public surface
    NEVER_LOAD,
    PRACTICE_SESSIONS_COLLECTION,
    ROLE_MATCH,
    ROLE_USER,
    PersonaContext,
    _PERSONA_TOKEN,
    _load_session,
    append_turns,
    build_persona_context,
    coach_hint,
    compose_coach_prompt,
    compose_debrief_prompt,
    compose_persona_prompt,
    end_session,
    generate_debrief,
    persona_context_for_coach,
    persona_reply,
    start_session,
)

logger = logging.getLogger("ayma.practice_date")


def _bucket():
    return storage.bucket(CONFIG.storage_bucket)


async def require_not_underage_uid(uid: str = Depends(require_uid)) -> str:
    """18+ gate for Practice Date (same contract as main's gate): refuses
    minors, lets a not-yet-birthdated onboarding user through. Defined locally
    so this router carries no import cycle back into ``main``."""
    try:
        await asyncio.to_thread(
            age_gate.enforce, get_db(), _bucket, uid, require_birthdate=False
        )
    except age_gate.AgeGateError as exc:
        raise HTTPException(
            status_code=403, detail={"code": exc.code, "message": exc.message}
        ) from exc
    return uid


# --------------------------------------------------------------------------- #
# HTTP API (mounted by main.py via app.include_router)
# --------------------------------------------------------------------------- #
router = APIRouter(prefix="/practice", tags=["practice"])


class StartRequest(BaseModel):
    other_uid: str = Field(..., min_length=1, max_length=128)


class ChatRequest(BaseModel):
    session_id: str = Field(..., min_length=1, max_length=128)
    message: str = Field(..., min_length=1, max_length=4000)


class DebriefRequest(BaseModel):
    session_id: str = Field(..., min_length=1, max_length=128)


@router.post("/start", dependencies=[Depends(require_not_underage_uid)])
async def practice_start(
    req: StartRequest, caller: Caller = Depends(require_caller)
) -> dict[str, object]:
    """Open a practice simulator against ``other_uid``'s viewer-visible profile."""
    db = get_db()
    ctx = build_persona_context(db, caller.uid, req.other_uid.strip())
    if ctx is None:
        raise HTTPException(status_code=404, detail="No profile to practice with.")
    session_id = start_session(db, caller.uid, req.other_uid.strip())
    return {
        "session_id": session_id,
        "simulation": True,
        "persona": {
            "name": ctx.name,
            "age": ctx.age,
            "location": ctx.location,
            "photo_count": ctx.photo_count,
        },
        "banner": (
            f"Practice mode — you're talking to a simulated version of "
            f"{ctx.name}, not the real person."
        ),
    }


@router.post("/chat", dependencies=[Depends(require_not_underage_uid)])
async def practice_chat(
    req: ChatRequest, caller: Caller = Depends(require_caller)
) -> dict[str, object]:
    """One practice turn: the match's in-character reply + a live coach nudge."""
    db = get_db()
    try:
        data = _load_session(db, caller.uid, req.session_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Practice session not found.") from exc

    ctx = build_persona_context(db, caller.uid, str(data.get("target_uid") or ""))
    if ctx is None:
        raise HTTPException(status_code=404, detail="No profile to practice with.")

    turns = list(data.get("turns") or [])
    message = req.message.strip()
    try:
        reply = await persona_reply(
            ctx, turns, message, uid=caller.uid, session_id=req.session_id
        )
    except token_ledger.TokenCapExceeded as exc:
        raise HTTPException(status_code=402, detail="Out of credits.") from exc
    except Exception as exc:  # noqa: BLE001 - model/transport failure → 502
        raise HTTPException(status_code=502, detail=f"Practice reply failed: {exc}") from exc

    full = append_turns(
        db,
        caller.uid,
        req.session_id,
        [{"role": ROLE_USER, "text": message}, {"role": ROLE_MATCH, "text": reply}],
    )
    hint = await coach_hint(ctx, full, uid=caller.uid)
    return {"reply": reply, "coach_hint": hint, "simulation": True}


@router.post("/debrief", dependencies=[Depends(require_not_underage_uid)])
async def practice_debrief(
    req: DebriefRequest, caller: Caller = Depends(require_caller)
) -> dict[str, object]:
    """End the session and return the coaching debrief."""
    db = get_db()
    try:
        data = _load_session(db, caller.uid, req.session_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Practice session not found.") from exc

    ctx = build_persona_context(db, caller.uid, str(data.get("target_uid") or ""))
    turns = list(data.get("turns") or [])
    if ctx is None:
        raise HTTPException(status_code=404, detail="No profile to practice with.")
    try:
        debrief = await generate_debrief(ctx, turns, uid=caller.uid)
    except token_ledger.TokenCapExceeded as exc:
        raise HTTPException(status_code=402, detail="Out of credits.") from exc
    except Exception as exc:  # noqa: BLE001 - model/transport failure → 502
        raise HTTPException(status_code=502, detail=f"Debrief failed: {exc}") from exc
    end_session(db, caller.uid, req.session_id)
    return {"simulation": True, **debrief}


class VoiceStartRequest(BaseModel):
    other_uid: str = Field(..., min_length=1, max_length=128)


@router.post("/voice/start", dependencies=[Depends(require_not_underage_uid)])
async def practice_voice_start(
    req: VoiceStartRequest,
    background: BackgroundTasks,
    caller: Caller = Depends(require_caller),
) -> dict[str, object]:
    """Open a PRACTICE voice session against ``other_uid`` (hackathon B).

    Same privacy boundary as the text path: the persona is built ONLY from
    :func:`build_persona_context` (viewer-visible, never-load-filtered), and
    its prompt — :func:`compose_persona_prompt` — is seeded into a LiveKit room
    flagged ``practice`` so the voice agent worker runs the simulated persona
    (deflecting extraction in-character) with Ayma's own tools, memory flush
    and wiki ingest all OFF. Reuses the existing LiveKit voice pipeline (Gemini
    Live today); the Meta voice cascade (Muse Voice Transcribe → Muse Spark →
    partner TTS) is a documented TODO, not built here. A practice session row
    is created so the client can fetch the end-of-call debrief."""
    db = get_db()
    target_uid = req.other_uid.strip()
    ctx = build_persona_context(db, caller.uid, target_uid)
    if ctx is None:
        raise HTTPException(status_code=404, detail="No profile to practice with.")

    try:
        await asyncio.to_thread(token_ledger.check, caller.uid)
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True, "simulation": True}

    if not CONFIG.livekit_url:
        raise HTTPException(status_code=503, detail="LIVEKIT_URL is not configured.")

    session_id = start_session(db, caller.uid, target_uid)
    room = room_name_for(caller.uid)
    try:
        token = mint_access_token(caller.uid, room)
    except LiveKitConfigError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    # Wake the scale-to-zero agent in parallel with room creation (same as
    # /bootstrap), then seed the persona prompt onto the room metadata.
    background.add_task(agent_wake.wake_agent)
    try:
        await seed_room_context(
            room,
            build_room_seed(
                compose_persona_prompt(ctx),
                [],
                caller.uid,
                session_id,
                practice=True,
                persona_name=ctx.name,
                target_uid=target_uid,
            ),
        )
    except Exception:  # noqa: BLE001 - seeding is best-effort, never blocks voice
        logger.exception("failed to seed practice voice room %s", room)

    return {
        "session_id": session_id,
        "simulation": True,
        "persona": {
            "name": ctx.name,
            "age": ctx.age,
            "location": ctx.location,
            "photo_count": ctx.photo_count,
        },
        "banner": (
            f"Practice mode — you're talking to a simulated version of "
            f"{ctx.name}, not the real person."
        ),
        "livekit": {
            "token": token,
            "url": CONFIG.livekit_url,
            "room": room,
        },
    }
