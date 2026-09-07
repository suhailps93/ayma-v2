"""Ayma Main API — Cloud Run service (see ``docs/ARCHITECTURE.md`` §10.1).

Step 1 scaffolding: a single unauthenticated health-check route. The real
endpoint surface (§10.2) and the shared auth / cron middleware (§10.4, §10.5)
land in later steps per ``PLAN.md``.
"""

from __future__ import annotations

import asyncio
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

import json  # noqa: E402
import logging  # noqa: E402
import secrets  # noqa: E402
from dataclasses import dataclass  # noqa: E402
from datetime import datetime  # noqa: E402
from typing import Literal  # noqa: E402

from fastapi import (  # noqa: E402 - must follow the dotenv load
    BackgroundTasks,
    Body,
    Depends,
    FastAPI,
    Request,
)
from fastapi.responses import StreamingResponse  # noqa: E402
from pydantic import BaseModel, Field  # noqa: E402

from fastapi import HTTPException  # noqa: E402

from auth import (  # noqa: E402
    Caller,
    require_admin_password,
    require_caller,
    require_cron,
    require_uid,
)
from config import CONFIG  # noqa: E402
import gemini  # noqa: E402
import token_ledger  # noqa: E402
from livekit_token import (  # noqa: E402
    LiveKitConfigError,
    build_room_seed,
    mint_access_token,
    room_name_for,
    seed_room_context,
)
import account_ops  # noqa: E402
import account_purge  # noqa: E402
import auto_analysis  # noqa: E402
import deep_dive  # noqa: E402
import face_report  # noqa: E402
import body_report  # noqa: E402
import skill_memory  # noqa: E402
import explore as explore_mod  # noqa: E402
import public_profile as public_profile_mod  # noqa: E402
import matching  # noqa: E402
import matching_cron  # noqa: E402
import matching_skill  # noqa: E402
from matching_schema import (  # noqa: E402
    BLOCKS_COLLECTION,
    MATCH_STATUS_MUTUAL,
    MATCH_STATUS_SCORED,
    MATCHES_COLLECTION,
    block_id,
)
import dm_ingest  # noqa: E402
import dm_ops  # noqa: E402
import icebreakers  # noqa: E402
import notifications_ops  # noqa: E402
import notifications_triggers  # noqa: E402
import schema  # noqa: E402
from pair_key import sorted_pair_key, uids_from_pair_key  # noqa: E402
import media_embed  # noqa: E402
import photo_attrs  # noqa: E402
from media_embed import process_media  # noqa: E402
import backfill_ops  # noqa: E402
import chat_history  # noqa: E402
import feedback_ops  # noqa: E402
from db import get_db  # noqa: E402
from post_turn import persist_raw_turns  # noqa: E402
import prompt as prompt_module  # noqa: E402
from prompt import compose_system_prompt  # noqa: E402
import session_mode  # noqa: E402
from skills import (  # noqa: E402
    make_session_tool_fns,
    session_tool_declarations,
)
import turn_caps  # noqa: E402
from transcript import ROLE_AYMA, ROLE_USER, Turn  # noqa: E402
from wiki_ingest import ingest as wiki_ingest  # noqa: E402
from wiki_lint import lint_all  # noqa: E402
from wiki_query import read_wiki_context  # noqa: E402
import story  # noqa: E402

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
    """Best-effort raw_turns upsert — never fails the request it rides on.

    Also stamps ``users/{uid}.last_active_at`` — the signal the re-engagement
    cron (§7.1) reads. Only genuine user sessions flow through here (chat /
    post-turn / bootstrap); receiving a DM does not count as activity.
    """
    try:
        persist_raw_turns(get_db(), uid, session_id, turns)
    except Exception:  # noqa: BLE001
        logger.exception("failed to persist raw_turns for %s/%s", uid, session_id)
    try:
        get_db().collection("users").document(uid).set(
            {"last_active_at": _server_ts()}, merge=True
        )
    except Exception:  # noqa: BLE001
        logger.exception("failed to stamp last_active_at for %s", uid)


def _bucket():
    from firebase_admin import storage

    return storage.bucket(CONFIG.storage_bucket)


def _ayma_voice_name(uid: str) -> str:
    """The user's ``ayma_voice_name`` preset preference (§13.3), or "" — the
    agent falls back to ``CONFIG.gemini_live_voice`` when it's empty/invalid."""
    try:
        snap = schema.profile_doc(get_db(), uid).get()
        return str((snap.to_dict() or {}).get(schema.PF_AYMA_VOICE, "")).strip()
    except Exception:  # noqa: BLE001
        logger.exception("could not read ayma_voice_name for %s", uid)
        return ""


def _ayma_voice_language(uid: str) -> str:
    """The user's speaking-voice instruction — free text like "Malayalam mixed
    with English" or "a Southern US accent", set on the settings screen or by
    ``set_voice_preference`` from conversation. "" = plain English default. A
    mid-call switch by the caller is handled by the prompt (§13.3)."""
    try:
        import voices

        snap = schema.profile_doc(get_db(), uid).get()
        return str(
            (snap.to_dict() or {}).get(voices.PF_AYMA_VOICE_LANGUAGE, "")
        ).strip()[:200]
    except Exception:  # noqa: BLE001
        logger.exception("could not read ayma_voice_language for %s", uid)
        return ""


def _voice_language_directive(pref: str) -> str:
    """A system-prompt line: speak the way the user asked by default, but
    follow the caller if they switch language mid-call."""
    if not pref:
        return (
            "\n\nSpeak English by default. If the caller talks to you in "
            "another language, switch and keep replying in theirs until they "
            "switch back."
        )
    return (
        f"\n\nSpeak like this by default: {pref}. If the caller clearly moves "
        "to another language, follow them into it and switch back when they do."
    )


def _server_ts():
    from firebase_admin import firestore

    return firestore.SERVER_TIMESTAMP


def _recovery_required(uid: str) -> bool:
    return account_ops.is_recovery_required(get_db(), uid)


def _session_mode(caller: Caller) -> str:
    """Derive the caller's ``session_mode`` (§3.3) from auth state + profile
    completeness. Best-effort: a Firestore read failure falls back to the
    conservative ``marketing``."""
    try:
        return session_mode.derive_for(
            get_db(), caller.uid, caller.is_anonymous
        )
    except Exception:  # noqa: BLE001
        logger.exception("session_mode derivation failed for %s", caller.uid)
        return session_mode.MODE_MARKETING


def _interview_progress(uid: str, mode: str) -> str:
    """The 'already captured' preboarding summary for interview-mode prompts —
    stops Ayma re-asking for a field the on-screen form already holds. Empty for
    every other mode. Best-effort: a read failure just omits it."""
    if mode != session_mode.MODE_INTERVIEW:
        return ""
    try:
        snap = schema.profile_doc(get_db(), uid).get()
        return session_mode.describe_progress(
            snap.to_dict() if snap.exists else None
        )
    except Exception:  # noqa: BLE001
        logger.exception("interview progress read failed for %s", uid)
        return ""


async def _run_ingest(uid: str, session_id: str, turns: list[Turn]) -> None:
    """Wiki ingest (§2.3), run after the response is sent. Best-effort.

    Out of credits → flag the session so a later top-up / the nightly sweep
    re-ingests it (§15)."""
    try:
        written = await wiki_ingest(get_db(), uid, session_id, turns)
        if written:
            logger.info("wiki ingest wrote %d page(s) for %s", written, uid)
    except token_ledger.TokenCapExceeded:
        backfill_ops.mark_pending(get_db(), uid, session_id)
    except Exception:  # noqa: BLE001
        logger.exception("wiki ingest failed for %s", uid)

app = FastAPI(title="Ayma Main API", version=CONFIG.version)

