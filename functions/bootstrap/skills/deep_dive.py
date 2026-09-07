"""``deep_dive`` — a consented web lookup on a named person (§ deep dive).

Either the user on themselves ("search me so I don't have to repeat it") or on
someone they're about to meet. Returns a digest for Ayma to walk through with
the user; confirmations flow into the wiki through normal ingest. Never runs
unprompted, never on a third party the user isn't meeting.

Async — ``gemini.generate_reply`` awaits it in the text tool loop, and
livekit ``function_tool`` awaits it in voice.
"""

from __future__ import annotations

from typing import Awaitable, Callable

import deep_dive as engine
import token_ledger

from ._base import Skill

DESCRIPTION = (
    "Look a person up on the open web and come back with a digest + links. "
    "Call it ONLY when the user explicitly asks you to research someone: "
    "themselves (\"search me so I don't have to repeat everything\") or a "
    "person they're going on a date with. Pass their full name. Never call it "
    "unprompted or about a third party the user isn't meeting."
)

DECLARATION = {
    "name": "deep_dive",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "full_name": {
                "type": "string",
                "description": "the person's full name to search for",
            },
            "subject": {
                "type": "string",
                "enum": ["self", "other"],
                "description": "'self' if the user is researching themselves, "
                "'other' for a person they're meeting",
            },
            "context": {
                "type": "string",
                "description": "optional disambiguating detail — city, employer, "
                "field — so the right person is found; \"\" if none",
            },
        },
        "required": ["full_name", "subject"],
    },
}


def _bind(db, uid: str) -> Callable[..., Awaitable[str]]:
    async def deep_dive(
        full_name: str, subject: str = "other", context: str = ""
    ) -> str:
        try:
            digest = await engine.run(
                full_name,
                uid=uid,
                context=context,
                is_self=(subject == "self"),
            )
        except ValueError:
            return "give me their full name and I'll look them up"
        except token_ledger.TokenCapExceeded:
            return (
                "out of credits, so I can't run a web search right now — "
                "reload on the profile screen"
            )
        return engine.render(digest)

    return deep_dive


SKILL = Skill(declaration=DECLARATION, bind=_bind)
