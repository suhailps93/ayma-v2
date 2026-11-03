"""``rerun_web_research`` — re-run / refresh the user's OWN web-research
(self deep-dive) report (§ deep dive).

The chat/voice counterpart to the Web research report screen's "Search again"
button and ``POST /deep-dive`` with ``force`` — it kicks off the SAME queued
background refresh and returns immediately, so Ayma re-running the report can
never block (or hang) the turn. The refreshed report is delivered to the chat
transcript + a push when it lands (``deep_dive_delivery`` owns that tail), so
the user gets it whether or not they're still on the call.

This is what "re-run / refresh / regenerate / update my web research report"
resolves to (``app_registry`` ``report_actions.rerun_web_research`` points
here). It is SELF-ONLY: refreshing the user's own report. A fresh lookup on the
user, a date, or another member stays the ``deep_dive`` tool.

Why its own tool, not ``deep_dive``: ``deep_dive`` runs the grounded research
INLINE (awaited) and, in voice, had no server-side timeout — so asking to
"re-run the web search report" in a call called ``deep_dive`` and left a stuck
"Searching the web…" with no honest finish (founder bug 2026-11-03). Queuing
the refresh like the button makes it return at once and deliver out-of-band.

Async — ``gemini.generate_reply`` awaits it in the text tool loop, and livekit
``function_tool`` awaits it in voice.
"""

from __future__ import annotations

from typing import Awaitable, Callable

import deep_dive_delivery
import token_ledger

from ._base import Skill

DESCRIPTION = (
    "Re-run / refresh the user's OWN web-research (self deep-dive) report — on "
    "an explicit ask to re-run / refresh / regenerate / update their web "
    "research or web search report, especially with that report open. Kicks off "
    "a fresh background search of the user themselves and drops the updated "
    "report into chat when it's ready; returns right away. This is the ONLY way "
    "to actually re-run that report — it is NOT a fresh lookup on someone else "
    "(use deep_dive for that), and open_screen my_web_research only opens the "
    "existing report without re-running it."
)

DECLARATION = {
    "name": "rerun_web_research",
    "description": DESCRIPTION,
    "parameters": {"type": "object", "properties": {}},
}

_NO_NAME = (
    "I need your name on your profile before I can search the web about you — "
    "add it and I'll run it"
)


def _bind(db, uid: str) -> Callable[..., Awaitable[str]]:
    async def rerun_web_research() -> str:
        try:
            token_ledger.check(uid)
        except token_ledger.TokenCapExceeded:
            return token_ledger.out_of_credits_message(
                token_ledger.CONTEXT_DEEP_DIVE
            )
        report_id, _name = deep_dive_delivery.schedule_self_refresh(db, uid)
        if not report_id:
            return _NO_NAME
        line = (
            "On it — I'm re-running your web research now. I'll drop the updated "
            "report in chat the moment it's ready."
        )
        return f"{line}\n\n[deep_dive:{report_id}]"

    return rerun_web_research


SKILL = Skill(declaration=DECLARATION, bind=_bind)
