"""``recall`` — on-demand retrieval from Ayma's long-term notes (the wiki),
context_opt Phase 3 (cost program 2026-09-26).

With ``CONTEXT_OPT_LEVEL >= 3`` the standing wiki block in every prompt
shrinks to the ~2k-char core persona card, and everything else becomes
recall-on-demand: instead of re-sending ~12k chars of compiled notes with
every single message/turn, Ayma pulls a targeted slice only when the
conversation actually needs it. Registered in BOTH tool paths — text chat
(``skills.session_tool_declarations`` / ``make_session_tool_fns``) and the
Live voice session (``skills.make_livekit_tools``) — but only while the flag
is on; below level 3 this tool does not exist and the standing context is
unchanged.

Backed by :func:`wiki_query.recall_snippets` — plain keyword scoring over the
existing ``wiki_pages``, no LLM or embedding call, so a recall costs a
Firestore read instead of thousands of standing prompt tokens per turn.
"""

from __future__ import annotations

from typing import Callable

from ._base import Skill

DESCRIPTION = (
    "Search your own long-term notes on this person whenever a topic comes "
    "up you should remember more about before responding. Returns the "
    "relevant note pages."
)

DECLARATION = {
    "name": "recall",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "topic": {
                "type": "string",
                "description": "a few keywords, e.g. 'family siblings'",
            }
        },
        "required": ["topic"],
    },
}


def _bind(db, uid: str) -> Callable[..., str]:
    def recall(topic: str = "") -> str:
        from wiki_query import recall_snippets

        return recall_snippets(db, uid, topic)

    return recall


SKILL = Skill(declaration=DECLARATION, bind=_bind)
