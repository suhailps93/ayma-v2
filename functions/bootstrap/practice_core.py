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

import dm_schema
import practice_llm
import public_profile
import schema
import token_ledger

logger = logging.getLogger("ayma.practice_date")

_PROMPT_DIR = Path(__file__).parent / "prompts"
_PERSONA_PROMPT_PATH = _PROMPT_DIR / "practice_persona.md"
# Voice-call framing appended to the persona prompt ONLY on the voice path: the
# persona is answering a live phone call from the user, not texting (see
# :func:`compose_persona_prompt`). The text path never loads this.
_PERSONA_VOICE_PROMPT_PATH = _PROMPT_DIR / "practice_persona_voice.md"
_COACH_PROMPT_PATH = _PROMPT_DIR / "practice_coach.md"
_DEBRIEF_PROMPT_PATH = _PROMPT_DIR / "practice_debrief.md"

_PERSONA_TOKEN = "{{PERSONA}}"
_USER_NAME_TOKEN = "{{USER_NAME}}"

PRACTICE_SESSIONS_COLLECTION = "practice_sessions"
_MAX_TURNS = 100  # hard ceiling on stored turns per practice session

# Self-persona texting-style exemplars (AI Date Simulation, founder directive
# 2026-10-27): a CAPPED sample of the USER'S OWN recent, short sent DM messages,
# read ONLY by :func:`build_self_persona_context` so the user's own agent can
# mirror how they actually text. The caps bound tokens/credits; short messages
# are preferred because they best show casual texting voice. The gatherer reads
# ONLY messages this user sent (``sender_uid == uid``) — never the other
# participant's content (hard privacy boundary).
_SELF_STYLE_THREAD_SCAN = 40  # at most this many of the user's own DM threads
_SELF_STYLE_MSGS_PER_THREAD = 60  # recent messages scanned per thread
_SELF_STYLE_MAX_MESSAGES = 40  # exemplars kept
_SELF_STYLE_MAX_MSG_CHARS = 200  # skip long messages — want quick, casual texts
_SELF_STYLE_MAX_TOTAL_CHARS = 2000  # hard total-char cap across all exemplars

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
    # The match's profile gender ("woman"/"man"/"non-binary"/free text, or "").
    # Viewer-visible (shown on the profile card) — no privacy concern. Drives
    # the gender-matched TTS voice for the voice call (agent.py) and the coach's
    # pronouns (:func:`pronouns_for_gender`), and is surfaced in the persona
    # prompt so the simulated match stays consistent about who they are.
    gender: str = ""
    pages: list[dict] = field(default_factory=list)  # [{title, body}]
    # Texting-STYLE exemplars: a capped sample of the user's OWN recent short
    # sent DM messages, used ONLY by :func:`build_self_persona_context` so the
    # user's own agent can sound like how they actually text. NEVER populated
    # for the MATCH persona (:func:`build_persona_context` leaves it empty), and
    # it never holds another user's message content — the gatherer reads only
    # messages whose ``sender_uid`` is this user (see
    # :func:`_gather_self_style_exemplars`). Style only; the disclosure filter in
    # ``prompts/date_sim.md`` still forbids leaking any private specifics.
    style_exemplars: list[str] = field(default_factory=list)
    photo_count: int = 0
    # The match's PRIMARY public photo URL (first of the viewer-visible grid),
    # or ``None`` when the profile has no photos. Photos are public, so this is
    # no privacy concern; it is surfaced to the client for the voice-call avatar
    # and is NOT injected into the persona prompt (it isn't persona knowledge).
    photo_url: str | None = None

    def to_prompt_block(self) -> str:
        lines = [f"Name: {self.name}"]
        if self.age:
            lines.append(f"Age: {self.age}")
        if self.gender:
            lines.append(f"Gender: {self.gender}")
        if self.location:
            lines.append(f"Lives in (city only): {self.location}")
        if self.photo_count:
            lines.append(f"Profile photos: {self.photo_count}")
        for p in self.pages:
            title = (p.get("title") or "Note").strip()
            body = " ".join(str(p.get("body") or "").split())
            if body:
                lines.append(f"\n[{title}]\n{body}")
        if self.style_exemplars:
            lines.append(
                "\n[How this user texts — STYLE ONLY, do NOT repeat the wording"
                " or facts]\nReal one-liners this user recently sent in their own"
                " chats, given purely as examples of their voice and tone —"
                " message length, punctuation, capitalisation, emoji and slang"
                " habits. Mirror that STYLE when you write; never reuse these"
                " exact words, and never treat them as facts to bring up:"
            )
            for ex in self.style_exemplars:
                lines.append(f"- {ex}")
        return "\n".join(lines).strip()


