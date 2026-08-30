"""Shared shape for a registered skill (ARCHITECTURE.md §13.6)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable


@dataclass(frozen=True)
class Skill:
    """One tool, defined once and shared by voice and text.

    ``declaration`` is the Gemini function declaration (``name``,
    ``description``, JSON-schema ``parameters``). ``bind`` returns the callable
    that actually runs it, closed over this session's ``(db, uid)`` — it takes
    only the model-supplied arguments.
    """

    declaration: dict
    bind: Callable[[object, str], Callable[..., str]]

    @property
    def name(self) -> str:
        return self.declaration["name"]