# Per-endpoint fixed-window rate limiting (§10.4, §10.6 step 3). Wraps every
# route; `/cron/*` is still additionally protected by the X-Cron-Secret check.
from ratelimit import RateLimiter  # noqa: E402

app.add_middleware(RateLimiter)


@app.on_event("startup")
async def _warmup() -> None:
    """Pay the Gemini cold-start cost before serving traffic, so the first
    real /chat doesn't eat an ADC/gRPC/transient-5xx hiccup."""
    await gemini.warmup()


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


def _should_auto_dive(uid: str) -> bool:
    """True when ``uid`` has a usable research name and has not yet had the
    one-time automatic self deep-dive (§ auto analysis). Best-effort — any
    read failure just defers the dive to a later bootstrap."""
    try:
        if not deep_dive.profile_full_name(get_db(), uid):
            return False
        snap = get_db().collection("users").document(uid).get()
        if not getattr(snap, "exists", False):
            return True
        return not (snap.to_dict() or {}).get("auto_dive_done")
    except Exception:  # noqa: BLE001
        return False


@app.post("/bootstrap")
async def bootstrap(
    background: BackgroundTasks,
    caller: Caller = Depends(require_caller),
    req: BootstrapRequest | None = Body(default=None),
) -> dict[str, object]:
    """Session bootstrap (§1.7 step 3, §1.1, §1.5).

    Mints the short-lived, room-scoped LiveKit token, and — when the client
    sends its recent-turns window — attaches the composed system prompt + that
    window to the room metadata so the auto-dispatched agent seeds its Gemini
    Live session with the same context ``/chat`` sees (Step 17). ``session_mode``
    is still the Step 6 stub; real derivation is Step 34.
    """
    uid = caller.uid
    if _recovery_required(uid):
        return {"recovery_required": True, "uid": uid}

    # `session_mode` drives which screen the client opens (§11.2 / entryRouteFor)
    # and is independent of credit state — derive it before anything can short-
    # circuit, so an out-of-credits user still lands on their real screen.
    mode = _session_mode(caller)

    # Automatic one-time self deep-dive (§ auto analysis): fires on the first
    # app open once onboarding has given us a real name, writes only to the
    # user's private `ai_only` memory, and never blocks this response.
    if _should_auto_dive(uid):
        background.add_task(auto_analysis.analyse_web, get_db(), uid)

    # Voice is an LLM session — no credits, no room (heuristic-only paths keep
    # working). Still return `session_mode` so the client routes normally and
    # merely shows "reload credits"; just drop the LiveKit creds.
    try:
        await asyncio.to_thread(token_ledger.check, uid)
    except token_ledger.TokenCapExceeded:
        return {
            "session_mode": mode,
            "uid": uid,
            "turn_cap": turn_caps.peek(get_db(), uid, mode),
            "usage_capped": True,
        }

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
    voice_language = _ayma_voice_language(uid)
    system_prompt = compose_system_prompt(
        recent_turns=turns,
        wiki_context=read_wiki_context(get_db(), uid),
        session_mode=mode,
        profile_progress=_interview_progress(uid, mode),
    ) + _voice_language_directive(voice_language)
    voice_name = _ayma_voice_name(uid)
    try:
        await seed_room_context(
            room,
            build_room_seed(
                system_prompt, turns, uid, session_id, voice_name,
                voice_language=voice_language,
            ),
        )
    except Exception:  # noqa: BLE001 - seeding is best-effort, never blocks voice
        logger.exception("failed to seed room context for %s", room)

    if session_id and turns:
        _persist_session(uid, session_id, turns)

    return {
        "session_mode": mode,
        "uid": uid,
        "turn_cap": turn_caps.peek(get_db(), uid, mode),
        "livekit": {
            "token": token,
            "url": CONFIG.livekit_url,
            "room": room,
        },
    }


# --- POST /welcome/token (pre-sign-in voice greeting) ------------------

_WELCOME_GREETING = (
    "Open the call. In two or three sentences: you're Ayma, their matchmaker "
    "— you get to know them by talking, then find and introduce people who "
    "actually fit. Then tell them to sign in on this screen (Google, email or "
    "phone) to get started. Warm, brief, inviting — no questions yet."
)
# Best-effort per-IP throttle (single process; a burst across Cloud Run
# instances can still slip through — acceptable for an ephemeral greeting room).
_welcome_hits: dict[str, list[float]] = {}
_WELCOME_MAX_PER_MIN = 4


def _welcome_rate_ok(ip: str) -> bool:
    import time as _t

    now = _t.time()
    hits = [h for h in _welcome_hits.get(ip, []) if now - h < 60]
    if len(hits) >= _WELCOME_MAX_PER_MIN:
        _welcome_hits[ip] = hits
        return False
    hits.append(now)
    _welcome_hits[ip] = hits
    if len(_welcome_hits) > 4000:  # crude cap so the dict can't grow unbounded
        _welcome_hits.clear()
    return True


@app.post("/welcome/token")
async def welcome_token(request: Request) -> dict[str, object]:
    """A LiveKit token for the pre-sign-in "welcome" room. Unauthenticated by
    design — there is no account yet. The auto-dispatched agent reads a
    greeting-framed persona from the room metadata and opens the call; the
    session carries no ``uid`` (unmetered) and is meant to last under a minute.
    """
    ip = (request.client.host if request.client else "") or "unknown"
    if not _welcome_rate_ok(ip):
        raise HTTPException(status_code=429, detail="Slow down a moment.")
    if not CONFIG.livekit_url:
        raise HTTPException(status_code=503, detail="Voice is unavailable.")

    room = f"welcome-{secrets.token_urlsafe(9)}"
    try:
        token = mint_access_token(f"guest-{room}", room)
    except LiveKitConfigError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    try:
        await seed_room_context(
            room,
            build_room_seed(
                prompt_module.compose_welcome_prompt(),
                [],
                "",
                "",
                greeting_instructions=_WELCOME_GREETING,
            ),
        )
    except Exception:  # noqa: BLE001 - best-effort; the agent still has a base persona
        logger.exception("failed to seed welcome room %s", room)

    return {"livekit": {"token": token, "url": CONFIG.livekit_url, "room": room}}


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)
    session_id: str = _SESSION_ID
    recent_turns: list[TurnModel] = Field(
        default_factory=list, max_length=_MAX_RECENT_TURNS
    )
    viewing_profile_uid: str = Field(default="", max_length=128)
    # A photo the user attached, already uploaded to their own uploads/ tree
    # (§2.2). Empty for a plain text turn.
    image_path: str = Field(default="", max_length=256)


def _viewing_profile_context(db, uid: str, other: str) -> str:
    """That pair's ``ai_explanation`` for Ayma's context (§5.6)."""
    if not other or other == uid:
        return ""
    try:
        snap = (
            db.collection(MATCHES_COLLECTION)
            .document(sorted_pair_key(uid, other))
            .get()
        )
        return (snap.to_dict() or {}).get("ai_explanation", "") if snap.exists else ""
    except Exception:  # noqa: BLE001
        return ""


_USAGE_CAPPED_REPLY = (
    "I've used up the shared assistant budget on your account for now, so I "
    "need to pause here. It frees up again over time — check your usage in "
    "Settings."
)


@dataclass
class _ChatCtx:
    uid: str
    image: tuple[bytes, str] | None
    image_path: str
    window: list
    system_prompt: str