def ai_avatar_enabled(db, uid: str) -> bool:
    """Whether ``uid`` allows an AI version of themselves (Settings > "AI
    Avatar"). Defaults to True when unset; only an explicit ``False`` opts out."""
    prof = (
        db.collection("users")
        .document(uid)
        .collection("profile")
        .document("main")
        .get()
        .to_dict()
    ) or {}
    return prof.get(schema.PF_AI_AVATAR) is not False


def build_persona_context(
    db, viewer_uid: str, target_uid: str
) -> PersonaContext | None:
    """Assemble the persona context for ``target_uid`` as seen by ``viewer_uid``.

    This is the privacy boundary. It calls ONLY :func:`public_profile.build`
    (which blocks cross-user reads it isn't allowed to make, filters wiki to
    ``visibility == "public"`` at query level, and strips private/ai-only
    spans) and then copies out only the persona-appropriate fields. It reads
    nothing from any ``NEVER_LOAD`` category. Returns ``None`` when there is no
    real, set-up, reachable profile to simulate (missing, deleted, or blocked) or
    when the target has opted out of an AI Avatar."""
    if not ai_avatar_enabled(db, target_uid):
        return None
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
    photos = view.get("photos") or []
    return PersonaContext(
        target_uid=target_uid,
        name=name,
        age=view.get("age"),
        gender=str(view.get("gender") or ""),
        location=str(view.get("location") or ""),
        pages=pages,
        photo_count=len(photos),
        photo_url=(str(photos[0]) if photos else None),
    )


def _created_at_key(value) -> float:
    """A sortable recency key for a message ``created_at``. Handles Firestore
    datetimes (``.timestamp()``) and numeric values; anything else (a pending
    server-timestamp sentinel, ``None``, a bad type) sorts oldest."""
    try:
        if hasattr(value, "timestamp"):
            return float(value.timestamp())
        if isinstance(value, (int, float)):
            return float(value)
    except Exception:  # noqa: BLE001 - a bad timestamp just sorts oldest
        pass
    return 0.0


def _stream_thread_messages(thread_ref):
    """Recent messages in one DM thread, newest first when the backend supports
    ``order_by`` (real Firestore); falls back to an unordered capped read (the
    test fake) — the caller re-sorts globally by ``created_at`` either way."""
    coll = thread_ref.collection(dm_schema.DM_MESSAGES_COLLECTION)
    try:
        from firebase_admin import firestore  # lean-runtime safe (local import)

        return list(
            coll.order_by(
                "created_at", direction=firestore.Query.DESCENDING
            )
            .limit(_SELF_STYLE_MSGS_PER_THREAD)
            .stream()
        )
    except Exception:  # noqa: BLE001 - no order_by/index → unordered fallback
        return list(coll.limit(_SELF_STYLE_MSGS_PER_THREAD).stream())


