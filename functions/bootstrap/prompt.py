"""System-prompt composition (§13.5).

The base persona is loaded from ``persona.md`` (AGENTS.md: prompt text never
lives inside a code file). Layers wired so far, in §13.5 order: base persona
(Step 11), the curated feedback-correction bullets from ``prompts/lessons.md``
(§15), ``session_mode`` instructions (Step 33), wiki ``ai_body`` (Step 24) —
which includes each user's ``private`` steering page — and the recent-turns
window (Step 17). Still to come: ``viewing_profile_uid`` context (Step 44).
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from transcript import Turn, format_recent_turns

_DIR = Path(__file__).parent
_PERSONA_PATH = _DIR / "persona.md"
_WELCOME_PATH = _DIR / "welcome_persona.md"
_LESSONS_PATH = _DIR / "prompts" / "lessons.md"
_QUESTIONNAIRE_PATH = _DIR / "prompts" / "questionnaire.md"

# §3.3 — marketing- and interview-scoped instructions. ``active`` / normal adds
# nothing beyond the base persona.
_MODE_PROMPTS = {
    "marketing": _DIR / "prompts" / "mode_marketing.md",
    "interview": _DIR / "prompts" / "mode_interview.md",
}


@lru_cache(maxsize=1)
def load_persona() -> str:
    return _PERSONA_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=1)
def compose_welcome_prompt() -> str:
    """System prompt for the pre-sign-in "welcome" voice room — the base
    persona plus a short greeting frame. No user context, no history."""
    parts = [load_persona()]
    if _WELCOME_PATH.exists():
        parts.append(_WELCOME_PATH.read_text(encoding="utf-8").strip())
    return "\n\n".join(p for p in parts if p)


@lru_cache(maxsize=1)
def load_lessons() -> str:
    """The curated behavioural-correction bullets from ``prompts/lessons.md``
    (§15). Comment / blank lines are dropped; ``""`` when there are none yet."""
    if not _LESSONS_PATH.exists():
        return ""
    lines = [
        ln.rstrip()
        for ln in _LESSONS_PATH.read_text(encoding="utf-8").splitlines()
        if ln.strip().startswith("- ")
    ]
    return "\n".join(lines)


@lru_cache(maxsize=4)
def load_mode_prompt(session_mode: str) -> str:
    path = _MODE_PROMPTS.get(session_mode)
    return path.read_text(encoding="utf-8").strip() if path else ""


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
) -> str:
    """Assemble the final system prompt in §13.5 order: base persona, then the
    ``session_mode`` instructions (§3.3), the preboarding-progress note (interview
    mode only), the wiki ``ai_body`` block (§2.3), the recent-turns window
    (§1.5), and — when the user is talking about a specific profile — that pair's
    ``ai_explanation`` (§5.6)."""
    parts = [load_persona()]

    lessons = load_lessons()
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

    if wiki_context.strip():
        parts.append(wiki_context.strip())

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
