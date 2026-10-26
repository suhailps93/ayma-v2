"""Practice Date domain core (hackathon deliverable B).

The fastapi-free heart of Practice Date: the persona context (the privacy
boundary), prompt composition, the model calls (persona reply, live coach,
debrief) through ``practice_llm``, and the Firestore session store. It is kept
separate from the HTTP layer in ``practice_date.py`` for one concrete reason:
the LiveKit voice agent worker (``agent.py``) runs in a deliberately lean
runtime that carries NO web stack (no fastapi) — see ``requirements-agent.txt``
— yet it needs these exact primitives to run the simulated-persona voice
session and its live coach. ``practice_date`` re-exports everything here, so the
feature's public surface is unchanged and the text path is untouched.

PRIVACY IS THE HEADLINE (judging asset). The persona is built ONLY from the
viewer-visible profile — the exact same serializer the profile screen uses
(:func:`public_profile.build`), which already filters wiki pages to
``visibility == "public"`` AT QUERY LEVEL and strips ``{{private}}`` /
``{{ai_only}}`` spans. :func:`build_persona_context` then whitelists only the
persona-appropriate fields out of that view; it reads NOTHING else about the
target (no raw ``profile/main`` doc, no matches/likes, no contact fields, no
other users). So the never-load data is never fetched into the persona context,
not merely omitted from the prompt — see ``NEVER_LOAD`` and
``tests/test_practice_extraction.py``.

Provider: every model call goes through ``practice_llm`` (``LLM_PROVIDER``,
default gemini today; flips to Meta Muse Spark later). Voice reuses the existing
LiveKit pipeline — :func:`compose_persona_prompt` produces the system prompt a
practice voice room seeds with; see docs/PRACTICE_DATE.md for that seam.
"""

from __future__ import annotations

import logging
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

import practice_llm
import public_profile
import token_ledger

logger = logging.getLogger("ayma.practice_date")

_PROMPT_DIR = Path(__file__).parent / "prompts"
_PERSONA_PROMPT_PATH = _PROMPT_DIR / "practice_persona.md"
_COACH_PROMPT_PATH = _PROMPT_DIR / "practice_coach.md"
_DEBRIEF_PROMPT_PATH = _PROMPT_DIR / "practice_debrief.md"

_PERSONA_TOKEN = "{{PERSONA}}"

PRACTICE_SESSIONS_COLLECTION = "practice_sessions"
_MAX_TURNS = 100  # hard ceiling on stored turns per practice session

# The categories that must NEVER be loaded into a persona context. This is the
# documented contract the extraction test enforces; the enforcement itself is
# structural (we only ever read :func:`public_profile.build`'s already-filtered
# view and whitelist from it) rather than a post-hoc scrub.
NEVER_LOAD = (
    "exact location / GPS coordinates",
    "contact info — phone, email, street address, social handles",
    "other matches / people they are seeing or talking to",
    "private or ai-only wiki spans",
    "internal / admin data",
    "any other user's data",
)

ROLE_USER = "user"
ROLE_MATCH = "match"

_COACH_SCHEMA = {
    "type": "object",
    "properties": {"hint": {"type": "string"}},
    "required": ["hint"],
}