def _gather_self_style_exemplars(db, uid: str) -> list[str]:
    """A capped sample of the user's OWN recent, short sent DM messages, as
    texting-STYLE exemplars for the user's own agent (founder directive
    2026-10-27).

    HARD PRIVACY BOUNDARY: only messages this user sent are read — a message is
    kept only when its ``sender_uid`` equals ``uid``. The other participant's
    messages are that other user's private content and are NEVER included. This
    is the user's own data only; it stays inside :func:`build_self_persona_context`
    (the user's own agent) and never reaches the MATCH persona.

    Fully defensive: a missing/unreadable thread or message collection just
    yields fewer (or zero) exemplars — it never raises. Results are the most
    recent messages first, deduped, each short (<= ``_SELF_STYLE_MAX_MSG_CHARS``),
    capped to ``_SELF_STYLE_MAX_MESSAGES`` and ``_SELF_STYLE_MAX_TOTAL_CHARS``."""
    uid = (uid or "").strip()
    if not uid:
        return []
    try:
        threads = list(
            db.collection(dm_schema.DM_THREADS_COLLECTION)
            .where("participants", "array_contains", uid)
            .limit(_SELF_STYLE_THREAD_SCAN)
            .stream()
        )
    except Exception:  # noqa: BLE001 - no threads readable → no exemplars
        logger.warning("self-style DM thread read failed for %s", uid, exc_info=True)
        return []

    collected: list[tuple[float, str]] = []
    for t in threads:
        try:
            msgs = _stream_thread_messages(t.reference)
        except Exception:  # noqa: BLE001 - skip an unreadable thread, keep going
            logger.warning(
                "self-style DM message read failed for %s", uid, exc_info=True
            )
            continue
        for m in msgs:
            data = m.to_dict() or {}
            # Only this user's OWN outgoing text messages — never the other
            # participant's (another user's private content).
            if data.get("sender_uid") != uid:
                continue
            if str(data.get("type") or dm_schema.MESSAGE_TEXT) != dm_schema.MESSAGE_TEXT:
                continue
            body = " ".join(str(data.get("body") or "").split())
            if not body or len(body) > _SELF_STYLE_MAX_MSG_CHARS:
                continue
            collected.append((_created_at_key(data.get("created_at")), body))

    collected.sort(key=lambda it: it[0], reverse=True)  # most recent first
    out: list[str] = []
    seen: set[str] = set()
    total = 0
    for _, body in collected:
        if len(out) >= _SELF_STYLE_MAX_MESSAGES:
            break
        key = body.lower()
        if key in seen:
            continue
        if total + len(body) > _SELF_STYLE_MAX_TOTAL_CHARS:
            continue
        seen.add(key)
        out.append(body)
        total += len(body)
    return out


def build_self_persona_context(db, uid: str) -> PersonaContext | None:
    """Assemble the persona context for the user's OWN agent — grounded in
    their FULL profile, every wiki page, AND how they actually text.

    The asymmetry is deliberate and documented (AI Date Simulation, founder
    directive 2026-10-27): a user's own agent authentically represents them, so
    it may read everything the user has about themselves — profile/main, and
    EVERY wiki page regardless of ``visibility`` (``public`` / ``private`` /
    ``ai_only``), with ``{{private}}`` spans KEPT, not stripped — plus a capped
    sample of the user's OWN recent sent DM messages as texting-STYLE exemplars
    (``_gather_self_style_exemplars``) so the agent sounds like how the user
    really texts. This is the user's own data only; it never crosses into
    another user's record — in particular the style exemplars are ONLY messages
    this user sent (never the other participant's). The MATCH's agent, by
    contrast, is built with :func:`build_persona_context` (public-profile-only,
    and NEVER any DM content) because we may not read another user's data.

    Grounded-but-filtered: the agent is given the full context so it can be
    authentic and gauge compatibility, but ``prompts/date_sim.md`` carries a
    disclosure filter that forbids it from ever *emitting* private/sensitive
    specifics in the simulated chat (see ``tests/test_date_sim.py``). Returns
    ``None`` when the user has no set-up profile (no name)."""
    uid = (uid or "").strip()
    if not uid:
        return None
    prof = (
        db.collection("users")
        .document(uid)
        .collection("profile")
        .document("main")
        .get()
        .to_dict()
    ) or {}
    name = str(prof.get("name") or "").strip()
    if not name:
        return None

    from matching import _age

    pages: list[dict] = []
    try:
        docs = list(
            db.collection("users")
            .document(uid)
            .collection("wiki_pages")
            .stream()
        )
    except Exception:  # noqa: BLE001 - a missing wiki just means fewer pages
        logger.warning("self wiki read failed for %s", uid, exc_info=True)
        docs = []
    for d in docs:
        data = d.to_dict() or {}
        if data.get("user_hidden") is True:
            continue
        # Effective body, NOT private-span-stripped: it's the user's own data,
        # and the disclosure filter (not redaction) keeps it from leaking.
        body = str(data.get("user_edits") or data.get("ai_body") or "").strip()
        if not body:
            continue
        pages.append(
            {
                "title": str(data.get("title") or data.get("page_type") or "Note"),
                "body": body,
            }
        )
    photos = [p for p in (prof.get("photos") or []) if isinstance(p, dict)]
    return PersonaContext(
        target_uid=uid,
        name=name,
        age=_age(prof.get("birthdate")),
        gender=str(prof.get("gender") or ""),
        location=str(prof.get("location") or ""),
        pages=pages,
        style_exemplars=_gather_self_style_exemplars(db, uid),
        photo_count=len(photos),
    )


