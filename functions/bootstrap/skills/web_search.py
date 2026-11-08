"""``web_search`` — search the live web (web-search restore, 2026-11-07).

One tool, defined once and shared by voice and text (ARCHITECTURE.md
§13.6): the capped search in :mod:`web_search` — the backend fetches
result titles / snippets / links under the founder's hard daily
free-quota cap and the model answers from them. Direct-Google
grounding stays disabled (:func:`gemini.research` still raises), and
the capped path reports its states honestly — paused at the cap,
unavailable when unconfigured — never as a fake internal error.

History: this tool used to be hand-appended to the TEXT tool set
inside ``gemini.py``'s inference loop when ``GEMINI_WEB_SEARCH`` was
on, so voice — which takes its tools from this registry — never had
it. The founder hit exactly that on 2026-11-07: mid voice call he
asked Ayma to search the web and she truthfully said she could not.
Registration here is gated by that same switch
(:func:`skills._web_search_skills`, checked per call), so flipping it
moves both surfaces together.

Async — ``gemini.generate_reply`` awaits it in the text tool loop, and
livekit ``function_tool`` awaits it in voice. The session ``db`` is
threaded into the capped search so the quota counter is charged
against the same Firestore the session already uses.
"""

from __future__ import annotations

from typing import Awaitable, Callable

import web_search as _capped

from ._base import Skill

DESCRIPTION = (
    "Search the live web. Use it for anything current or factual you "
    "are unsure about — events, news, places, prices, schedules, what "
    "is happening near the user — and include a place the user "
    "mentioned or that is already in context when the question is "
    "local. Returns search results (titles, snippets, links) for you "
    "to answer from. Search has a daily free-quota cap: if the result "
    "says it is used up for today, tell the user exactly that — never "
    "present it as a glitch or a technical problem."
)

DECLARATION = {
    "name": "web_search",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "What to look up, or the URL to read.",
            }
        },
        "required": ["query"],
    },
}


def _bind(db, uid: str) -> Callable[..., Awaitable[str]]:
    async def web_search(query: str) -> str:
        outcome = await _capped.search(query, db=db)
        return _capped.format_outcome(outcome, query)

    return web_search


SKILL = Skill(declaration=DECLARATION, bind=_bind)
