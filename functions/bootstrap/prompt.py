"""System-prompt composition (§13.5).

The base persona is loaded from ``persona.md`` (AGENTS.md: prompt text never
lives inside a code file). Step 11 wires only the base layer; later steps add the
``session_mode`` instructions (Step 33), the wiki ``ai_body`` (Step 24), the
recent-turns window, and ``viewing_profile_uid`` context — in the order §13.5
specifies.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

_PERSONA_PATH = Path(__file__).with_name("persona.md")


@lru_cache(maxsize=1)
def load_persona() -> str:
    return _PERSONA_PATH.read_text(encoding="utf-8").strip()


def compose_system_prompt() -> str:
    """Assemble the final system prompt. Currently just the base persona; the
    remaining §13.5 layers slot in here as their steps land."""
    return load_persona()