async def _prepare_chat(
    req: ChatRequest, caller: Caller
) -> tuple[dict | None, _ChatCtx | None]:
    """Shared setup for ``/chat`` and ``/chat/stream``: turn cap → image →
    prompt compose. Returns ``(early_response, None)`` when the turn is capped,
    else ``(None, ctx)``. Raises ``HTTPException`` for a bad image path."""
    uid = caller.uid
    mode = _session_mode(caller)
    cap = turn_caps.evaluate(get_db(), uid, mode)
    if not cap.allowed:
        return (
            {
                "reply": cap.canned_reply or "",
                "capped": True,
                "fallback_form": cap.fallback_form,
                "turn_cap": {
                    "mode": cap.mode, "count": cap.count, "cap": cap.cap
                },
            },
            None,
        )

    image_path = req.image_path.strip()
    image: tuple[bytes, str] | None = None
    if image_path:
        if not image_path.startswith(f"uploads/{uid}/"):
            raise HTTPException(
                status_code=403,
                detail="image_path must be under the caller's uploads/ tree.",
            )
        try:
            img_bytes, mime = await asyncio.to_thread(
                media_embed.download_bytes, image_path
            )
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(
                status_code=502, detail=f"Could not read the image: {exc}"
            ) from exc
        # No app-side content check on a photo the user shares privately with
        # Ayma — Gemini's own API safety is the backstop.
        image = (img_bytes, mime)

    window = _to_turns(req.recent_turns)
    system_prompt = compose_system_prompt(
        recent_turns=window,
        wiki_context=read_wiki_context(get_db(), uid),
        session_mode=mode,
        profile_progress=_interview_progress(uid, mode),
        viewing_profile_context=_viewing_profile_context(
            get_db(), uid, req.viewing_profile_uid.strip()
        ),
    )
    return (None, _ChatCtx(uid, image, image_path, window, system_prompt))


def _finalize_chat(
    background: BackgroundTasks,
    ctx: _ChatCtx,
    req: ChatRequest,
    reply_text: str,
) -> None:
    """Durable transcript + raw_turns + wiki-ingest kickoff after a reply
    (shared by both endpoints). Best-effort — never raises."""
    try:
        chat_history.append(
            get_db(), ctx.uid, "user", req.message,
            image_path=ctx.image_path or None,
        )
        chat_history.append(get_db(), ctx.uid, "ayma", reply_text)
    except Exception:  # noqa: BLE001
        logger.exception("chat_history append failed for %s", ctx.uid)

    if req.session_id:
        user_text = req.message
        if ctx.image is not None:
            user_text = f"{req.message}\n[shared a photo]".strip()
        full_window = ctx.window + [
            Turn(ROLE_USER, user_text),
            Turn(ROLE_AYMA, reply_text),
        ]
        _persist_session(ctx.uid, req.session_id, full_window)
        background.add_task(
            _run_chat_followups, ctx.uid, req.session_id, full_window,
            ctx.image_path if ctx.image is not None else "",
        )


@app.post("/chat")
async def chat(
    req: ChatRequest,
    background: BackgroundTasks,
    caller: Caller = Depends(require_caller),
) -> dict[str, object]:
    """Text chat turn (§1.7 step 2, §1.5, §3.3). Non-streaming; the client
    prefers ``/chat/stream`` for live status, and falls back here."""
    early, ctx = await _prepare_chat(req, caller)
    if early is not None:
        return early
    assert ctx is not None
    try:
        reply = await gemini.generate_reply(
            req.message,
            system_prompt=ctx.system_prompt,
            tool_declarations=session_tool_declarations(),
            tool_fns=make_session_tool_fns(get_db(), ctx.uid),
            image=ctx.image,
            uid=ctx.uid,
            feature=token_ledger.FEATURE_CHAT,
        )
    except token_ledger.TokenCapExceeded:
        return {
            "reply": _USAGE_CAPPED_REPLY,
            "capped": False,
            "fallback_form": False,
            "usage_capped": True,
        }
    except Exception as exc:  # noqa: BLE001 - model/transport failure → 502
        raise HTTPException(
            status_code=502, detail=f"Gemini call failed: {exc}"
        ) from exc

    _finalize_chat(background, ctx, req, reply.text)
    return {"reply": reply.text, "tools_used": reply.tools_used}


def _sse(obj: dict) -> str:
    return f"data: {json.dumps(obj)}\n\n"


