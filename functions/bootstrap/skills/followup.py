"""``add_followup_question`` — queue a question for a later conversation
(ARCHITECTURE.md §2.4, §2.8 step 5)."""

from __future__ import annotations

from typing import Callable

import pending_questions

from ._base import Skill

_CATEGORY_HINT = (
    "the area it concerns — one of identity, career, family, relationships, "
    "dealbreakers, values, personality, interests, lifestyle, goals, sensitive, "
    "misc"
)

DESCRIPTION = (
    "Queue a question to ask this user in a LATER conversation. Use it when you "
    "notice a topic worth exploring but asking now would derail the current "
    "thread. Do not use it for something you can simply ask right now."
)

DECLARATION = {
    "name": "add_followup_question",
    "description": DESCRIPTION,
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
                    'optional wiki page id an answer would update; "" if unsure'
                ),
            },
        },
        "required": ["question_text", "category"],
    },
}


def _bind(db, uid: str) -> Callable[..., str]:
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


SKILL = Skill(declaration=DECLARATION, bind=_bind)
