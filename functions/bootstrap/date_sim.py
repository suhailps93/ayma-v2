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
  private spans kept), because a user's own agent authentically represents them;
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
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

import dm_moderation
import practice_llm
import token_ledger
from auth import Caller, require_caller
from db import get_db
from practice_core import (
    PersonaContext,
    build_persona_context,
    build_self_persona_context,
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


async def run_simulation(
    db, uid: str, other_uid: str, max_messages: int
) -> dict:
    """Run the two-persona conversation and return the transcript + verdict.

    Grounds the user's persona in their FULL own context and the match's in
    their PUBLIC profile only, alternates up to ``max_messages`` turns (the user
    opens), moderates the result (advisory, never blocks — nothing is sent), and
    produces the compatibility read. Raises :class:`ValueError` when the match
    has no simulatable public profile, and :class:`token_ledger.TokenCapExceeded`
    only when the user is out of credits before the first message is produced;
    running out mid-conversation returns the partial transcript with
    ``usage_capped`` set (and no further metered verdict call)."""
    self_ctx = build_self_persona_context(db, uid)
    if self_ctx is None:
        raise ValueError("no profile for the current user")
    match_ctx = build_persona_context(db, uid, other_uid)
    if match_ctx is None:
        raise ValueError("no simulatable profile for the match")

    self_name = self_ctx.name
    other_name = match_ctx.name
    session_id = f"datesim_{uuid.uuid4().hex}"
    cap = max(MIN_MESSAGES, min(MAX_MESSAGES, int(max_messages)))

    transcript: list[dict] = []
    turns: list[dict] = []
    usage_capped = False
    for i in range(cap):
        role = ROLE_YOU if i % 2 == 0 else ROLE_THEM
        if role == ROLE_YOU:
            ctx, speaker, other = self_ctx, self_name, other_name
        else:
            ctx, speaker, other = match_ctx, other_name, self_name
        system, message = compose_sim_prompt(ctx, speaker, other, turns, role)
        try:
            text = await practice_llm.generate_text(
                system,
                message,
                uid=uid,
                feature=token_ledger.FEATURE_DATE_SIM,
                session_id=session_id,
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

    # Advisory moderation over the whole generated conversation — same DM
    # policy: annotate, never block (nothing is sent to anyone).
    moderation = await dm_moderation.moderate(
        "\n".join(t["text"] for t in transcript)
    )

    verdict: dict = {"score": 0, "score_label": "", "summary": ""}
    if transcript and not usage_capped:
        try:
            verdict = await _verdict(
                self_name, other_name, transcript, uid=uid
            )
        except token_ledger.TokenCapExceeded:
            usage_capped = True
        except Exception:  # noqa: BLE001 - a verdict failure keeps the transcript
            logger.warning("date-sim verdict failed", exc_info=True)

    return {
        "simulation": True,
        "persona": {
            "name": match_ctx.name,
            "age": match_ctx.age,
            "location": match_ctx.location,
            "photo_count": match_ctx.photo_count,
            "photo_url": match_ctx.photo_url,
        },
        "banner": f"Simulated — not sent to {match_ctx.name}.",
        "transcript": transcript,
        "score": verdict["score"],
        "score_label": verdict["score_label"],
        "summary": verdict["summary"],
        "moderation": {
            "flagged": bool(moderation.get("flagged")),
            "categories": list(moderation.get("categories") or []),
        },
        "usage_capped": usage_capped,
    }


# --------------------------------------------------------------------------- #
# HTTP API (mounted by main.py via app.include_router)
# --------------------------------------------------------------------------- #
router = APIRouter(tags=["date_sim"])


class DateSimRequest(BaseModel):
    other_uid: str = Field(..., min_length=1, max_length=128)
    max_messages: int = Field(DEFAULT_MESSAGES, ge=MIN_MESSAGES, le=MAX_MESSAGES)


@router.post("/date-sim", dependencies=[Depends(require_not_underage_uid)])
async def date_sim(
    req: DateSimRequest, caller: Caller = Depends(require_caller)
) -> dict[str, object]:
    """Run an AI date simulation against ``other_uid``'s public profile.

    Two personas (the caller's — grounded in their full own context — and the
    match's — public-profile-only) hold a bounded conversation; returns the
    transcript, a 0–100 compatibility score, a label and a short summary.
    Nothing is sent to the other user."""
    db = get_db()
    # Out of credits → 402 before spending anything (mirrors Practice Date).
    try:
        await asyncio.to_thread(token_ledger.check, caller.uid)
    except token_ledger.TokenCapExceeded as exc:
        raise HTTPException(status_code=402, detail="Out of credits.") from exc

    try:
        return await run_simulation(
            db, caller.uid, req.other_uid.strip(), req.max_messages
        )
    except token_ledger.TokenCapExceeded as exc:
        raise HTTPException(status_code=402, detail="Out of credits.") from exc
    except ValueError as exc:
        raise HTTPException(
            status_code=404, detail="No profile to simulate a date with."
        ) from exc
    except Exception as exc:  # noqa: BLE001 - model/transport failure → 502
        raise HTTPException(
            status_code=502, detail=f"Date simulation failed: {exc}"
        ) from exc