@app.post("/chat/stream")
async def chat_stream(
    req: ChatRequest,
    background: BackgroundTasks,
    caller: Caller = Depends(require_caller),
):
    """Text chat turn as Server-Sent Events: ``{"type":"status","label":"…"}``
    while a tool runs (so the client can show *"Searching the web…"* live),
    then one ``{"type":"reply","text":…,"tools_used":[…]}``. Same persistence
    as ``/chat`` once the reply lands."""
    early, ctx = await _prepare_chat(req, caller)

    async def _gen():
        if early is not None:
            yield _sse({"type": "reply", **early})
            return
        assert ctx is not None
        reply_text = ""
        tools_used: list[str] = []
        try:
            async for ev in gemini.generate_reply_events(
                req.message,
                system_prompt=ctx.system_prompt,
                tool_declarations=session_tool_declarations(),
                tool_fns=make_session_tool_fns(get_db(), ctx.uid),
                image=ctx.image,
                uid=ctx.uid,
                feature=token_ledger.FEATURE_CHAT,
            ):
                if ev.get("type") == "reply":
                    reply_text = ev["text"]
                    tools_used = ev["tools_used"]
                yield _sse(ev)
        except token_ledger.TokenCapExceeded:
            yield _sse({
                "type": "reply", "text": _USAGE_CAPPED_REPLY,
                "tools_used": [], "usage_capped": True,
            })
            return
        except Exception as exc:  # noqa: BLE001
            logger.exception("chat stream failed for %s", ctx.uid)
            yield _sse({"type": "error", "detail": str(exc)})
            return
        if reply_text:
            _finalize_chat(background, ctx, req, reply_text)

    return StreamingResponse(
        _gen(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        background=background,
    )


async def _run_chat_followups(
    uid: str, session_id: str, turns: list[Turn], image_path: str
) -> None:
    """After the reply is sent: caption any attached photo so wiki ingest can
    remember what was in it, then run the normal ingest (§2.2, §2.3)."""
    enriched = turns
    if image_path:
        try:
            import photo_pipeline

            img_bytes, mime = await asyncio.to_thread(
                media_embed.download_bytes, image_path
            )
            caption = (await photo_pipeline._caption(img_bytes, mime)).strip()
            if caption:
                enriched = turns + [
                    Turn(ROLE_USER, f"(the photo I shared shows: {caption})")
                ]
        except Exception:  # noqa: BLE001
            logger.exception("chat photo caption failed for %s", uid)
    await _run_ingest(uid, session_id, enriched)


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


@app.get("/chat/history")
async def chat_history_page(
    before: str = "",
    limit: int = 40,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """The durable Ayma-tab transcript (§2.2), newest page first-loaded.

    Returns up to ``limit`` messages older than ``before`` (an ISO-8601
    timestamp from a prior ``next_before``), oldest-first, plus the cursor for
    the next older page.
    """
    cursor: datetime | None = None
    if before.strip():
        try:
            cursor = datetime.fromisoformat(before.strip())
        except ValueError:
            raise HTTPException(  # noqa: B904
                status_code=422, detail="`before` must be ISO-8601."
            )
    return await asyncio.to_thread(
        chat_history.recent, get_db(), uid, before=cursor, limit=limit
    )


class MediaRequest(BaseModel):
    storage_path: str = Field(min_length=1, max_length=500)
    context: Literal["profile", "chat", "dm"] = "profile"


@app.post("/media")
async def register_media(
    req: MediaRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Embed an uploaded photo and record it on ``user_media`` (§2.5, §2.8
    step 7). The client uploads the file to ``uploads/{uid}/…`` first, then
    calls this. The unified ``/media/upload`` entry + full §8.5 pipeline is
    Phase 10.
    """
    prefix = f"uploads/{uid}/"
    if not req.storage_path.startswith(prefix):
        raise HTTPException(
            status_code=403,
            detail="storage_path must be under the caller's uploads/ tree.",
        )
    import photo_pipeline

    try:
        result = await photo_pipeline.process(
            get_db(),
            uid,
            req.storage_path,
            req.context,
            wiki_uids=[uid] if req.context in ("profile", "chat") else None,
        )
    except Exception as exc:  # noqa: BLE001 - surface embed/storage failure
        raise HTTPException(
            status_code=502, detail=f"Media pipeline failed: {exc}"
        ) from exc

    # Auto-analysis (§ auto analysis): the user's own photo -> face/body read
    # into their private `ai_only` memory, in the background.
    background.add_task(
        auto_analysis.analyse_photo, get_db(), uid, req.storage_path
    )

    return {
        "ok": True,
        "media_id": result["media_id"],
        "moderation_status": result["moderation_status"],
        "published": result["published"],
        "reason": result["reason"],
        "photo_attrs": result["attributes"],
    }


@app.post("/account/delete")
async def account_delete(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Soft-delete: quarantine the account into ``deleted_accounts/{uid}`` and
    remove the live copies (§3.6). The Auth account is left intact so the user
    can sign back in and recover within the window."""
    try:
        result = await asyncio.to_thread(
            account_ops.soft_delete, get_db(), _bucket(), uid
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Account delete failed: {exc}"
        ) from exc
    return {"ok": True, **result}


@app.post("/account/recover")
async def account_recover(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Restore a soft-deleted account from its quarantine (§3.6)."""
    if not _recovery_required(uid):
        raise HTTPException(
            status_code=409, detail="Nothing to recover for this account."
        )
    try:
        result = await asyncio.to_thread(
            account_ops.recover, get_db(), _bucket(), uid
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Account recovery failed: {exc}"
        ) from exc
    return {"ok": True, **result}


@app.get("/explore")
async def explore(
    q: str = "",
    location: str = "",
    hair_color: str = "",
    glasses: str = "",
    age_min: int | None = None,
    age_max: int | None = None,
    limit: int = 30,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Live Explore feed (§6.1). ``q`` is parsed once into the filter schema;
    dropdown params override it."""
    try:
        nl = await explore_mod.parse_nl_query(q, uid=uid) if q.strip() else {}
    except Exception:  # noqa: BLE001 - a bad NL parse falls back to no filter
        logger.warning("explore: NL parse failed for %r", q, exc_info=True)
        nl = {}
    dropdown = {
        "location": location,
        "hair_color": hair_color,
        "glasses": glasses,
        "age_min": age_min,
        "age_max": age_max,
    }
    filters = explore_mod.merge_filters(dropdown, nl)
    try:
        cards = await asyncio.to_thread(
            explore_mod.explore, get_db(), uid, filters, min(limit, 60)
        )
    except Exception:  # noqa: BLE001 - Explore must render even if the feed errors
        logger.exception("explore: feed build failed for %s", uid)
        cards = []
    return {"cards": cards, "filters_applied": filters}


@app.get("/explore/profile/{other_uid}")
async def explore_profile(
    other_uid: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Another user's public profile — the Explore card tap-through: public
    wiki narrative, visible photos, plus the caller-relative score / like
    state and the DM thread id."""
    view = await asyncio.to_thread(
        public_profile_mod.build, get_db(), uid, other_uid.strip()
    )
    if view is None:
        raise HTTPException(status_code=404, detail="No such profile.")
    return view


class DeepDiveRequest(BaseModel):
    # Empty / own uid -> research yourself; another uid -> that person. `name`
    # overrides the name we'd otherwise read from their profile.
    target_uid: str = Field(default="", max_length=128)
    name: str = Field(default="", max_length=120)
    context: str = Field(default="", max_length=600)


def _profile_full_name(uid: str) -> str:
    """The subject's research name — ``"{first_name} {last_name}"`` when the
    profile has both, else the plain ``name`` field."""
    return deep_dive.profile_full_name(get_db(), uid)


@app.post("/deep-dive")
async def deep_dive_endpoint(
    req: DeepDiveRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Consented web deep-dive on a named person (§ deep dive). Runs the
    two-step research, drops Ayma's summary into the chat transcript, and
    returns the structured digest. `target_uid` empty (or the caller) = a
    lookup on yourself."""
    target = (req.target_uid or "").strip()
    is_self = not target or target == uid
    name = req.name.strip() or _profile_full_name(uid if is_self else target)
    if not name:
        raise HTTPException(
            status_code=400,
            detail="No name to search — set it on the profile first.",
        )
    context = req.context.strip() or (
        "" if is_self else "Someone the user is considering a date with."
    )
    if is_self:
        extra = deep_dive.profile_dive_context(get_db(), uid)
        if extra:
            context = f"{context} {extra}".strip()
    try:
        digest = await deep_dive.run(
            name, uid=uid, context=context, is_self=is_self
        )
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Deep-dive failed: {exc}"
        ) from exc

    skill_memory.save_web_findings(get_db(), uid, digest)
    if is_self:
        # The explicit-ask path (§ auto analysis §4): move the finding into the
        # user's visible `private` wiki.
        skill_memory.promote(get_db(), uid, "web_findings")
    summary = deep_dive.render(digest)
    try:
        chat_history.append(get_db(), uid, "ayma", summary)
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive chat_history append failed for %s", uid)
    return {"digest": digest, "summary": summary, "is_self": is_self}


# --- POST /face-report + /body-report ------------------------------------


class FaceReportRequest(BaseModel):
    # A chat attachment (must be under uploads/{caller}/) takes precedence;
    # otherwise the primary profile photo of `target_uid` (empty -> self).
    attachment_path: str = Field(default="", max_length=256)
    target_uid: str = Field(default="", max_length=128)


# `/body-report` shares the request shape.
BodyReportRequest = FaceReportRequest


def _primary_profile_photo_path(uid: str) -> str:
    """The ``storage_path`` of ``uid``'s primary (lowest-order) profile
    photo, or ``""`` if they have none."""
    try:
        prof = schema.profile_doc(get_db(), uid).get().to_dict() or {}
    except Exception:  # noqa: BLE001
        return ""
    entries = [
        p for p in (prof.get(schema.PF_PHOTOS) or []) if isinstance(p, dict)
    ]
    entries.sort(key=lambda p: p.get("order", 0))
    for e in entries:
        sp = str(e.get("storage_path") or "").strip()  # legacy inline shape
        if sp:
            return sp
        mid = str(e.get("media_id") or "").strip()
        if not mid:
            continue
        try:
            media = (
                get_db()
                .collection("users")
                .document(uid)
                .collection("user_media")
                .document(mid)
                .get()
                .to_dict()
            ) or {}
        except Exception:  # noqa: BLE001
            media = {}
        sp = str(media.get("storage_path") or "").strip()
        if sp:
            return sp
    return ""


def _resolve_report_image(
    caller_uid: str, attachment_path: str, target_uid: str
) -> tuple[bytes, str, str]:
    """``(bytes, mime, storage_path)`` for a face/body report request. 403 for
    an attachment outside the caller's own upload space; 400 when no photo can
    be found. The storage path is kept so the stored report can embed the
    analysed image."""
    attachment_path = (attachment_path or "").strip()
    if attachment_path:
        if not attachment_path.startswith(f"uploads/{caller_uid}/"):
            raise HTTPException(
                status_code=403, detail="Not your attachment."
            )
        storage_path = attachment_path
    else:
        target = (target_uid or "").strip() or caller_uid
        storage_path = _primary_profile_photo_path(target)
        if not storage_path:
            raise HTTPException(
                status_code=400,
                detail="No photo to analyse — add a profile photo first.",
            )
    try:
        image_bytes, mime = media_embed.download_bytes(storage_path)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=400, detail=f"Couldn't read that photo: {exc}"
        ) from exc
    return image_bytes, mime, storage_path


async def _run_report_endpoint(
    engine, req: "FaceReportRequest", uid: str, pointer: str
) -> dict[str, object]:
    """Shared body for ``/face-report`` and ``/body-report``: resolve the
    photo, run ``engine.run``, store the report, drop an Ayma pointer into the
    transcript, and return ``{report, report_id}``."""
    image_bytes, mime, image_path = _resolve_report_image(
        uid, req.attachment_path, req.target_uid
    )
    try:
        report = await engine.run(image_bytes, mime, uid=uid)
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Report failed: {exc}"
        ) from exc

    page_type = "face_analysis" if pointer == "face" else "body_analysis"
    if pointer == "face":
        skill_memory.save_face_analysis(get_db(), uid, report)
    else:
        skill_memory.save_body_analysis(get_db(), uid, report)

    # The explicit-ask path (§ auto analysis §4): a self report the user asked
    # for is promoted into their visible `private` wiki. A report on someone
    # else's photo is never promoted.
    target = (req.target_uid or "").strip()
    if (not target or target == uid) and report.get("usable", True):
        skill_memory.promote(get_db(), uid, page_type)

    report_id = ""
    try:
        ref = (
            get_db()
            .collection("users")
            .document(uid)
            .collection(f"{pointer}_reports")
            .add(
                {
                    "report": report,
                    "image_path": image_path,
                    "created_at": _server_ts(),
                }
            )
        )
        report_id = getattr(ref[1], "id", "") if isinstance(ref, tuple) else ""
    except Exception:  # noqa: BLE001
        logger.exception("%s-report store failed for %s", pointer, uid)

    if report.get("usable", True):
        kind = "facial beauty" if pointer == "face" else "physique"
        line = (
            f"Here's your {kind} report — {report.get('verdict', '')}, "
            f"{report.get('overall_score', 0)}/10."
        )
        try:
            chat_history.append(get_db(), uid, "ayma", line)
        except Exception:  # noqa: BLE001
            logger.exception(
                "%s-report chat_history append failed for %s", pointer, uid
            )
    return {"report": report, "report_id": report_id}


@app.post("/face-report")
async def face_report_endpoint(
    req: FaceReportRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """An honest, data-driven facial-beauty report on a photo (§ face report).
    Runs on a chat attachment or the subject's primary profile photo; stores
    the report and drops an Ayma pointer into the transcript."""
    return await _run_report_endpoint(face_report, req, uid, "face")


@app.post("/body-report")
async def body_report_endpoint(
    req: BodyReportRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """An honest, data-driven physique report on a photo (§ body report).
    Same shape as ``/face-report``."""
    return await _run_report_endpoint(body_report, req, uid, "body")


@app.get("/skills/report/{kind}/{report_id}")
async def skills_report(
    kind: str, report_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Re-open a stored face / body report by id — from a chat marker
    (``[face_report:<id>]`` / ``[body_report:<id>]``) or a history list.
    ``kind`` is ``face`` or ``body``; 404 when the caller has no such report."""
    if kind not in ("face", "body"):
        raise HTTPException(
            status_code=400, detail="kind must be 'face' or 'body'."
        )

    def _read() -> dict[str, object] | None:
        snap = (
            get_db()
            .collection("users")
            .document(uid)
            .collection(f"{kind}_reports")
            .document(report_id.strip())
            .get()
        )
        if not getattr(snap, "exists", False):
            return None
        data = snap.to_dict() or {}
        created = data.get("created_at")
        return {
            "report": data.get("report") or {},
            "image_path": str(data.get("image_path") or ""),
            "created_at": (
                created.isoformat()
                if hasattr(created, "isoformat")
                else None
            ),
        }

    out = await asyncio.to_thread(_read)
    if out is None:
        raise HTTPException(status_code=404, detail="No such report.")
    return out


@app.get("/skills/reports/{kind}")
async def skills_reports(
    kind: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """List the caller's stored face / body reports, newest first — backs the
    per-skill history on the Skills screen. Unusable reads are filtered out."""
    if kind not in ("face", "body"):
        raise HTTPException(
            status_code=400, detail="kind must be 'face' or 'body'."
        )

    def _list() -> list[dict[str, object]]:
        from firebase_admin import firestore

        col = (
            get_db()
            .collection("users")
            .document(uid)
            .collection(f"{kind}_reports")
        )
        try:
            snaps = list(
                col.order_by(
                    "created_at", direction=firestore.Query.DESCENDING
                )
                .limit(30)
                .stream()
            )
        except Exception:  # noqa: BLE001 - missing index / empty collection
            snaps = sorted(
                col.stream(),
                key=lambda s: str((s.to_dict() or {}).get("created_at") or ""),
                reverse=True,
            )
        out: list[dict[str, object]] = []
        for s in snaps:
            data = s.to_dict() or {}
            report = data.get("report") or {}
            if not report.get("usable", True):
                continue
            created = data.get("created_at")
            out.append(
                {
                    "id": s.id,
                    "image_path": str(data.get("image_path") or ""),
                    "overall_score": report.get("overall_score", 0),
                    "verdict": str(report.get("verdict") or ""),
                    "created_at": (
                        created.isoformat()
                        if hasattr(created, "isoformat")
                        else None
                    ),
                }
            )
            if len(out) >= 20:
                break
        return out

    return {"reports": await asyncio.to_thread(_list)}


class _OtherUid(BaseModel):
    other_uid: str = Field(min_length=1, max_length=128)


@app.post("/explore/like")
async def explore_like(
    req: _OtherUid,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Record interest; a reciprocal like flips ``matches/{id}.status`` to
    ``mutual_interest`` (creating the doc if Pass 2 hasn't run, §6.5)."""
    other = req.other_uid.strip()
    if other == uid:
        raise HTTPException(status_code=400, detail="Cannot like yourself.")
    db = get_db()
    db.collection("users").document(uid).collection("likes").document(
        other
    ).set({"liked_at": _server_ts()})

    reciprocal = (
        db.collection("users")
        .document(other)
        .collection("likes")
        .document(uid)
        .get()
        .exists
    )
    if not reciprocal:
        return {"ok": True, "mutual": False}

    lo, hi = sorted((uid, other))
    db.collection(MATCHES_COLLECTION).document(sorted_pair_key(uid, other)).set(
        {
            "uids": [lo, hi],
            "status": MATCH_STATUS_MUTUAL,
            "updated_at": _server_ts(),
        },
        merge=True,
    )
    background.add_task(_notify_mutual_match, uid, other)
    return {"ok": True, "mutual": True}


@app.post("/explore/pass")
async def explore_pass(
    req: _OtherUid, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Seen/passed marker — not a block (§6.5); the card stops resurfacing."""
    get_db().collection("users").document(uid).collection(
        "explore_passed"
    ).document(req.other_uid.strip()).set({"passed_at": _server_ts()})
    return {"ok": True}


class DmMessageRequest(BaseModel):
    type: Literal["text", "photo", "voice", "shared_profile"]
    body: str = Field(min_length=1, max_length=4000)


@app.post("/dm/{thread_id}/messages")
async def dm_send(
    thread_id: str,
    req: DmMessageRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Send a DM message (§6.6). ``thread_id`` is the sorted-pair id; the caller
    must be a participant. Ingestion into the wiki (§6.8) is Step 51."""
    from pair_key import uids_from_pair_key

    try:
        a, b = uids_from_pair_key(thread_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if uid not in (a, b):
        raise HTTPException(status_code=403, detail="Not your thread.")
    other = b if uid == a else a

    if req.type in ("photo", "voice") and not req.body.startswith(
        f"uploads/{uid}/"
    ):
        raise HTTPException(
            status_code=400,
            detail="photo/voice body must be a path under your uploads/.",
        )
    try:
        msg_id = await asyncio.to_thread(
            dm_ops.post_message, get_db(), uid, other, req.type, req.body
        )
    except PermissionError:
        raise HTTPException(status_code=403, detail="Blocked.") from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    # Notify first — it's time-sensitive and cheap; wiki ingest (several Gemini
    # calls) runs after so it never delays the push.
    background.add_task(
        _notify_new_dm, thread_id, uid, other, req.type, req.body
    )
    background.add_task(
        _run_dm_ingest, thread_id, msg_id, uid, other, req.type, req.body
    )
    return {"ok": True, "message_id": msg_id, "thread_id": thread_id}


async def _notify_new_dm(
    thread_id: str, sender: str, recipient: str, mtype: str, body: str
) -> None:
    await notifications_triggers.notify_new_dm(
        get_db(), thread_id, sender, recipient, mtype, body
    )


async def _notify_mutual_match(uid_a: str, uid_b: str) -> None:
    await notifications_triggers.notify_mutual_match(get_db(), uid_a, uid_b)


async def _run_dm_ingest(
    thread_id: str, msg_id: str, sender: str, other: str, mtype: str, body: str
) -> None:
    try:
        await dm_ingest.ingest_dm_message(
            get_db(), thread_id, msg_id, sender, other, mtype, body
        )
    except Exception:  # noqa: BLE001
        logger.exception("DM ingest task failed for %s", thread_id)


@app.get("/dm/{thread_id}/icebreakers")
async def dm_icebreakers(
    thread_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Suggested opener chips for this thread (§6.9). Empty until a
    compatibility check has produced a ``matches`` doc for the pair."""
    try:
        a, b = uids_from_pair_key(thread_id)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if uid not in (a, b):
        raise HTTPException(status_code=403, detail="Not your thread.")
    other = b if uid == a else a
    chips = await icebreakers.suggest(get_db(), uid, other)
    return {"icebreakers": chips}


class ProfileShareRequest(BaseModel):
    shared_uid: str = Field(min_length=1, max_length=128)
    thread_with: str = Field(min_length=1, max_length=128)


@app.post("/profile/share")
async def profile_share(
    req: ProfileShareRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Send a ``shared_profile`` message into the DM thread with
    ``thread_with`` (§6.7)."""
    try:
        msg_id = await asyncio.to_thread(
            dm_ops.post_message,
            get_db(),
            uid,
            req.thread_with.strip(),
            "shared_profile",
            req.shared_uid.strip(),
        )
    except PermissionError:
        raise HTTPException(status_code=403, detail="Blocked.") from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, "message_id": msg_id}


class BlockRequest(BaseModel):
    blocked_uid: str = Field(min_length=1, max_length=128)


@app.post("/block")
async def block_user(
    req: BlockRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Block a user — excluded from all future candidate sourcing (§5.1, §5.10
    step 11). Used from both Explore and DM in Phase 8."""
    from firebase_admin import firestore

    blocked = req.blocked_uid.strip()
    if blocked == uid:
        raise HTTPException(status_code=400, detail="Cannot block yourself.")
    db = get_db()
    db.collection(BLOCKS_COLLECTION).document(block_id(uid, blocked)).set(
        {
            "blocker": uid,
            "blocked": blocked,
            "created_at": _server_ts(),
        }
    )
    # Hide the pair's DM thread from the blocker (§6.11 step 11). Message
    # sends both ways are already refused by dm_ops once a block exists.
    thread_ref = db.collection("dm_threads").document(
        sorted_pair_key(uid, blocked)
    )
    if thread_ref.get().exists:
        thread_ref.set(
            {"hidden_for": firestore.ArrayUnion([uid])}, merge=True
        )
    return {"ok": True}


@app.get("/instagram/auth-url")
async def instagram_auth_url(uid: str = Depends(require_uid)) -> dict[str, str]:
    """The URL the client opens to authorise Instagram access (§8.1)."""
    import instagram

    try:
        return {"url": instagram.auth_url(state=uid)}
    except instagram.InstagramError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


class InstagramConnectRequest(BaseModel):
    code: str = Field(min_length=1, max_length=4096)


@app.post("/instagram/connect")
async def instagram_connect(
    req: InstagramConnectRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Exchange the OAuth ``code``, store the token, import recent photos +
    captions (§8.2, §8.7 step 2)."""
    import instagram

    try:
        return await asyncio.to_thread(
            instagram.connect, get_db(), uid, req.code
        )
    except instagram.InstagramError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@app.post("/instagram/disconnect")
async def instagram_disconnect(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Forget the Instagram token; imported photos stay (§8.1)."""
    import instagram

    await asyncio.to_thread(instagram.disconnect, get_db(), uid)
    return {"ok": True}


@app.get("/admin/users", dependencies=[Depends(require_admin_password)])
async def admin_users(q: str = "") -> dict[str, object]:
    """Search users by uid or name substring (§14.3)."""
    import admin

    return {"users": await asyncio.to_thread(admin.search_users, get_db(), q)}


@app.get(
    "/admin/users/{uid}", dependencies=[Depends(require_admin_password)]
)
async def admin_user_detail(uid: str) -> dict[str, object]:
    """Full per-user detail over the data model (§14.3): account, profile,
    wiki pages (incl. ``ai_only``), matches, dm_threads, trust_flags, and any
    ``deleted_accounts`` record."""
    import admin

    return await asyncio.to_thread(admin.user_detail, get_db(), uid)


class WikiPromoteRequest(BaseModel):
    page_type: str = Field(min_length=1, max_length=40)


_PROMOTABLE_PAGE_TYPES = {"web_findings", "face_analysis", "body_analysis"}


@app.post("/wiki/promote")
async def wiki_promote(
    req: WikiPromoteRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Add what Ayma found to the user's story — flip a skill-memory page
    (``web_findings`` / ``face_analysis`` / ``body_analysis``) from Ayma's
    private ``ai_only`` memory to the user's private wiki. ``{"promoted": bool}``
    — ``false`` when there is no such page yet."""
    if req.page_type not in _PROMOTABLE_PAGE_TYPES:
        raise HTTPException(
            status_code=400, detail="Not a promotable page type."
        )
    promoted = await asyncio.to_thread(
        skill_memory.promote, get_db(), uid, req.page_type
    )
    return {"promoted": promoted}


@app.post("/wiki/reset")
async def wiki_reset(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Wipe what Ayma has learned — clears ``wiki_pages`` and ``raw_turns`` for
    the caller (§14.2). ``users/{uid}``, ``profile`` and auth are untouched;
    this is distinct from account deletion (§3.6)."""

    def _wipe() -> dict:
        db = get_db()
        user = schema.user_doc(db, uid)
        deleted = {}
        for coll in (schema.WIKI_PAGES, schema.RAW_TURNS, schema.PENDING_QUESTIONS):
            n = 0
            for snap in user.collection(coll).stream():
                snap.reference.delete()
                n += 1
            deleted[coll] = n
        return deleted

    deleted = await asyncio.to_thread(_wipe)
    return {"ok": True, "deleted": deleted}


# --- Your Story editor (§ Your Story) -------------------------------------


class StorySaveSectionRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    body: str = Field(default="", max_length=20000)
    visibility: Literal["private", "public"] | None = None


class StoryVisibilityRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    visibility: Literal["private", "public"]


class StoryChatMessage(BaseModel):
    role: Literal["user", "ayma"]
    text: str = Field(default="", max_length=4000)


class StoryEditRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    selection: str = Field(default="", max_length=8000)
    messages: list[StoryChatMessage] = Field(default_factory=list, max_length=40)


class StoryRemoveSectionRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)


class StorySectionRevertRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    version_id: str = Field(min_length=1, max_length=128)


@app.get("/story")
async def story_get(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The whole story document once — every visible section (title, body,
    visibility, flags). The client renders the Public preview by filtering
    ``visibility == 'public'`` and stripping private spans locally. Each
    section's version history lives at ``/story/section/{id}/versions``."""
    return await asyncio.to_thread(story.get_story, get_db(), uid)


@app.put("/story/section")
async def story_save_section(
    req: StorySaveSectionRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Persist an edited section body (as a ``user_edits`` override),
    optionally changing its visibility, and commit a version to its history."""
    try:
        return await asyncio.to_thread(
            story.save_section,
            get_db(), uid, req.page_id, req.body, req.visibility,
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@app.post("/story/section/visibility")
async def story_set_visibility(
    req: StoryVisibilityRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Flip a whole section between ``public`` and ``private``."""
    try:
        return await asyncio.to_thread(
            story.set_visibility, get_db(), uid, req.page_id, req.visibility
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@app.post("/story/edit")
async def story_edit(
    req: StoryEditRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """One turn of the passage chat. Returns ``{reply, revised_body?, action,
    target_visibility?}`` — ``revised_body`` set only when Ayma proposes a
    concrete rewrite — or ``{usage_capped:true}``. Writes nothing."""
    try:
        return await story.edit_section(
            get_db(),
            uid,
            req.page_id,
            req.selection,
            [m.model_dump() for m in req.messages],
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@app.post("/story/section/remove")
async def story_remove_section(
    req: StoryRemoveSectionRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Delete a section from the editor (``ai_only`` + ``user_hidden``,
    ``ai_body`` untouched). Its pre-delete state stays in history so a revert
    brings it back."""
    try:
        return await asyncio.to_thread(
            story.remove_section, get_db(), uid, req.page_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@app.get("/story/section/{page_id}/versions")
async def story_section_versions(
    page_id: str, uid: str = Depends(require_uid)
) -> list[dict[str, object]]:
    """One section's version history, newest first."""
    return await asyncio.to_thread(
        story.list_section_versions, get_db(), uid, page_id
    )


@app.get("/story/section/{page_id}/versions/{version_id}")
async def story_section_version(
    page_id: str, version_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """One stored section version in full (body + visibility)."""
    try:
        return await asyncio.to_thread(
            story.get_section_version, get_db(), uid, page_id, version_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such version.")


@app.post("/story/section/revert")
async def story_section_revert(
    req: StorySectionRevertRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Restore one section's body + visibility from one of its own versions
    (never ``ai_body``); a section deleted after that version comes back."""
    try:
        return await asyncio.to_thread(
            story.revert_section, get_db(), uid, req.page_id, req.version_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such version.")


@app.get("/usage")
async def token_usage(uid: str = Depends(require_uid)) -> dict[str, object]:
    """This user's lifetime Gemini-token usage — the running total plus a
    per-feature breakdown (chat / voice / matching / wiki / explore / reengage)
    — and the derived credit balance (grant + top-ups − used)."""
    return await asyncio.to_thread(token_ledger.usage, uid)


@app.post("/credits/topup")
async def credits_topup(
    background: BackgroundTasks, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Reload the user's credit balance by ``CONFIG.credit_topup_amount``.
    Free for now — no payment. Returns the fresh usage view, and kicks off a
    background pass to re-ingest any conversations skipped while broke (§15)."""
    await asyncio.to_thread(
        token_ledger.topup, uid, CONFIG.credit_topup_amount
    )
    background.add_task(backfill_ops.drain, get_db(), uid)
    return await asyncio.to_thread(token_ledger.usage, uid)


class FeedbackRequest(BaseModel):
    category: str = Field(default="thumbs_down", max_length=40)
    note: str = Field(default="", max_length=4000)
    quote: str = Field(default="", max_length=4000)
    session_id: str = Field(default="", max_length=128)


@app.post("/feedback")
async def submit_feedback(
    req: FeedbackRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """One-tap / typed conversational feedback about Ayma's conduct (§15). Lands
    in the ``feedback`` bucket the weekly review aggregates; Ayma also writes
    here herself via ``record_feedback``."""
    fid = await asyncio.to_thread(
        feedback_ops.record,
        get_db(), uid, req.category, req.note,
        quote=req.quote, source="thumbs_down", session_id=req.session_id,
    )
    return {"ok": fid is not None, "id": fid}


class ProductFeedbackRequest(BaseModel):
    kind: Literal["bug", "idea"] = "bug"
    text: str = Field(min_length=1, max_length=4000)
    image_paths: list[str] = Field(default_factory=list, max_length=6)
    app_version: str = Field(default="", max_length=64)


@app.post("/product-feedback")
async def submit_product_feedback(
    req: ProductFeedbackRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Bug reports and feature requests from the Profile screen (§15). Ayma
    never reads this bucket — the dev team triages it by hand. Screenshots must
    already be uploaded under the caller's ``uploads/`` tree."""
    for p in req.image_paths:
        if p and not p.startswith(f"uploads/{uid}/"):
            raise HTTPException(
                status_code=403,
                detail="image_paths must be under the caller's uploads/ tree.",
            )
    fid = await asyncio.to_thread(
        feedback_ops.record_product,
        get_db(), uid, req.kind, req.text, req.image_paths,
        app_version=req.app_version,
    )
    return {"ok": fid is not None, "id": fid}


@app.get("/voice/presets")
async def voice_presets(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The selectable Gemini Live voice presets for the settings picker
    (§13.3). Includes the user's current choice."""
    import voices

    return {
        "presets": [
            {"name": n, "description": d}
            for n, d in voices.VOICE_PRESETS.items()
        ],
        "current": _ayma_voice_name(uid),
        "default": CONFIG.gemini_live_voice,
        # The accent/language is a free-text instruction, not a fixed list —
        # "Malayalam mixed with English", "a soft Southern US accent", etc.
        # current_language is whatever Ayma has as her default right now
        # (set here or learned from conversation via set_voice_preference).
        "current_language": _ayma_voice_language(uid),
        "language_examples": list(voices.LANGUAGE_EXAMPLES),
    }


@app.get("/voice/preview/{voice_name}")
async def voice_preview_endpoint(
    voice_name: str, uid: str = Depends(require_uid)
) -> dict[str, str]:
    """A short spoken "Hi, I'm Ayma…" sample in ``voice_name`` for the settings
    picker (§13.3). Generated once per preset via Gemini TTS, then cached in
    Storage — subsequent calls just return the cached clip's URL."""
    import voices
    import voice_preview

    if not voices.is_valid_voice(voice_name):
        raise HTTPException(status_code=404, detail="Unknown voice preset.")
    try:
        url = await voice_preview.preview_url(voice_name)
    except Exception as exc:  # noqa: BLE001 - surface TTS/storage failure as 502
        logger.exception("voice preview failed for %s", voice_name)
        raise HTTPException(
            status_code=502, detail="Could not generate a voice preview."
        ) from exc
    return {"url": url}


@app.get("/media/photos")
async def media_photos_list(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The current profile-photo grid (§8.3)."""
    import photo_ops

    return {"photos": await asyncio.to_thread(photo_ops.list_photos, get_db(), uid)}


class PhotoRef(BaseModel):
    media_id: str = Field(min_length=1, max_length=128)


def _media_storage_path(uid: str, media_id: str) -> str:
    """The ``storage_path`` on ``users/{uid}/user_media/{media_id}``, or
    ``""`` if it can't be read."""
    try:
        snap = (
            get_db()
            .collection("users")
            .document(uid)
            .collection("user_media")
            .document(media_id)
            .get()
        )
        return str((snap.to_dict() or {}).get("storage_path") or "").strip()
    except Exception:  # noqa: BLE001
        logger.exception(
            "media storage_path lookup failed for %s/%s", uid, media_id
        )
        return ""


@app.post("/media/photos")
async def media_photos_add(
    req: PhotoRef,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Add an already-processed photo to the grid (§8.7 step 6)."""
    import photo_ops

    try:
        photos = await asyncio.to_thread(
            photo_ops.add_photo, get_db(), uid, req.media_id
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    # Auto-analysis (§ auto analysis) on the user's own grid photo.
    storage_path = await asyncio.to_thread(
        _media_storage_path, uid, req.media_id
    )
    if storage_path:
        background.add_task(
            auto_analysis.analyse_photo, get_db(), uid, storage_path
        )
    return {"ok": True, "photos": photos}


@app.post("/media/photos/{media_id}/remove")
async def media_photos_remove(
    media_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Soft-remove a photo from the grid — the ``user_media`` doc, Storage
    file and embedding all stay (§8.3, §8.7 step 5)."""
    import photo_ops

    photos = await asyncio.to_thread(
        photo_ops.remove_photo, get_db(), uid, media_id
    )
    return {"ok": True, "photos": photos}


class PhotoOrder(BaseModel):
    media_ids: list[str] = Field(min_length=0, max_length=32)


@app.put("/media/photos/order")
async def media_photos_reorder(
    req: PhotoOrder, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Reorder the grid; ``media_ids[0]`` becomes the primary photo (§8.3)."""
    import photo_ops

    photos = await asyncio.to_thread(
        photo_ops.reorder_photos, get_db(), uid, req.media_ids
    )
    return {"ok": True, "photos": photos}


class FcmTokenRequest(BaseModel):
    token: str = Field(min_length=1, max_length=4096)


@app.post("/notifications/token")
async def notifications_register_token(
    req: FcmTokenRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Register/refresh this device's FCM token (§7.2, §7.9 step 2)."""
    try:
        await asyncio.to_thread(
            notifications_ops.register_token, get_db(), uid, req.token
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True}


@app.post("/notifications/token/remove")
async def notifications_unregister_token(
    req: FcmTokenRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Drop a device token (sign-out or token rotation)."""
    await asyncio.to_thread(
        notifications_ops.unregister_token, get_db(), uid, req.token
    )
    return {"ok": True}


@app.post("/run-matching")
async def run_matching(uid: str = Depends(require_uid)) -> dict[str, object]:
    """On-demand Pass 1 over the full pool (§5.3, §5.10 step 5). Writes
    ``users/{uid}/match_candidates/*``, feeds Explore. Heuristic-only — no
    Gemini call — so it's not credit-gated; the endpoint rate limit is the
    guard."""
    try:
        candidates = await asyncio.to_thread(
            matching.source_and_score, get_db(), uid, None
        )
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Matching failed: {exc}"
        ) from exc
    return {"ok": True, "candidates": len(candidates)}


class MatchResponseRequest(BaseModel):
    response: Literal["accept", "reject"]


@app.post("/match/{match_id}/respond")
async def match_respond(
    match_id: str,
    req: MatchResponseRequest,
    background: BackgroundTasks,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Accept or reject a scored match (§5.7, §14.3). Reject unmatches it;
    accept records this user's interest and flips to ``mutual_interest`` once
    both participants have accepted."""
    db = get_db()
    ref = db.collection(MATCHES_COLLECTION).document(match_id)
    snap = ref.get()
    if not snap.exists:
        raise HTTPException(status_code=404, detail="No such match.")
    data = snap.to_dict() or {}
    if uid not in (data.get("uids") or []):
        raise HTTPException(status_code=403, detail="Not your match.")

    if req.response == "reject":
        ref.set(
            {"status": "unmatched", "updated_at": _server_ts()}, merge=True
        )
        return {"ok": True, "status": "unmatched"}

    accepted = set(data.get("accepted_by") or [])
    accepted.add(uid)
    uids = list(data.get("uids") or [])
    both = accepted.issuperset(set(uids))
    already_mutual = data.get("status") == "mutual_interest"
    status = "mutual_interest" if both else data.get("status", "scored")
    ref.set(
        {
            "accepted_by": sorted(accepted),
            "status": status,
            "updated_at": _server_ts(),
        },
        merge=True,
    )
    if both and not already_mutual and len(uids) == 2:
        background.add_task(_notify_mutual_match, uids[0], uids[1])
    return {"ok": True, "status": status}


class CompatibilityRequest(BaseModel):
    other_uid: str = Field(min_length=1, max_length=128)


@app.post("/check-compatibility")
async def check_compatibility(
    req: CompatibilityRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """On-demand Pass 2 for one pair (§5.3, §5.10 step 6). Writes / updates
    ``matches/{matchId}``."""
    other = req.other_uid.strip()
    if other == uid:
        raise HTTPException(status_code=400, detail="Cannot match with self.")
    try:
        await asyncio.to_thread(token_ledger.check, uid)
    except token_ledger.TokenCapExceeded:
        return {"ok": False, "usage_capped": True}
    db = get_db()
    try:
        result = await matching_skill.score_pair(db, uid, other)
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Compatibility check failed: {exc}"
        ) from exc

    match_id = sorted_pair_key(uid, other)
    lo, hi = sorted((uid, other))
    ref = db.collection(MATCHES_COLLECTION).document(match_id)
    payload = {
        "uids": [lo, hi],
        "score": result["score"],
        "user_explanation": result["user_explanation"],
        "ai_explanation": result["ai_explanation"],
        "trust_flags": result["trust_flags"],
        "updated_at": _server_ts(),
    }
    if not ref.get().exists:
        payload["status"] = MATCH_STATUS_SCORED
        payload["scored_at"] = _server_ts()
    ref.set(payload, merge=True)
    return {"ok": True, "match_id": match_id, "score": result["score"]}


@app.post("/cron/purge-deleted", dependencies=[Depends(require_cron)])
async def cron_purge_deleted() -> dict:
    """Permanent purge of soft-deleted accounts past the recovery window
    (§3.6, §3.10 step 10). Daily Cloud Scheduler."""
    return await asyncio.to_thread(
        account_purge.purge_expired, get_db(), _bucket()
    )


@app.post("/cron/match", dependencies=[Depends(require_cron)])
async def cron_match(user_limit: int | None = None) -> dict:
    """Scheduled two-pass matching over the lighter pool (§5.3, §5.10 step 7)."""
    return await matching_cron.run(get_db(), user_limit)


@app.post("/cron/ingest-backfill", dependencies=[Depends(require_cron)])
async def cron_ingest_backfill(user_limit: int = 200) -> dict:
    """Nightly safety net (§15): re-ingest conversations that were skipped
    while a user was out of credits, for any user that now has some."""
    return await backfill_ops.sweep(get_db(), user_limit)


@app.post("/cron/reengage", dependencies=[Depends(require_cron)])
async def cron_reengage(user_limit: int | None = None) -> dict:
    """Scheduled re-engagement sweep (§7.1, §7.9 step 7). For each user idle
    past the threshold and out of backoff, Ayma writes one `raw_turns` message
    and a check-in push."""
    import reengagement

    return await reengagement.run(get_db(), user_limit)


@app.post("/cron/lint", dependencies=[Depends(require_cron)])
async def cron_lint(limit: int | None = None) -> dict:
    """Scheduled wiki lint (§2.3, §2.8 step 6). Cloud Scheduler hits this daily
    with the ``X-Cron-Secret`` header; ``?limit=`` caps the sweep for manual
    runs. Writes ``lint_flags`` onto affected pages, resolves nothing."""
    return await lint_all(get_db(), limit=limit)
