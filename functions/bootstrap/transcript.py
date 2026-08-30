"""Shared recent-turns window shape (§1.5).

The client keeps a bounded rolling window of interleaved voice + text turns and
sends it with every ``/chat`` and ``/bootstrap`` call so both entry points build
the same context (§13.5 layer 4). This module is dependency-free so both the
Main API and the agent worker (different dependency closures) can import it.
"""

from __future__ import annotations

from dataclasses import dataclass

ROLE_USER = "user"
ROLE_AYMA = "ayma"


@dataclass(frozen=True)
class Turn:
    role: str  # ROLE_USER | ROLE_AYMA
    text: str


def format_recent_turns(turns: list[Turn]) -> str:
    """Render turns as a plain ``Speaker: text`` transcript for a system prompt."""
    out = []
    for turn in turns:
        who = "User" if turn.role == ROLE_USER else "Ayma"
        text = turn.text.strip()
        if text:
            out.append(f"{who}: {text}")
    return "\n".join(out)
