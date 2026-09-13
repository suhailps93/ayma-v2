"""``set_user_steering`` — record a standing instruction this user gave about
how Ayma should talk to *them* (ARCHITECTURE.md §15).

"Don't ask me about my dog." "Keep questions short." "Stop bringing up my ex."
The rule is appended to the user's ``private`` steering page and applies to
every future conversation. Not for one-off requests you can just honour now,
and not for facts about the user (that's the wiki).
"""

from __future__ import annotations

from typing import Callable

import steering_ops

from ._base import Skill

DESCRIPTION = (
    "Save a lasting rule this user has given about how to talk to them — a "
    "topic to avoid, a style they want, something to stop doing. It sticks "
    "across all future conversations. Use it only for standing preferences, "
    "not one-time asks."
)

DECLARATION = {
    "name": "set_user_steering",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "rule": {
                "type": "string",
                "description": (
                    "the instruction as a short imperative, e.g. "
                    '"Don\'t ask about her dog" or "Keep questions to one line"'
                ),
            },
        },
        "required": ["rule"],
    },
}


def _bind(db, uid: str) -> Callable[..., str]:
    def set_user_steering(rule: str) -> str:
        """Persist a standing conversational preference for this user."""
        saved = steering_ops.add_rule(db, uid, rule)
        return f'saved: "{saved}"' if saved else "not saved"

    return set_user_steering


SKILL = Skill(declaration=DECLARATION, bind=_bind)
