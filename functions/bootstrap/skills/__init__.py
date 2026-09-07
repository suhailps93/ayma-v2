"""Skills / tools registry (ARCHITECTURE.md §13.6).

Every agent tool is defined once as a :class:`~skills._base.Skill` and exposed
here in the two forms the callers need — identical behaviour in both:

* ``/chat`` (text): :func:`session_tool_declarations` + :func:`make_session_tool_fns`
  feed ``gemini.generate_reply``'s manual function-calling loop.
* ``agent.py`` (voice): :func:`make_livekit_tools` wraps the same bound
  callables as livekit-agents ``function_tool``\\ s.

Adding a tool = one module under ``skills/`` and one line in ``_REGISTRY``.
``set_voice_preference`` (§13.3), the matching skill (§5.4) and Explore's NL
filter parser (§6.2) land here in their own steps.
"""

from __future__ import annotations

from typing import Callable

from . import (
    body_report,
    deep_dive,
    face_report,
    followup,
    record_feedback,
    remember,
    set_profile_field,
    set_voice_preference,
    user_steering,
)
from ._base import Skill

_REGISTRY: list[Skill] = [
    followup.SKILL,
    set_profile_field.SKILL,
    set_voice_preference.SKILL,
    record_feedback.SKILL,
    user_steering.SKILL,
    remember.SKILL,
    deep_dive.SKILL,
    face_report.SKILL,
    body_report.SKILL,
]


def all_skills() -> list[Skill]:
    return list(_REGISTRY)


def session_tool_declarations() -> list[dict]:
    """Gemini function declarations for every registered skill."""
    return [s.declaration for s in _REGISTRY]


def make_session_tool_fns(
    db, uid: str, *, session_ctx: dict | None = None
) -> dict[str, Callable[..., str]]:
    """``{name: bound callable}`` for ``gemini.generate_reply`` (text).

    ``session_ctx`` (``session_id`` / ``turn_index`` / ``turns``) is threaded
    only into ``remember`` so it can ingest the live window and rate-limit
    itself; every other skill binds on ``(db, uid)`` alone.
    """
    out: dict[str, Callable[..., str]] = {}
    for s in _REGISTRY:
        if s.name == "remember" and session_ctx:
            out[s.name] = s.bind(db, uid, **session_ctx)
        else:
            out[s.name] = s.bind(db, uid)
    return out


def make_livekit_tools(db, uid: str) -> list:
    """The same bound callables wrapped as livekit-agents tools (voice).

    ``function_tool`` is imported lazily so this package stays importable in the
    Main API venv, which has no ``livekit-agents``.
    """
    from livekit.agents import function_tool

    return [
        function_tool(
            s.bind(db, uid), name=s.name, description=s.declaration["description"]
        )
        for s in _REGISTRY
    ]
