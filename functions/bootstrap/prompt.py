"""System-prompt composition (§13.5).

The base persona is loaded from ``persona.md`` (AGENTS.md: prompt text never
lives inside a code file). Layers wired so far, in §13.5 order: base persona
(Step 11), the curated feedback-correction bullets from ``lessons.md`` (§15),
``session_mode`` instructions (Step 33), wiki ``ai_body`` (Step 24) — which
includes each user's ``private`` steering page — and the recent-turns window
(Step 17). Still to come: ``viewing_profile_uid`` context (Step 44).

The *effective* lessons content is Firestore-backed (``config/ayma_persona``,
field ``lessons_md``) so the daily persona-evolution job (``persona_evolution.py``,
§15 Part B) can update it live, across every running Cloud Run instance,
without a redeploy — instances are stateless/ephemeral, so a background job
rewriting the static file on disk would never actually take effect. The
static ``prompts/lessons.md`` file stays in the repo as the documented
default/seed: it's what a brand-new deploy starts from, and what the very
first persona-evolution run reads as "current" before any real update has
ever landed. Callers that don't pass a Firestore client (``db=None`) — voice's
context-free fallback paths, most of this module's own tests — get the
static file only, exactly as before this migration.

Freshness: reading Firestore on every chat turn would be wasteful, so the
raw effective content is cached process-wide for ``_LESSONS_TTL_SECONDS``
(5 minutes — no existing Firestore-config-caching convention in this codebase
to follow, so this is a fresh, simple choice) rather than the indefinite
``@lru_cache`` this used to be. A daily update is visible to every instance
within one TTL window without needing to restart anything.
"""

from __future__ import annotations

import logging
import re
import time
from functools import lru_cache
from pathlib import Path

from transcript import Turn, format_recent_turns

logger = logging.getLogger("ayma.prompt")

_DIR = Path(__file__).parent
_PERSONA_PATH = _DIR / "persona.md"
_WELCOME_PATH = _DIR / "welcome_persona.md"
_LESSONS_PATH = _DIR / "prompts" / "lessons.md"
_QUESTIONNAIRE_PATH = _DIR / "prompts" / "questionnaire.md"
_VOICE_OPENER_PATH = _DIR / "prompts" / "voice_opener.md"

_LESSONS_CONFIG_COLLECTION = "config"
_LESSONS_CONFIG_DOC = "ayma_persona"
_LESSONS_CONFIG_FIELD = "lessons_md"
_LESSONS_TTL_SECONDS = 300

# {"raw": str, "loaded_at": float} — process-wide short-TTL cache for the
# effective (Firestore-or-file) lessons content. Not an ``@lru_cache`` because
# that never expires; see module docstring.
_lessons_cache: dict[str, object] = {"raw": None, "loaded_at": 0.0}

# §3.3 — marketing- and interview-scoped instructions. ``active`` / normal adds
# nothing beyond the base persona.
_MODE_PROMPTS = {
    "marketing": _DIR / "prompts" / "mode_marketing.md",
    "interview": _DIR / "prompts" / "mode_interview.md",
}


# --- persona variants (voice-prompt diet, cost program 2026-09-26) ----------
#
# Voice re-bills every resident system-prompt token on every turn of a call
# (the Live API has no prefix caching), while text gets Gemini's implicit
# prefix-cache discount — so the voice variant of the persona drops the few
# rules that provably CANNOT fire in a voice session (text-UI-only mechanics:
# the `[face_report:...]` sentinel copy, the "Shared photo" note protocol,
# the profile-edit-chat tool flow, web/link/map grounding that voice's tool
# set doesn't have, emoji). One source file, `persona.md`, carries both
# variants via line-level markers so the two can never drift apart:
#
#   <!-- text-only -->  ... lines only the text variant keeps ...  <!-- /text-only -->
#   <!-- voice-only --> ... lines only the voice variant keeps ... <!-- /voice-only -->
#
# Marker lines themselves are never emitted. Every behavioural rule stays
# resident in whichever variant it applies to — nothing is loaded on demand.

_VARIANTS = ("text", "voice")
_MARKER_OPEN = {"<!-- text-only -->": "text", "<!-- voice-only -->": "voice"}
_MARKER_CLOSE = {"<!-- /text-only -->": "text", "<!-- /voice-only -->": "voice"}


def _persona_variant(raw: str, variant: str) -> str:
    """Render one variant of the marked-up persona source: marker lines are
    dropped, spans for the other variant are dropped, and any blank-line
    doubling the removals leave behind is collapsed."""
    if variant not in _VARIANTS:
        raise ValueError(f"unknown persona variant: {variant!r}")
    out: list[str] = []
    in_span: str | None = None
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped in _MARKER_OPEN:
            if in_span is not None:
                raise ValueError("nested persona variant markers")
            in_span = _MARKER_OPEN[stripped]
            continue
        if stripped in _MARKER_CLOSE:
            if in_span != _MARKER_CLOSE[stripped]:
                raise ValueError("unbalanced persona variant markers")
            in_span = None
            continue
        if in_span is not None and in_span != variant:
            continue
        out.append(line)
    if in_span is not None:
        raise ValueError("unclosed persona variant marker")
    return re.sub(r"\n{3,}", "\n\n", "\n".join(out)).strip()


