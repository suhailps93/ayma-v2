"""AI Date Simulation (hackathon flagship, agents theme).

Watch your AI and theirs feel each other out before you message them. Two AI
personas hold a short, first-time conversation — the CURRENT USER's persona and
a MATCH's persona — each grounded in that person's real profile, capped at a
user-set number of messages. The user then sees the transcript plus a
compatibility read (a 0–100 score + a short "how it went" summary).

This is a ONE-SIDED simulation run entirely server-side: nothing is ever sent to
the other user. It reuses the Practice Date persona machinery (``practice_core``)
for both sides, generalised from "simulate one persona replying to the user" to
"run two personas back-and-forth":

* the USER's persona is grounded in their FULL own context
  (:func:`practice_core.build_self_persona_context` — profile + every wiki page,
  private spans kept, PLUS a capped sample of the user's OWN sent DM messages as
  texting-STYLE exemplars so it sounds like how the user actually texts; only
  the user's own messages, never the other participant's), because a user's own
  agent authentically represents them;
* the MATCH's persona is grounded ONLY in their viewer-visible PUBLIC profile
  (:func:`practice_core.build_persona_context` — the same privacy boundary
  Practice Date uses), because we may never read another user's private data.

Both personas run under ``prompts/date_sim.md``, whose disclosure filter keeps
each one from *emitting* private/sensitive specifics in the chat even though it
is grounded in full context (grounded-but-filtered — see
``tests/test_date_sim.py``). Every model call goes through ``practice_llm`` (the
shared per-surface provider: Gemini today, Meta Muse Spark on a flag flip) and
is metered to the user under ``FEATURE_DATE_SIM``; a user-set message cap bounds
the real spend of two personas conversing. The generated transcript is passed
through the same advisory DM moderation; like DMs it never blocks (nothing is
sent anywhere). 18+ gating mirrors Practice Date.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

import dm_moderation
import persona_snapshot
import practice_llm
import token_ledger
from auth import Caller, require_caller
from db import get_db
from billing import credits_for
from config import CONFIG
from practice_core import (
    PersonaContext,
    ai_avatar_enabled,
    build_persona_context,
)
from practice_date import require_not_underage_uid

logger = logging.getLogger("ayma.date_sim")

_PROMPT_DIR = Path(__file__).parent / "prompts"
_SIM_PROMPT_PATH = _PROMPT_DIR / "date_sim.md"
_VERDICT_PROMPT_PATH = _PROMPT_DIR / "date_sim_verdict.md"

_PERSONA_TOKEN = "{{PERSONA}}"
_SELF_NAME_TOKEN = "{{SELF_NAME}}"
_OTHER_NAME_TOKEN = "{{OTHER_NAME}}"

# Roles in the simulated transcript, from the VIEWING user's point of view.
ROLE_YOU = "you"  # the current user's persona
ROLE_THEM = "them"  # the match's persona

# Message-cap bounds (bounds the real spend of two personas conversing).
MIN_MESSAGES = 2
MAX_MESSAGES = 20
DEFAULT_MESSAGES = 6

# Hang guards: no single model call, and no whole run, may exceed these (Cloud
# Run's request timeout is 300s; leave headroom to write the final status).
TURN_TIMEOUT_S = 40.0
RUN_DEADLINE_S = 240.0

STATUS_RUNNING = "running"
STATUS_DONE = "done"
STATUS_ERROR = "error"

# Client-chosen sim id (so the client can start listening before the POST
# returns). Strictly validated: it becomes a Firestore doc id under the CALLER's
# own uid, so it can never address another user's data.
_SIM_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")

# Cost-estimate assumptions (deliberately conservative: better to over- than
# under-state). Per persona turn: ~2,500 input tokens of system prompt + persona
# grounding, plus ~60 tokens for each prior transcript message, and ~150 output
# tokens (a short chat line plus headroom for reasoning). The verdict call reads
# ~1,500 tokens of prompt plus the whole transcript and writes ~300.
_TURN_BASE_INPUT_TOKENS = 2500
_TOKENS_PER_MESSAGE = 60
_TURN_OUTPUT_TOKENS = 150
_VERDICT_BASE_INPUT_TOKENS = 1500
_VERDICT_OUTPUT_TOKENS = 300


class AvatarOptOut(Exception):
    """A party has opted out of an AI Avatar. ``who`` is ``"self"`` (the
    triggering user) or ``"match"`` (the other person)."""

    def __init__(self, who: str) -> None:
        super().__init__(who)
        self.who = who


_OPT_OUT_MESSAGES = {
    "self": "Turn on AI Avatar in Settings to use simulated dates.",
    "match": "This person has opted out of AI simulations.",
}


def estimate_credits(message_count: int) -> int:
    """Approximate credits a ``message_count``-message simulation will bill the
    triggering user (both personas' turns + the verdict), from the same
    pricing table and ``credits_per_usd`` the ledger uses."""
    usd = 0.0
    for i in range(message_count):
        usd += token_ledger.cost_usd_for(
            token_ledger.FEATURE_DATE_SIM,
            _TURN_BASE_INPUT_TOKENS + i * _TOKENS_PER_MESSAGE,
            _TURN_OUTPUT_TOKENS,
        )
    usd += token_ledger.cost_usd_for(
        token_ledger.FEATURE_DATE_SIM,
        _VERDICT_BASE_INPUT_TOKENS + message_count * _TOKENS_PER_MESSAGE,
        _VERDICT_OUTPUT_TOKENS,
    )
    return max(1, credits_for(usd, CONFIG))


_VERDICT_SCHEMA = {
    "type": "object",
    "properties": {
        "score": {"type": "integer"},
        "score_label": {"type": "string"},
        "summary": {"type": "string"},
    },
    "required": ["score", "score_label", "summary"],
}


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def compose_sim_prompt(
    ctx: PersonaContext,
    self_name: str,
    other_name: str,
    turns: list[dict],
    speaker_role: str,
) -> tuple[str, str]:
    """``(system_prompt, user_message)`` for ``self_name``'s next turn.

    The system prompt is ``date_sim.md`` with the speaker's own grounding block
    and both names filled in. The user message carries the conversation so far
    rendered from the speaker's point of view (their own lines labelled by their
    name, the other persona's by theirs) plus the explicit instruction to send
    the next message — or, on an empty transcript, to open the conversation."""
    system = (
        _read(_SIM_PROMPT_PATH)
        .replace(_SELF_NAME_TOKEN, self_name)
        .replace(_OTHER_NAME_TOKEN, other_name)
        .replace(_PERSONA_TOKEN, ctx.to_prompt_block())
    )
    lines: list[str] = []
    for t in turns:
        who = self_name if t.get("role") == speaker_role else other_name
        text = str(t.get("text") or "").strip()
        if text:
            lines.append(f"{who}: {text}")
    if lines:
        message = (
            "Conversation so far:\n"
            + "\n".join(lines)
            + f"\n\nYou are {self_name}. Reply to {other_name} with your next "
            "message. Stay in character and keep it natural."
        )
    else:
        message = (
            f"You are {self_name}. Start the conversation with {other_name} — "
            "send a natural opening message, the way you really would."
        )
    return system, message


async def _verdict(
    self_name: str, other_name: str, transcript: list[dict], *, uid: str
) -> dict:
    """The compatibility read: ``{score (0-100), score_label, summary}``.

    Grounded only in the simulated transcript. Raises on a model/transport
    failure so the caller can decide (the endpoint returns 502)."""
    convo = "\n".join(
        f"{self_name if t['from'] == ROLE_YOU else other_name}: {t['text']}"
        for t in transcript
    )
    result = await practice_llm.generate_structured(
        _read(_VERDICT_PROMPT_PATH),
        (
            f"The user is {self_name} ('you'); the potential match is "
            f"{other_name} ('them'). Simulated first conversation:\n{convo}"
        ),
        _VERDICT_SCHEMA,
        uid=uid,
        feature=token_ledger.FEATURE_DATE_SIM,
    )
    if not isinstance(result, dict):
        raise RuntimeError("verdict model returned a non-object response")
    try:
        score = int(result.get("score"))
    except (TypeError, ValueError):
        score = 0
    score = max(0, min(100, score))
    return {
        "score": score,
        "score_label": str(result.get("score_label") or "").strip(),
        "summary": str(result.get("summary") or "").strip(),
    }


def _sims(db, uid: str):
    return db.collection("users").document(uid).collection("date_sims")


async def _write(fn, *args, **kwargs) -> None:
    await asyncio.to_thread(fn, *args, **kwargs)


async def run_simulation(
    db, uid: str, other_uid: str, max_messages: int, sim_id: str | None = None
) -> dict:
    """Run the two-persona conversation, streaming it to Firestore, and return
    the transcript + verdict.

    Grounds the user's persona in their FULL own context and the match's in
    their PUBLIC profile only, alternates up to ``max_messages`` turns (the user
    opens), moderates the result (advisory, never blocks — nothing is sent), and
    produces the compatibility read.

    Live streaming: once both personas are built, a parent doc
    ``users/{uid}/date_sims/{sim_id}`` is created (``status: running``) and each
    turn is written to its ``messages/{seq}`` subcollection the moment it is
    produced; the verdict + ``status: done`` land at the end, or ``status:
    error`` with a reason (partial transcript kept) on any failure. The client
    reads ONLY these docs (owner-read rules, Admin-SDK writes) and never needs
    the POST response. Each turn is bounded by ``TURN_TIMEOUT_S`` and the whole
    run by ``RUN_DEADLINE_S`` so it can never hang.

    Raises :class:`ValueError` when the match has no simulatable public profile,
    :class:`AvatarOptOut` when either party has opted out of an AI Avatar (both
    before anything is written), and :class:`token_ledger.TokenCapExceeded`
    only when the user is out of credits before the first message is produced;
    running out mid-conversation returns the partial transcript with
    ``usage_capped`` set (and no further metered verdict call)."""
    if not ai_avatar_enabled(db, uid):
        raise AvatarOptOut("self")
    if not ai_avatar_enabled(db, other_uid):
        raise AvatarOptOut("match")
    # SELF: spawn from the standing avatar snapshot — instant, no live
    # assembly (persona_snapshot). If one does not exist yet, seed it ONCE here,
    # LLM-free (distill=False), and persist it; the background sweep later
    # upgrades it with the distilled brief. The avatar is NEVER rebuilt with an
    # LLM on this spawn hot path.
    self_ctx = persona_snapshot.get_persona_snapshot(db, uid)
    if self_ctx is None:
        self_ctx = await persona_snapshot.build_persona_snapshot(
            db, uid, distill=False
        )
    if self_ctx is None:
        raise ValueError("no profile for the current user")
    # MATCH: when the match has their own private-grounded avatar snapshot
    # (AI Avatar is already confirmed on above), spawn THEIR snapshot — their
    # own full-context, non-disclosure avatar. Otherwise fall back to the
    # public-profile-only persona, because we may never read another user's
    # private data to build one on their behalf.
    match_ctx = persona_snapshot.get_persona_snapshot(db, other_uid)
    if match_ctx is None:
        match_ctx = build_persona_context(db, uid, other_uid)
    if match_ctx is None:
        raise ValueError("no simulatable profile for the match")

    self_name = self_ctx.name
    other_name = match_ctx.name
    session_id = f"datesim_{uuid.uuid4().hex}"
    cap = max(MIN_MESSAGES, min(MAX_MESSAGES, int(max_messages)))
    persona = {
        "name": match_ctx.name,
        "age": match_ctx.age,
        "location": match_ctx.location,
        "photo_count": match_ctx.photo_count,
        "photo_url": match_ctx.photo_url,
    }
    banner = f"Simulated — not sent to {match_ctx.name}."

    sim_id = sim_id or uuid.uuid4().hex
    sim_ref = _sims(db, uid).document(sim_id)
    await _write(
        sim_ref.set,
        {
            "status": STATUS_RUNNING,
            "other_uid": other_uid,
            "max_messages": cap,
            "estimate": estimate_credits(cap),
            "persona": persona,
            "banner": banner,
            "created_at": datetime.now(timezone.utc),
        },
    )

    transcript: list[dict] = []
    turns: list[dict] = []
    usage_capped = False
    deadline = time.monotonic() + RUN_DEADLINE_S

    async def _fail(code: str, reason: str) -> None:
        try:
            await _write(
                sim_ref.update,
                {"status": STATUS_ERROR, "error": {"code": code, "message": reason}},
            )
        except Exception:  # noqa: BLE001 - best effort; the original error wins
            logger.warning("date-sim could not record failure", exc_info=True)

    try:
        for i in range(cap):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise asyncio.TimeoutError()
            role = ROLE_YOU if i % 2 == 0 else ROLE_THEM
            if role == ROLE_YOU:
                ctx, speaker, other = self_ctx, self_name, other_name
            else:
                ctx, speaker, other = match_ctx, other_name, self_name
            system, message = compose_sim_prompt(ctx, speaker, other, turns, role)
            try:
                text = await asyncio.wait_for(
                    practice_llm.generate_text(
                        system,
                        message,
                        uid=uid,
                        feature=token_ledger.FEATURE_DATE_SIM,
                        session_id=session_id,
                    ),
                    timeout=min(TURN_TIMEOUT_S, remaining),
                )
            except token_ledger.TokenCapExceeded:
                if not transcript:
                    raise
                usage_capped = True
                break
            text = text.strip()
            if not text:
                break
            turns.append({"role": role, "text": text})
            transcript.append({"from": role, "text": text})
            await _write(
                sim_ref.collection("messages").document(f"{i:03d}").set,
                {
                    "seq": i,
                    "speaker": role,
                    "text": text,
                    "at": datetime.now(timezone.utc),
                },
            )

        # Advisory moderation over the whole generated conversation — same DM
        # policy: annotate, never block (nothing is sent to anyone).
        moderation = await dm_moderation.moderate(
            "\n".join(t["text"] for t in transcript)
        )

        verdict: dict = {"score": 0, "score_label": "", "summary": ""}
        if transcript and not usage_capped:
            try:
                verdict = await asyncio.wait_for(
                    _verdict(self_name, other_name, transcript, uid=uid),
                    timeout=max(1.0, min(TURN_TIMEOUT_S, deadline - time.monotonic())),
                )
            except token_ledger.TokenCapExceeded:
                usage_capped = True
            except Exception:  # noqa: BLE001 - a verdict failure keeps the transcript
                logger.warning("date-sim verdict failed", exc_info=True)

        mod = {
            "flagged": bool(moderation.get("flagged")),
            "categories": list(moderation.get("categories") or []),
        }
        await _write(
            sim_ref.update,
            {
                "status": STATUS_DONE,
                "verdict": verdict,
                "moderation": mod,
                "usage_capped": usage_capped,
                "finished_at": datetime.now(timezone.utc),
            },
        )
    except token_ledger.TokenCapExceeded:
        await _fail("out_of_credits", "Out of credits.")
        raise
    except asyncio.TimeoutError:
        await _fail("timeout", "The simulation took too long and was stopped.")
        raise
    except Exception:
        logger.warning("date-sim failed", exc_info=True)
        await _fail("failed", "The simulation failed.")
        raise

    return {
        "simulation": True,
        "sim_id": sim_id,
        "persona": persona,
        "banner": banner,
        "transcript": transcript,
        "score": verdict["score"],
        "score_label": verdict["score_label"],
        "summary": verdict["summary"],
        "moderation": mod,
        "usage_capped": usage_capped,
    }


# --------------------------------------------------------------------------- #
# HTTP API (mounted by main.py via app.include_router)
# --------------------------------------------------------------------------- #
router = APIRouter(tags=["date_sim"])


class DateSimRequest(BaseModel):
    other_uid: str = Field(..., min_length=1, max_length=128)
    max_messages: int = Field(DEFAULT_MESSAGES, ge=MIN_MESSAGES, le=MAX_MESSAGES)
    sim_id: str | None = Field(None, max_length=64)


@router.get("/date-sim/estimate")
async def date_sim_estimate(
    other_uid: str | None = None,
    caller: Caller = Depends(require_caller),
) -> dict[str, object]:
    """Approximate credits for each allowed message count, so the setup screen
    can warn about the cost before the run (both agents bill the caller).

    When ``other_uid`` is supplied (the sim setup screen already knows who it is
    about to simulate), also returns a ``readiness`` block for that match —
    ``{name, readiness_score (0-100), low_context, message?}`` — so the UI can
    warn when the match "doesn't have much context yet" before spending
    credits. Omitted when the match has no simulatable profile / has opted out."""
    out: dict[str, object] = {
        "credits_by_messages": {
            str(n): estimate_credits(n)
            for n in range(MIN_MESSAGES, MAX_MESSAGES + 1)
        }
    }
    if other_uid and other_uid.strip():
        readiness = await asyncio.to_thread(
            persona_snapshot.preflight_readiness,
            get_db(),
            caller.uid,
            other_uid.strip(),
        )
        if readiness is not None:
            out["readiness"] = readiness
    return out


@router.post("/date-sim", dependencies=[Depends(require_not_underage_uid)])
async def date_sim(
    req: DateSimRequest, caller: Caller = Depends(require_caller)
) -> dict[str, object]:
    """Run an AI date simulation against ``other_uid``'s public profile.

    Two personas (the caller's — grounded in their full own context — and the
    match's — public-profile-only) hold a bounded conversation. The transcript
    streams to ``users/{uid}/date_sims/{sim_id}`` (owner-readable) as it is
    generated; the client listens there and does not depend on this response,
    which just reports the final status. Nothing is sent to the other user."""
    db = get_db()
    # Out of credits → 402 before spending anything (mirrors Practice Date).
    try:
        await asyncio.to_thread(token_ledger.check, caller.uid)
    except token_ledger.TokenCapExceeded as exc:
        raise HTTPException(status_code=402, detail="Out of credits.") from exc

    sim_id = req.sim_id
    if sim_id is not None and not _SIM_ID_RE.match(sim_id):
        raise HTTPException(status_code=422, detail="Invalid sim_id.")
    if sim_id is not None:
        existing = await asyncio.to_thread(_sims(db, caller.uid).document(sim_id).get)
        if existing.exists:
            raise HTTPException(status_code=409, detail="sim_id already used.")

    try:
        out = await run_simulation(
            db, caller.uid, req.other_uid.strip(), req.max_messages, sim_id
        )
        return {"sim_id": out["sim_id"], "status": STATUS_DONE}
    except token_ledger.TokenCapExceeded as exc:
        raise HTTPException(status_code=402, detail="Out of credits.") from exc
    except AvatarOptOut as exc:
        raise HTTPException(
            status_code=403,
            detail={
                "code": f"ai_avatar_opt_out_{exc.who}",
                "message": _OPT_OUT_MESSAGES[exc.who],
            },
        ) from exc
    except ValueError as exc:
        raise HTTPException(
            status_code=404, detail="No profile to simulate a date with."
        ) from exc
    except Exception as exc:  # noqa: BLE001 - model/transport failure → 502
        raise HTTPException(
            status_code=502, detail=f"Date simulation failed: {exc}"
        ) from exc
