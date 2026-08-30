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

from auth import Caller, require_caller, require_cron, require_uid  # noqa: E402
from config import CONFIG  # noqa: E402
import gemini  # noqa: E402
from livekit_token import (  # noqa: E402
    LiveKitConfigError,
    build_room_seed,
    mint_access_token,
    room_name_for,
    seed_room_context,
)
import account_ops  # noqa: E402
import account_purge  # noqa: E402
import explore as explore_mod  # noqa: E402
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
from pair_key import sorted_pair_key, uids_from_pair_key  # noqa: E402
import media_embed  # noqa: E402
import photo_attrs  # noqa: E402
from media_embed import process_media  # noqa: E402
from db import get_db  # noqa: E402
from post_turn import persist_raw_turns  # noqa: E402
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
    mode = _session_mode(caller)
    system_prompt = compose_system_prompt(
        recent_turns=turns,
        wiki_context=read_wiki_context(get_db(), uid),
        session_mode=mode,
    )
    try:
        await seed_room_context(
            room, build_room_seed(system_prompt, turns, uid, session_id)
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


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)
    session_id: str = _SESSION_ID
    recent_turns: list[TurnModel] = Field(
        default_factory=list, max_length=_MAX_RECENT_TURNS
    )
    viewing_profile_uid: str = Field(default="", max_length=128)


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


@app.post("/chat")
async def chat(
    req: ChatRequest,
    background: BackgroundTasks,
    caller: Caller = Depends(require_caller),
) -> dict[str, object]:
    """Text chat turn (§1.7 step 2, §1.5, §3.3).

    Enforces the marketing / interview turn caps first (§3.10 step 3): at the
    cap Ayma nudges toward "get started" (or the client falls back to a manual
    form in interview mode), then further capped turns are refused. Otherwise
    the reply is seeded with the base persona + recent-turns window + wiki
    memory (§13.5), and ``raw_turns`` / wiki ingest run in the background.
    ``session_mode`` scoping of the prompt is Step 33.
    """
    uid = caller.uid
    mode = _session_mode(caller)
    cap = turn_caps.evaluate(get_db(), uid, mode)
    if not cap.allowed:
        return {
            "reply": cap.canned_reply or "",
            "capped": True,
            "fallback_form": cap.fallback_form,
            "turn_cap": {"mode": cap.mode, "count": cap.count, "cap": cap.cap},
        }

    window = _to_turns(req.recent_turns)
    system_prompt = compose_system_prompt(
        recent_turns=window,
        wiki_context=read_wiki_context(get_db(), uid),
        session_mode=mode,
        viewing_profile_context=_viewing_profile_context(
            get_db(), uid, req.viewing_profile_uid.strip()
        ),
    )
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


class MediaRequest(BaseModel):
    storage_path: str = Field(min_length=1, max_length=500)
    context: Literal["profile", "chat", "dm"] = "profile"


@app.post("/media")
async def register_media(
    req: MediaRequest, uid: str = Depends(require_uid)
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
    try:
        media_id = await asyncio.to_thread(
            process_media, get_db(), uid, req.storage_path, req.context
        )
    except Exception as exc:  # noqa: BLE001 - surface embed/storage failure
        raise HTTPException(
            status_code=502, detail=f"Media embedding failed: {exc}"
        ) from exc

    attrs = None
    if req.context == "profile":
        try:
            image, mime = await asyncio.to_thread(
                media_embed.download_bytes, req.storage_path
            )
            attrs = await photo_attrs.extract_attributes(image, mime)
            get_db().collection("users").document(uid).collection(
                "profile"
            ).document("main").set({"photo_attrs": attrs}, merge=True)
        except Exception:  # noqa: BLE001 - attribute extraction is best-effort
            logger.exception("photo attribute extraction failed for %s", uid)

    return {"ok": True, "media_id": media_id, "photo_attrs": attrs}


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
    nl = await explore_mod.parse_nl_query(q) if q.strip() else {}
    dropdown = {
        "location": location,
        "hair_color": hair_color,
        "glasses": glasses,
        "age_min": age_min,
        "age_max": age_max,
    }
    filters = explore_mod.merge_filters(dropdown, nl)
    cards = await asyncio.to_thread(
        explore_mod.explore, get_db(), uid, filters, min(limit, 60)
    )
    return {"cards": cards, "filters_applied": filters}


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
    ``users/{uid}/match_candidates/*``, feeds Explore."""
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