_DEBRIEF_SCHEMA = {
    "type": "object",
    "properties": {
        "what_worked": {"type": "array", "items": {"type": "string"}},
        "suggested_next_lines": {"type": "array", "items": {"type": "string"}},
        "avoid": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["what_worked", "suggested_next_lines", "avoid"],
}


# --------------------------------------------------------------------------- #
# Persona context — the privacy boundary
# --------------------------------------------------------------------------- #
@dataclass
class PersonaContext:
    """The whitelisted, viewer-visible facts a persona is allowed to know.

    Built only from :func:`public_profile.build`. Nothing on this object may
    carry a value from any ``NEVER_LOAD`` category — ``location`` is the coarse
    city string shown on the profile card, never coordinates."""

    target_uid: str
    name: str
    age: int | None
    location: str
    pages: list[dict] = field(default_factory=list)  # [{title, body}]
    photo_count: int = 0

    def to_prompt_block(self) -> str:
        lines = [f"Name: {self.name}"]
        if self.age:
            lines.append(f"Age: {self.age}")
        if self.location:
            lines.append(f"Lives in (city only): {self.location}")
        if self.photo_count:
            lines.append(f"Profile photos: {self.photo_count}")
        for p in self.pages:
            title = (p.get("title") or "Note").strip()
            body = " ".join(str(p.get("body") or "").split())
            if body:
                lines.append(f"\n[{title}]\n{body}")
        return "\n".join(lines).strip()


def build_persona_context(
    db, viewer_uid: str, target_uid: str
) -> PersonaContext | None:
    """Assemble the persona context for ``target_uid`` as seen by ``viewer_uid``.

    This is the privacy boundary. It calls ONLY :func:`public_profile.build`
    (which blocks cross-user reads it isn't allowed to make, filters wiki to
    ``visibility == "public"`` at query level, and strips private/ai-only
    spans) and then copies out only the persona-appropriate fields. It reads
    nothing from any ``NEVER_LOAD`` category. Returns ``None`` when there is no
    real, set-up, reachable profile to simulate (missing, deleted, or blocked)."""
    view = public_profile.build(db, viewer_uid, target_uid)
    if not view:
        return None
    if view.get("deleted") or view.get("blocked") or view.get("self"):
        return None
    name = str(view.get("name") or "").strip()
    if not name:
        return None

    pages = [
        {
            "title": str(p.get("title") or p.get("page_type") or "Note"),
            "body": str(p.get("body") or "").strip(),
        }
        for p in (view.get("pages") or [])
        if str(p.get("body") or "").strip()
    ]
    return PersonaContext(
        target_uid=target_uid,
        name=name,
        age=view.get("age"),
        location=str(view.get("location") or ""),
        pages=pages,
        photo_count=len(view.get("photos") or []),
    )


def persona_context_for_coach(name: str, target_uid: str = "") -> PersonaContext:
    """A name-only persona context for the VOICE live coach (hackathon B).

    The voice agent worker drives the live coach as the user speaks, but it
    must never re-read the target's profile — the privacy boundary is crossed
    exactly once, server-side, when :func:`build_persona_context` composes the
    seeded persona prompt. The coach only ever needs the match's (public)
    display name plus the running transcript, so the worker rebuilds this
    minimal context from the ``persona_name`` the seed already carries rather
    than loading anything new. Nothing here can hold a ``NEVER_LOAD`` value."""
    return PersonaContext(
        target_uid=target_uid,
        name=str(name or "").strip(),
        age=None,
        location="",
        pages=[],
        photo_count=0,
    )


# --------------------------------------------------------------------------- #
# Prompt composition
# --------------------------------------------------------------------------- #
def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def _format_transcript(turns: list[dict]) -> str:
    """Render stored turns as a plain conversation block for the model."""
    out: list[str] = []
    for t in turns:
        who = "You" if t.get("role") == ROLE_MATCH else "Them"
        text = str(t.get("text") or "").strip()
        if text:
            out.append(f"{who}: {text}")
    return "\n".join(out)


def compose_persona_prompt(ctx: PersonaContext, turns: list[dict] | None = None) -> str:
    """The persona system prompt: the roleplay template with the whitelisted
    persona block injected, plus the conversation-so-far from the match's point
    of view. Used by text practice and seeded into a practice voice room."""
    base = _read(_PERSONA_PROMPT_PATH).replace(_PERSONA_TOKEN, ctx.to_prompt_block())
    if turns:
        convo = []
        for t in turns:
            who = "Me" if t.get("role") == ROLE_MATCH else "Them"
            text = str(t.get("text") or "").strip()
            if text:
                convo.append(f"{who}: {text}")
        if convo:
            base += (
                "\n\n## Conversation so far (you are \"Me\")\n"
                + "\n".join(convo)
                + "\n\nReply as the match to their latest message. Stay in character."
            )
    return base


def compose_coach_prompt() -> str:
    return _read(_COACH_PROMPT_PATH)


def compose_debrief_prompt() -> str:
    return _read(_DEBRIEF_PROMPT_PATH)


# --------------------------------------------------------------------------- #
# Model calls
# --------------------------------------------------------------------------- #
async def persona_reply(
    ctx: PersonaContext, turns: list[dict], message: str, *, uid: str, session_id: str
) -> str:
    """The match's in-character reply to the user's latest ``message``."""
    system = compose_persona_prompt(ctx, turns)
    return (
        await practice_llm.generate_text(
            system,
            message,
            uid=uid,
            feature=token_ledger.FEATURE_PRACTICE,
            session_id=session_id,
        )
    ).strip()


async def coach_hint(
    ctx: PersonaContext, turns: list[dict], *, uid: str
) -> str:
    """A single short, best-effort live coaching nudge for the user. Never
    raises — a coach failure must not break the practice turn."""
    try:
        convo = _format_transcript(turns)
        result = await practice_llm.generate_structured(
            compose_coach_prompt(),
            f"The match is {ctx.name}. Conversation so far:\n{convo}",
            _COACH_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_PRACTICE,
        )
        if isinstance(result, dict):
            return str(result.get("hint") or "").strip()
    except Exception:  # noqa: BLE001 - coaching is advisory
        logger.warning("practice coach hint failed", exc_info=True)
    return ""


async def generate_debrief(
    ctx: PersonaContext, turns: list[dict], *, uid: str
) -> dict:
    """The end-of-session debrief: what worked / suggested next lines / avoid."""
    convo = _format_transcript(turns)
    result = await practice_llm.generate_structured(
        compose_debrief_prompt(),
        f"The match is {ctx.name}. Full practice transcript:\n{convo}",
        _DEBRIEF_SCHEMA,
        uid=uid,
        feature=token_ledger.FEATURE_PRACTICE,
    )
    if not isinstance(result, dict):
        raise RuntimeError("debrief model returned a non-object response")

    def _list(key: str) -> list[str]:
        return [str(x).strip() for x in (result.get(key) or []) if str(x).strip()]

    return {
        "what_worked": _list("what_worked"),
        "suggested_next_lines": _list("suggested_next_lines"),
        "avoid": _list("avoid"),
    }


# --------------------------------------------------------------------------- #
# Session store (Firestore: users/{uid}/practice_sessions/{session_id})
# --------------------------------------------------------------------------- #
def _session_ref(db, uid: str, session_id: str):
    return (
        db.collection("users")
        .document(uid)
        .collection(PRACTICE_SESSIONS_COLLECTION)
        .document(session_id)
    )


def start_session(db, uid: str, target_uid: str) -> str:
    """Create a practice session and return its id. Raises
    :class:`ValueError` if ``target_uid`` has no simulatable profile."""
    if build_persona_context(db, uid, target_uid) is None:
        raise ValueError("no simulatable profile for target")
    session_id = f"practice_{uuid.uuid4().hex}"
    _session_ref(db, uid, session_id).set(
        {
            "target_uid": target_uid,
            "created_at": time.time(),
            "ended_at": None,
            "turns": [],
        }
    )
    return session_id


def _load_session(db, uid: str, session_id: str) -> dict:
    snap = _session_ref(db, uid, session_id).get()
    if not getattr(snap, "exists", False):
        raise KeyError(session_id)
    return snap.to_dict() or {}


def append_turns(db, uid: str, session_id: str, new_turns: list[dict]) -> list[dict]:
    """Append ``new_turns`` (each ``{role, text}``) and return the full turn
    list. Caps stored turns at ``_MAX_TURNS`` (oldest dropped)."""
    data = _load_session(db, uid, session_id)
    turns = list(data.get("turns") or [])
    stamped = [
        {"role": t["role"], "text": str(t["text"]), "ts": time.time()}
        for t in new_turns
    ]
    turns.extend(stamped)
    turns = turns[-_MAX_TURNS:]
    _session_ref(db, uid, session_id).update({"turns": turns})
    return turns


def end_session(db, uid: str, session_id: str) -> None:
    _session_ref(db, uid, session_id).update({"ended_at": time.time()})
