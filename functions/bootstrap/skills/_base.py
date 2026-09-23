"""Shared shape for a registered skill (ARCHITECTURE.md §13.6)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

_MAX_QUOTE = 600


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


def last_user_quote(turns: list | None) -> str:
    """The most recent user-authored line in ``turns`` (a ``session_ctx``
    ``turns`` window — see ``skills.make_session_tool_fns``), trimmed to a
    sane length. ``""`` when there's no user turn at all (an empty/voice-only
    window). Used by provenance-writing tools (§ fact-source-of-truth,
    2026-09-21) as the verbatim quote to attribute a chat-written fact to —
    good enough for "this is roughly what they said, roughly when", the only
    thing this needs to support (see ``skills/fact_source.py``)."""
    for turn in reversed(list(turns or [])):
        role = getattr(turn, "role", None)
        text = str(getattr(turn, "text", "") or "").strip()
        if role == "user" and text:
            return text[:_MAX_QUOTE]
    return ""