@lru_cache(maxsize=2)
def load_persona(variant: str = "text") -> str:
    return _persona_variant(
        _PERSONA_PATH.read_text(encoding="utf-8"), variant
    )


def load_voice_persona() -> str:
    """The leaner voice variant of the base persona — see `_persona_variant`."""
    return load_persona("voice")


@lru_cache(maxsize=1)
def compose_welcome_prompt() -> str:
    """System prompt for the pre-sign-in "welcome" voice room — the base
    persona (voice variant: a welcome room is always a voice call) plus a
    short greeting frame. No user context, no history."""
    parts = [load_persona("voice")]
    if _WELCOME_PATH.exists():
        parts.append(_WELCOME_PATH.read_text(encoding="utf-8").strip())
    return "\n\n".join(p for p in parts if p)


def _static_lessons_seed() -> str:
    """The repo's checked-in default/seed content — used whenever Firestore
    has no ``config/ayma_persona`` doc yet (fresh deploy) or is unreachable."""
    if not _LESSONS_PATH.exists():
        return ""
    return _LESSONS_PATH.read_text(encoding="utf-8")


def _bullets_only(raw: str) -> str:
    """Comment / blank lines dropped, ``"- "`` bullets kept verbatim."""
    lines = [ln.rstrip() for ln in raw.splitlines() if ln.strip().startswith("- ")]
    return "\n".join(lines)


def _effective_lessons_raw(db=None) -> str:
    """The raw effective lessons content: the Firestore ``config/ayma_persona``
    doc's ``lessons_md`` field when present and non-blank, else the static
    seed file. Cached process-wide for ``_LESSONS_TTL_SECONDS`` so a daily
    update propagates without a redeploy; ``db=None`` (no Firestore client
    given) always reads the static file and isn't cached against a later call
    that does pass one.
    """
    if db is None:
        return _static_lessons_seed()

    now = time.monotonic()
    cached = _lessons_cache["raw"]
    if cached is not None and (now - _lessons_cache["loaded_at"]) < _LESSONS_TTL_SECONDS:
        return cached  # type: ignore[return-value]

    raw = _static_lessons_seed()
    try:
        snap = (
            db.collection(_LESSONS_CONFIG_COLLECTION)
            .document(_LESSONS_CONFIG_DOC)
            .get()
        )
        if snap.exists:
            value = (snap.to_dict() or {}).get(_LESSONS_CONFIG_FIELD)
            if isinstance(value, str) and value.strip():
                raw = value
    except Exception:  # noqa: BLE001 - a config read must never break a prompt
        logger.exception("prompt: reading config/ayma_persona failed")

    _lessons_cache["raw"] = raw
    _lessons_cache["loaded_at"] = now
    return raw


def load_lessons(db=None) -> str:
    """The curated behavioural-correction bullets (§15): from Firestore
    ``config/ayma_persona`` when ``db`` is given and the doc exists, else the
    static ``prompts/lessons.md`` seed file. Comment / blank lines are
    dropped; ``""`` when there are none yet."""
    return _bullets_only(_effective_lessons_raw(db))


@lru_cache(maxsize=4)
def load_mode_prompt(session_mode: str) -> str:
    path = _MODE_PROMPTS.get(session_mode)
    return path.read_text(encoding="utf-8").strip() if path else ""


@lru_cache(maxsize=1)
def load_voice_opener() -> str:
    """Instruction for Ayma's own opening line on a call the caller hasn't
    spoken in yet (``prompts/voice_opener.md``)."""
    return _VOICE_OPENER_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def load_questionnaire_guidance() -> str:
    """Standing behavioural guidance for working the tree-based questionnaire
    into conversation (referenced from ``persona.md``). ``""`` if absent."""
    if not _QUESTIONNAIRE_PATH.exists():
        return ""
    return _QUESTIONNAIRE_PATH.read_text(encoding="utf-8").strip()


