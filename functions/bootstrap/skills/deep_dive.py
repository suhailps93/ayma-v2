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
import skill_memory
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
        is_self = subject == "self"
        if is_self:
            # Prefer the profile's real identity and fold in location + the
            # (never-searched) phone note when looking the user up.
            prof_name = engine.profile_full_name(db, uid)
            if prof_name:
                full_name = prof_name
            extra = engine.profile_dive_context(db, uid)
            if extra:
                context = f"{context} {extra}".strip()
        try:
            digest = await engine.run(
                full_name,
                db=db,
                uid=uid,
                context=context,
                is_self=is_self,
            )
        except ValueError:
            return "give me their full name and I'll look them up"
        except token_ledger.TokenCapExceeded:
            return (
                "out of credits, so I can't run a web search right now — "
                "reload on the profile screen"
            )
        # Only a self-lookup goes into the user's wiki / Your Story; research on
        # someone they're meeting stays a private chat note (+ the reuse cache).
        if is_self:
            skill_memory.save_web_findings(db, uid, digest)
        return engine.render(digest)

    return deep_dive


SKILL = Skill(declaration=DECLARATION, bind=_bind)