def persona_context_for_coach(
    name: str, target_uid: str = "", gender: str = ""
) -> PersonaContext:
    """A name+gender-only persona context for the VOICE live coach (hackathon B).

    The voice agent worker drives the live coach as the user speaks, but it
    must never re-read the target's profile — the privacy boundary is crossed
    exactly once, server-side, when :func:`build_persona_context` composes the
    seeded persona prompt. The coach only ever needs the match's (public)
    display name and gender (both viewer-visible) plus the running transcript,
    so the worker rebuilds this minimal context from the ``persona_name`` /
    ``persona_gender`` the seed already carries rather than loading anything
    new. ``gender`` lets the coach use the right pronouns (founder bug
    2026-10-27: a she/her persona was coached as "him"). Nothing here can hold a
    ``NEVER_LOAD`` value."""
    return PersonaContext(
        target_uid=target_uid,
        name=str(name or "").strip(),
        age=None,
        gender=str(gender or "").strip(),
        location="",
        pages=[],
        photo_count=0,
    )


# --------------------------------------------------------------------------- #
# Pronouns (coach + prompts)
# --------------------------------------------------------------------------- #
_FEMALE_GENDER_WORDS = frozenset(
    {"female", "woman", "women", "f", "girl", "lady", "she", "her", "feminine"}
)
_MALE_GENDER_WORDS = frozenset(
    {"male", "man", "men", "m", "guy", "boy", "he", "him", "masculine"}
)


def pronouns_for_gender(gender: str | None) -> str:
    """The subject/object pronoun pair for a persona's ``gender``: ``"she/her"``,
    ``"he/him"``, or ``"they/them"`` when gender is non-binary, other, blank or
    unrecognised. Never defaults to "he/him" (founder bug 2026-10-27: a she/her
    persona was coached as "him")."""
    g = (gender or "").strip().lower()
    if g in _FEMALE_GENDER_WORDS:
        return "she/her"
    if g in _MALE_GENDER_WORDS:
        return "he/him"
    return "they/them"


# --------------------------------------------------------------------------- #
# Prompt composition
# --------------------------------------------------------------------------- #
def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def _format_transcript(turns: list[dict], match_name: str = "") -> str:
    """Render stored turns for the COACH and DEBRIEF, which coach the real user.

    The coachee (the real user) is labelled ``User`` and the simulated match is
    labelled by their name, so the prompts can unambiguously critique the user's
    lines — NOT the persona's. (Contrast :func:`compose_persona_prompt`, where
    the model plays the match and the mapping is the opposite "Me"/"Them".)"""
    other = (match_name or "").strip() or "Match"
    out: list[str] = []
    for t in turns:
        who = other if t.get("role") == ROLE_MATCH else "User"
        text = str(t.get("text") or "").strip()
        if text:
            out.append(f"{who}: {text}")
    return "\n".join(out)


def compose_persona_prompt(
    ctx: PersonaContext,
    turns: list[dict] | None = None,
    *,
    voice: bool = False,
    user_name: str = "",
) -> str:
    """The persona system prompt: the roleplay template with the whitelisted
    persona block injected, plus the conversation-so-far from the match's point
    of view. Used by text practice and seeded into a practice voice room.

    ``voice=True`` appends the live-voice-call framing (``practice_persona_voice``):
    the persona is answering a phone call from the user — speaking, not texting —
    and already knows who is calling because they matched, so it must never ask
    the user's name or greet them as a stranger. ``user_name`` (the caller's
    first name) is injected into that block so the match knows who they picked up
    the phone to. The text path passes neither and is unchanged."""
    base = _read(_PERSONA_PROMPT_PATH).replace(_PERSONA_TOKEN, ctx.to_prompt_block())
    if voice:
        caller = (user_name or "").strip() or "the person you matched with"
        base += "\n\n" + _read(_PERSONA_VOICE_PROMPT_PATH).replace(
            _USER_NAME_TOKEN, caller
        )
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
        convo = _format_transcript(turns, ctx.name)
        pronouns = pronouns_for_gender(ctx.gender)
        result = await practice_llm.generate_structured(
            compose_coach_prompt(),
            f"The match is {ctx.name} ({pronouns}). Refer to the match with "
            f"{pronouns} pronouns. Conversation so far:\n{convo}",
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
    convo = _format_transcript(turns, ctx.name)
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