def compose_system_prompt(
    recent_turns: list[Turn] | None = None,
    wiki_context: str = "",
    session_mode: str = "",
    viewing_profile_context: str = "",
    profile_progress: str = "",
    story_context: str = "",
    shared_photo_note: str = "",
    questionnaire_note: str = "",
    current_screen_context: str = "",
    db=None,
    lessons_md_override: str | None = None,
    summary_context: str = "",
    stable_prefix: bool = False,
    variant: str = "text",
) -> str:
    """Assemble the final system prompt in §13.5 order: base persona, then the
    ``session_mode`` instructions (§3.3), the preboarding-progress note (interview
    mode only), the wiki ``ai_body`` block (§2.3), the recent-turns window
    (§1.5), and — when the user is talking about a specific profile — that pair's
    ``ai_explanation`` (§5.6).

    ``current_screen_context`` is a short one-line description of whatever
    screen the user had open when they started this chat turn (the floating
    Ayma launcher's page-context threading) — the same descriptive shape
    ``skills.app_control._describe`` already builds for voice's
    ``current_screen`` tool, so text and voice share one notion of "where the
    user is". Left blank for the profile case, which already gets a much
    richer briefing via ``viewing_profile_context``.

    ``db`` reads the live (Firestore-or-file) lessons content — pass it at
    every real request site; ``None`` (voice's context-free fallback paths,
    most tests) uses the static seed file. ``lessons_md_override`` is for the
    persona-evolution eval gate only: it renders the prompt against a
    candidate ``lessons.md`` that was never written to Firestore, so the
    "current" and "proposed" personas can be compared side by side.

    ``summary_context`` is the rolling conversation summary (context_opt,
    cost-program Phase 2) — everything older than the raw ``recent_turns``
    tail, rendered just before the transcript so the two read as one
    continuous memory. ``""`` (the default) changes nothing.

    ``stable_prefix`` (context_opt, cost-program Phase 1) reorders assembly so
    the byte-stable parts — base persona, lessons, mode, questionnaire
    guidance, then the wiki block — come FIRST and are byte-identical across
    consecutive turns of a conversation, aligning with Gemini's implicit
    prompt-prefix caching; the volatile parts (progress notes, screen context,
    summary, history tail, photo/profile briefings) all move after the wiki
    block. ``False`` (the default) keeps the exact pre-existing §13.5 order,
    byte for byte.

    ``variant`` picks the persona variant (voice-prompt diet — see
    ``_persona_variant``): ``"text"`` (the default) is byte-identical to the
    pre-split persona, so the text path's stable-prefix caching property is
    untouched; ``"voice"`` is the leaner variant every voice seed uses.
    """
    parts = [load_persona(variant)]

    lessons = (
        _bullets_only(lessons_md_override)
        if lessons_md_override is not None
        else load_lessons(db)
    )
    if lessons:
        parts.append(
            "Corrections from past user feedback — apply every one:\n" + lessons
        )

    mode_prompt = load_mode_prompt(session_mode)
    if mode_prompt:
        parts.append(mode_prompt)

    guidance = load_questionnaire_guidance()
    if guidance:
        parts.append(guidance)

    # Cache-alignment reorder (see the docstring): the wiki block joins the
    # stable prefix right here, before any per-turn volatile part.
    if stable_prefix and wiki_context.strip():
        parts.append(wiki_context.strip())

    # What preboarding has already captured — keeps interview-mode Ayma from
    # re-asking for a field the on-screen form already holds.
    if profile_progress.strip():
        parts.append(profile_progress.strip())

    # Active-mode nudge: where the questionnaire-completeness score is < 100,
    # the current score + the highest-priority nodes still to fill in.
    if questionnaire_note.strip():
        parts.append(questionnaire_note.strip())

    # The user opened this chat from the Your Story editor to work on a passage.
    if story_context.strip():
        parts.append(story_context.strip())

    # Where the user is in the app right now (floating launcher, non-profile
    # screens) — a short line, not a full briefing.
    if current_screen_context.strip():
        parts.append(
            "What the user is currently looking at in the app: "
            + current_screen_context.strip()
        )

    if not stable_prefix and wiki_context.strip():
        parts.append(wiki_context.strip())

    # The rolling summary of everything older than the raw tail below.
    if summary_context.strip():
        parts.append(
            "What you and this person covered earlier (a running summary of "
            "older conversation not shown verbatim below — treat it as your "
            "own memory):\n" + summary_context.strip()
        )

    rendered = format_recent_turns(recent_turns) if recent_turns else ""
    if rendered:
        parts.append(
            "Conversation so far (voice and text turns interleaved). Continue "
            "it naturally — do not repeat yourself:\n" + rendered
        )

    # Face check on a photo the user just shared in this chat (§ shared-photo
    # verify) — is it the account holder, someone else, or unverifiable?
    if shared_photo_note.strip():
        parts.append("Shared photo: " + shared_photo_note.strip())

    if viewing_profile_context.strip():
        parts.append(
            "The user is looking at / has shared a specific person's profile so "
            "you can talk about them. Here is what you know about that person "
            "and, if a match was run, your private read on the pair. Use their "
            "public wiki freely; never state a private fact from your match "
            "read outright — use it to steer toward what matters:\n"
            + viewing_profile_context.strip()
        )

    return "\n\n".join(parts)
