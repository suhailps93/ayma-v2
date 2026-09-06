"""``record_feedback`` — log a moment where Ayma's own conduct in the
conversation fell short (ARCHITECTURE.md §15).

Ayma calls this as part of a normal turn when she notices friction — the user
says she's repeating herself, she realises she drifted off the questionnaire,
the user sounds impatient. It is NOT for bugs or feature requests (those go
through the Profile screen) and NOT for facts about the user (that's the wiki).
"""

from __future__ import annotations

from typing import Callable

import feedback_ops

from ._base import Skill

_CATEGORY_HINT = (
    "one of: repeated_question (asked something already asked/answered), "
    "off_script (strayed from the questionnaire / topic), rambling (talked too "
    "long or too vaguely), ignored_answer (missed what the user just said), "
    "too_many_questions, tone (too pushy / too flat), pacing, other"
)

DESCRIPTION = (
    "Log a point in THIS conversation where your own handling was off — you "
    "repeated a question, drifted from the questionnaire, over-talked, or the "
    "user signalled frustration. Call it in the same turn you notice, then "
    "carry on gracefully. Not for app bugs or feature ideas."
)

DECLARATION = {
    "name": "record_feedback",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "category": {"type": "string", "description": _CATEGORY_HINT},
            "note": {
                "type": "string",
                "description": "one sentence: what went wrong, in your words",
            },
            "quote": {
                "type": "string",
                "description": (
                    "the user's words that show it, if any; else \"\""
                ),
            },
            "severity": {
                "type": "string",
                "description": 'low | medium | high — how much it bothered them',
            },
        },
        "required": ["category", "note"],
    },
}


def _bind(db, uid: str) -> Callable[..., str]:
    def record_feedback(
        category: str,
        note: str,
        quote: str = "",
        severity: str = "low",
    ) -> str:
        """Log a conversational-conduct miss for the improvement loop."""
        fid = feedback_ops.record(
            db, uid, category, note,
            quote=quote, severity=severity, source="ayma",
        )
        return f"logged ({fid})" if fid else "not logged"

    return record_feedback


SKILL = Skill(declaration=DECLARATION, bind=_bind)
