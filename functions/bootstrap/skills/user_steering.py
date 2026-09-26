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
    "Save a standing rule the user gave about how to talk to them (topic to "
    "avoid, style to keep). Applies to all future conversations — not for "
    "one-time asks."
)

DECLARATION = {
    "name": "set_user_steering",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "rule": {
                "type": "string",
                "description": 'a short imperative, e.g. "Don\'t ask about her dog"',
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
