"""System-prompt composition (§13.5).

The base persona is loaded from ``persona.md`` (AGENTS.md: prompt text never
lives inside a code file). Layers wired so far, in §13.5 order: base persona
(Step 11), ``session_mode`` instructions (Step 33), wiki ``ai_body`` (Step 24),
the recent-turns window (Step 17). Still to come: ``viewing_profile_uid``
context (Step 44).
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from transcript import Turn, format_recent_turns

_DIR = Path(__file__).parent
_PERSONA_PATH = _DIR / "persona.md"

# §3.3 — marketing- and interview-scoped instructions. ``active`` / normal adds
# nothing beyond the base persona.
_MODE_PROMPTS = {
    "marketing": _DIR / "prompts" / "mode_marketing.md",
    "interview": _DIR / "prompts" / "mode_interview.md",
}


@lru_cache(maxsize=1)
def load_persona() -> str:
    return _PERSONA_PATH.read_text(encoding="utf-8").strip()


@lru_cache(maxsize=4)
def load_mode_prompt(session_mode: str) -> str:
    path = _MODE_PROMPTS.get(session_mode)
    return path.read_text(encoding="utf-8").strip() if path else ""


def compose_system_prompt(
    recent_turns: list[Turn] | None = None,
    wiki_context: str = "",
    session_mode: str = "",
    viewing_profile_context: str = "",
) -> str:
    """Assemble the final system prompt in §13.5 order: base persona, then the
    ``session_mode`` instructions (§3.3), the wiki ``ai_body`` block (§2.3), the
    recent-turns window (§1.5), and — when the user is talking about a specific
    profile — that pair's ``ai_explanation`` (§5.6)."""
    parts = [load_persona()]

    mode_prompt = load_mode_prompt(session_mode)
    if mode_prompt:
        parts.append(mode_prompt)

    if wiki_context.strip():
        parts.append(wiki_context.strip())

    rendered = format_recent_turns(recent_turns) if recent_turns else ""
    if rendered:
        parts.append(
            "Conversation so far (voice and text turns interleaved). Continue "
            "it naturally — do not repeat yourself:\n" + rendered
        )

    if viewing_profile_context.strip():
        parts.append(
            "The user is looking at a specific person's profile. Your private "
            "read on that match (never state a private fact from it outright — "
            "use it to steer toward what matters):\n"
            + viewing_profile_context.strip()
        )

    return "\n\n".join(parts)
