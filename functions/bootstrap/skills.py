"""Agent tools, built bound to a session's ``(db, uid)`` (ARCHITECTURE.md
§13.6). Step 22 has the one tool — ``add_followup_question``; Step 23 turns this
into the consolidated ``skills/`` registry shared with the LiveKit agent.

Each tool is a plain callable taking only the model-supplied arguments. The
matching declaration (name, description, JSON-schema parameters) is passed to
Gemini explicitly rather than via automatic-function-calling introspection,
which does not cope with bound closures.
"""

from __future__ import annotations

from typing import Callable

import pending_questions

_CATEGORY_HINT = (
    "the area it concerns — one of identity, career, family, relationships, "
    "dealbreakers, values, personality, interests, lifestyle, goals, sensitive, "
    "misc"
)

FOLLOWUP_DESCRIPTION = (
    "Queue a question to ask this user in a LATER conversation. Use it when you "
    "notice a topic worth exploring but asking now would derail the current "
    "thread. Do not use it for something you can simply ask right now."
)

FOLLOWUP_DECLARATION = {
    "name": "add_followup_question",
    "description": FOLLOWUP_DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "question_text": {
                "type": "string",
                "description": "the question, phrased the way Ayma would say it",
            },
            "category": {"type": "string", "description": _CATEGORY_HINT},
            "target_page": {
                "type": "string",
                "description": (
                    "optional wiki page id an answer would update; \"\" if "
                    "unsure"
                ),
            },
        },
        "required": ["question_text", "category"],
    },
}


def make_add_followup_question(db, uid: str) -> Callable[..., str]:
    """Return the ``add_followup_question`` tool bound to this session."""

    def add_followup_question(
        question_text: str,
        category: str = "misc",
        target_page: str = "",
    ) -> str:
        """Queue a question for Ayma to ask this user in a later conversation."""
        qid = pending_questions.add_followup_question(
            db, uid, question_text, category, target_page or None
        )
        return f"queued ({qid})" if qid else "not queued"

    return add_followup_question


def session_tool_declarations() -> list[dict]:
    return [FOLLOWUP_DECLARATION]


def make_session_tool_fns(db, uid: str) -> dict[str, Callable[..., str]]:
    return {"add_followup_question": make_add_followup_question(db, uid)}
