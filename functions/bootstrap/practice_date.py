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
import time

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
    resolve_voice_agent_cloud,
    room_name_for,
    seed_room_context,
    watch_hosted_dispatch,
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
    start_or_resume_session,
    start_session,
    store_debrief,
)

logger = logging.getLogger("ayma.practice_date")


def _bucket():
    return storage.bucket(CONFIG.storage_bucket)


def _caller_first_name(db, uid: str) -> str:
    """The caller's own first name from their ``profile/main`` ``name``, for the
    voice persona prompt (so the simulated match knows who is calling and never
    asks). Best-effort: returns ``""`` when there's no readable name."""
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
        )
        full = str((snap.to_dict() or {}).get("name") or "").strip()
        return full.split()[0] if full else ""
    except Exception:  # noqa: BLE001 - name is best-effort, never blocks voice
        logger.warning("practice voice: caller name lookup failed", exc_info=True)
        return ""


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
            "photo_url": ctx.photo_url,
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

    # Out of credits → 402 before spending anything. The coach runs with
    # ``enforce_cap=False``, so without this up-front check parallelizing (below)
    # would let a capped turn still meter a coach call — this keeps the
    # token-ledger behaviour identical to the old serial path, where the persona
    # call tripped the cap first and the coach never ran.
    try:
        await asyncio.to_thread(token_ledger.check, caller.uid)
    except token_ledger.TokenCapExceeded as exc:
        raise HTTPException(status_code=402, detail="Out of credits.") from exc

    # The persona's in-character reply and the live coach nudge are two
    # independent Meta Muse Spark calls: the coach critiques the user's
    # just-sent message and does NOT depend on the persona's new reply, so run
    # them concurrently instead of back-to-back. The client's send spinner then
    # waits ≈ max(persona, coach), not their sum. The coach sees the transcript
    # THROUGH the user's latest message (the message being coached) — never the
    # persona's not-yet-produced reply.
    coach_turns = turns + [{"role": ROLE_USER, "text": message}]
    reply_res, hint_res = await asyncio.gather(
        persona_reply(ctx, turns, message, uid=caller.uid, session_id=req.session_id),
        coach_hint(ctx, coach_turns, uid=caller.uid),
        return_exceptions=True,
    )
    if isinstance(reply_res, token_ledger.TokenCapExceeded):
        raise HTTPException(status_code=402, detail="Out of credits.") from reply_res
    if isinstance(reply_res, BaseException):
        raise HTTPException(
            status_code=502, detail=f"Practice reply failed: {reply_res}"
        ) from reply_res
    reply = reply_res
    hint = hint_res if isinstance(hint_res, str) else ""

    append_turns(
        db,
        caller.uid,
        req.session_id,
        [{"role": ROLE_USER, "text": message}, {"role": ROLE_MATCH, "text": reply}],
    )
    return {"reply": reply, "coach_hint": hint, "simulation": True}


#: How long POST /practice/debrief waits for a voice session's transcript
#: to finalize (the worker marks it final after draining its persist
#: queue at call end) before generating from whatever turns are stored.
#: The client fetches the debrief immediately after disconnect, so
#: without this the debrief is routinely generated from a partial
#: transcript. Bounded: a worker that died mid-drain never blocks the
#: request past this.
_DEBRIEF_FINAL_WAIT_SECONDS = 5.0
_DEBRIEF_FINAL_POLL_SECONDS = 0.25
#: A voice session ended longer ago than this cannot still be draining —
#: its transcript is as final as it will ever be, so no wait is owed.
_DEBRIEF_FINAL_RECENT_SECONDS = 10.0


def _needs_final_wait(data: dict) -> bool:
    """Whether POST /practice/debrief should wait for this session's
    transcript to finalize: a voice session whose worker has not marked
    it final yet, and which ended recently enough that the worker may
    still be draining (or has not ended at all). Text sessions persist
    synchronously in the request handler, so they are always final."""
    if data.get("modality") != "voice":
        return False
    if data.get("transcript_final_at"):
        return False
    ended_at = data.get("ended_at")
    if ended_at:
        try:
            if time.time() - float(ended_at) >= _DEBRIEF_FINAL_RECENT_SECONDS:
                return False
        except (TypeError, ValueError):
            return False
    return True


