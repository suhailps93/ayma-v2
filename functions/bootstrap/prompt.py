"""System-prompt composition (§13.5).

The base persona is loaded from ``persona.md`` (AGENTS.md: prompt text never
lives inside a code file). Layers wired so far, in §13.5 order: base persona
(Step 11), wiki ``ai_body`` (Step 24), the recent-turns window (Step 17). Still
to come: ``session_mode`` instructions (Step 33) and ``viewing_profile_uid``
context (Step 44).
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from transcript import Turn, format_recent_turns

_PERSONA_PATH = Path(__file__).with_name("persona.md")


@lru_cache(maxsize=1)
def load_persona() -> str:
    return _PERSONA_PATH.read_text(encoding="utf-8").strip()


def compose_system_prompt(
    recent_turns: list[Turn] | None = None,
    wiki_context: str = "",
) -> str:
    """Assemble the final system prompt in §13.5 order: base persona, then the
    wiki ``ai_body`` block (§2.3) when present, then the recent-turns window
    (voice + text interleaved, §1.5) when present."""
    parts = [load_persona()]

    if wiki_context.strip():
        parts.append(wiki_context.strip())

    rendered = format_recent_turns(recent_turns) if recent_turns else ""
    if rendered:
        parts.append(
            "Conversation so far (voice and text turns interleaved). Continue "
            "it naturally — do not repeat yourself:\n" + rendered
        )

    return "\n\n".join(parts)
