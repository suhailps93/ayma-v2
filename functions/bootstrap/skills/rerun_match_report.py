"""``rerun_match_report`` — re-run / refresh the user's OWN match
(compatibility) report with one person (§5.3 match report).

The chat/voice counterpart to the match report screen's "Recalculate" button
and ``POST /check-compatibility`` with ``force`` — it kicks off the SAME
background recalculation (``main._match_job``, the exact task the force path in
``check_compatibility`` queues) and returns at once, then opens the report so
the user watches it refresh. The refreshed ``[match:<id>]`` card lands in chat
when the score finishes (``_match_job`` owns that tail), so the user gets the
result whether or not they're still on the screen.

This is what "re-run / refresh / regenerate / recalculate / redo / update my
match report (with X)" resolves to (``app_registry``
``report_actions.rerun_match_report`` points here). It is SELF-ONLY: it always
recalculates the AUTHENTICATED user's OWN report with the named person (the
caller is bound on ``(db, uid)``, and ``_match_job`` is always called with that
``uid`` as one party) — never a third party's report, never a pair the caller
isn't in. A rerun refreshes an EXISTING report; if the pair was never scored
there is nothing to re-run, so it points at their profile (where a first match
is run) instead of silently scoring from scratch.

Why its own tool, not ``open_match_report``: opening only shows the stale
report; the conversational "refresh my match report" had no trigger and did
nothing (founder feedback ``CpR0f2fjG5UBOsxDay12``). Why queued, not inline:
the real scorer is a background job (the Recalculate button queues it too), so
re-running it must return immediately and deliver out-of-band rather than block
the turn.

Async — ``gemini.generate_reply`` awaits it in the text tool loop, and livekit
``function_tool`` awaits it in voice.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Awaitable, Callable

import token_ledger
from pair_key import sorted_pair_key

from ._base import Skill
from .app_control_navigation import _navigate, _resolve_person

logger = logging.getLogger("ayma.app_control")

DESCRIPTION = (
    "Re-run / refresh the user's OWN match (compatibility) report with one "
    "person, by name as the user said it — on an explicit ask to re-run / "
    "refresh / regenerate / recalculate / redo / update their match or "
    "compatibility report with someone. Kicks off the SAME background "
    "recalculation the report screen's 'Recalculate' button does, opens the "
    "report, and drops the refreshed card into chat when it's ready; returns "
    "right away. This is the ONLY way to actually re-run a match report — "
    "open_match_report only opens the existing report without re-running it. "
    "It always refreshes the user's own report with the named person; it never "
    "re-runs anyone else's report."
)

DECLARATION = {
    "name": "rerun_match_report",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {"name": {"type": "string"}},
        "required": ["name"],
    },
}

_WHO_WITH = (
    "Which match report? Ask the user who the match report is with, then call "
    "rerun_match_report again once they name someone — never re-run a report "
    "for a pair they didn't name."
)

# Keeps the detached recalc task referenced so the event loop can't GC it
# mid-flight (same guard deep_dive_delivery.schedule_self_refresh uses).
_PENDING: set[asyncio.Task] = set()


def _schedule_recalc(uid: str, other: str) -> bool:
    """Queue the SAME force-recalculation the Recalculate button triggers —
    ``main._match_job(uid, other)`` (the exact background task
    ``check_compatibility`` adds on ``force``) — as a detached task, so the
    rerun returns at once and the refreshed ``[match:<id>]`` card is delivered
    out-of-band. ``uid`` is always the authenticated caller, so this only ever
    recalculates that caller's own pair. ``False`` if the task couldn't be
    scheduled (honest failure, never a silent success)."""
    try:
        import main  # noqa: PLC0415 - lazy: shared scorer, no cycle (see async_voice)
    except Exception:  # noqa: BLE001
        logger.exception("match rerun: scheduling the recalculation failed")
        return False
    task = asyncio.create_task(main._match_job(uid, other))
    _PENDING.add(task)
    task.add_done_callback(_PENDING.discard)
    return True


def _bind(db, uid: str) -> Callable[..., Awaitable[str]]:
    async def rerun_match_report(name: str = "") -> str:
        asked = (name or "").strip()
        if not asked:
            return _WHO_WITH
        try:
            token_ledger.check(uid)
        except token_ledger.TokenCapExceeded:
            return token_ledger.out_of_credits_message(token_ledger.CONTEXT_MATCH)
        other, full = await asyncio.to_thread(_resolve_person, db, uid, asked)
        if not other:
            return f"I couldn't find someone called {asked} in the app."
        # Self-only: the pair is always (this caller, the named person) — never
        # a report between two other people.
        key = sorted_pair_key(uid, other)
        try:
            snap = await asyncio.to_thread(
                db.collection("matches").document(key).get
            )
            scored = bool(getattr(snap, "exists", False))
        except Exception:  # noqa: BLE001
            logger.exception("match rerun: lookup failed for %s", uid)
            scored = False
        if not scored:
            # A rerun refreshes an existing report; there's nothing to re-run
            # when the pair was never scored (mirrors open_match_report).
            return (
                f"There's no match report with {full} yet — offer to open "
                "their profile, where they can run the match."
            )
        if not _schedule_recalc(uid, other):
            return (
                f"I couldn't start recalculating your match report with {full} "
                "just now — tell the user it didn't work and to try again."
            )
        # Open the refreshed report the same way open_match_report does, so the
        # user watches it update; the recalc is already queued regardless.
        nav = await _navigate(
            db, uid, "match_report", f"/match/{key}",
            f"the match report with {full}",
        )
        if nav.startswith("navigated:"):
            line = (
                f"On it — I'm recalculating your match report with {full} and "
                "I've opened it; it'll refresh here in a moment."
            )
        else:
            line = (
                f"On it — I'm recalculating your match report with {full}; "
                "it'll refresh here in a moment."
            )
        return f"{line}\n\n[match:{key}]"

    return rerun_match_report


SKILL = Skill(declaration=DECLARATION, bind=_bind)