async def _wait_for_transcript_final(db, uid: str, session_id: str) -> dict:
    """Reload the session until ``transcript_final_at`` appears or the
    bounded wait expires; returns the latest session data either way."""
    data = await asyncio.to_thread(_load_session, db, uid, session_id)
    deadline = time.monotonic() + _DEBRIEF_FINAL_WAIT_SECONDS
    while not data.get("transcript_final_at") and time.monotonic() < deadline:
        await asyncio.sleep(_DEBRIEF_FINAL_POLL_SECONDS)
        data = await asyncio.to_thread(_load_session, db, uid, session_id)
    return data


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
    # A voice session's transcript may still be draining when the client
    # asks for the debrief right after disconnect: wait (bounded) for the
    # worker to mark it final, so the debrief is generated from the whole
    # conversation, not the partial transcript that happened to be stored.
    if _needs_final_wait(data):
        data = await _wait_for_transcript_final(db, caller.uid, req.session_id)
        turns = list(data.get("turns") or [])
    # A debrief already generated for this session (the voice-return
    # greeting in /bootstrap generates one when Ayma's session resumes
    # and caches it on the session doc) is reused — but only when it was
    # generated from exactly the turns the session holds now. A cached
    # debrief with no turn count is a legacy doc: reuse it as before.
    stored = data.get("debrief")
    stored_count = data.get("debrief_turn_count")
    if (
        isinstance(stored, dict)
        and stored
        and (stored_count is None or stored_count == len(turns))
    ):
        debrief = stored
    elif not turns:
        # No transcript to debrief: never ask the model to invent
        # feedback from nothing. An honest empty outcome, and nothing
        # cached for a later consumer to reuse.
        end_session(db, caller.uid, req.session_id)
        return {
            "simulation": True,
            "empty": True,
            "what_worked": [],
            "suggested_next_lines": [],
            "avoid": [],
        }
    else:
        try:
            debrief = await generate_debrief(ctx, turns, uid=caller.uid)
        except token_ledger.TokenCapExceeded as exc:
            raise HTTPException(status_code=402, detail="Out of credits.") from exc
        except Exception as exc:  # noqa: BLE001 - model/transport failure → 502
            raise HTTPException(status_code=502, detail=f"Debrief failed: {exc}") from exc
        try:
            store_debrief(
                db, caller.uid, req.session_id, debrief, turn_count=len(turns)
            )
        except Exception:  # noqa: BLE001 - the debrief itself is already in hand
            logger.warning("practice debrief: caching the debrief failed", exc_info=True)
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

    # Resume the caller's still-open voice session for this target when
    # one exists (bug 44RwY05T4hgzkP4HtAU8): the client re-runs this
    # start on its automatic retries, and minting a fresh session per
    # attempt left the debrief bound to the newest empty session while
    # the session holding the voice transcript was orphaned.
    session_id = start_or_resume_session(
        db, caller.uid, target_uid, modality="voice"
    )
    room = room_name_for(caller.uid)
    try:
        token = mint_access_token(caller.uid, room)
    except LiveKitConfigError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    # Route exactly like /bootstrap (§1.1 dual-cloud): resolve the caller's
    # target cloud (default the hosted LiveKit worker), wake the scale-to-zero
    # Cloud Run worker only when the room actually routes there, then seed the
    # persona prompt onto the room metadata. (This path originally skipped the
    # resolution entirely — no explicit dispatch, a default "cloudrun" marker
    # and an unconditional wake — so every practice call landed on GCP.) The
    # persona answers a live phone CALL from the caller, so the prompt is built
    # with the voice framing and the caller's first name (so the match never
    # asks who's calling), and the persona's gender rides along so the worker
    # picks a gender-matched TTS voice.
    user_name = _caller_first_name(db, caller.uid)
    agent_cloud = resolve_voice_agent_cloud(db, caller.uid)
    if agent_cloud == "cloudrun":
        background.add_task(agent_wake.wake_agent)
    try:
        await seed_room_context(
            room,
            build_room_seed(
                compose_persona_prompt(ctx, voice=True, user_name=user_name),
                [],
                caller.uid,
                session_id,
                practice=True,
                persona_name=ctx.name,
                persona_gender=ctx.gender,
                target_uid=target_uid,
                voice_agent_cloud=agent_cloud,
            ),
            agent_name=(
                CONFIG.agent_name_livekit if agent_cloud == "livekit" else None
            ),
        )
    except Exception:  # noqa: BLE001 - seeding is best-effort, never blocks voice
        logger.exception("failed to seed practice voice room %s", room)
    if agent_cloud == "livekit":
        # Failure-only GCP fallback (§1.1), same as /bootstrap.
        background.add_task(watch_hosted_dispatch, room)

    return {
        "session_id": session_id,
        "simulation": True,
        "persona": {
            "name": ctx.name,
            "age": ctx.age,
            "location": ctx.location,
            "photo_count": ctx.photo_count,
            "photo_url": ctx.photo_url,
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
