"""``propose_date_plan`` — post a date-plan card into a DM thread from a
chat/voice ask (Plan a date, location piece 1).

The chat/voice counterpart to the DM thread attach sheet's "Plan a date"
button: it runs the SAME propose path the button's endpoint runs
(``POST /dm/{thread_id}/date-plan/propose`` in ``main.py`` — resolve the
place via Google Places when no coordinates came with the ask, build the
plan with :func:`date_plan.propose_plan`, append the card with
:func:`date_plan.post_date_plan_message`), so a card posted from chat is
the identical ``type: date_plan`` message the thread renders for a
button-posted one, and both people approve it in the thread the same way.

Until now the brain had NO date-plan tool at all: Ayma could talk about a
plan in chat but never post the card, so a chat ask silently produced
nothing (founder feedback zVnQBIG0HGvSpx8Egwei, 2026-11-14). This tool is
the missing trigger, mirroring how ``rerun_match_report`` gave the match
report screen's "Recalculate" button a conversational trigger.

OWN-THREAD ONLY: the person is resolved among the DM threads this
authenticated user already has (``app_control_mirror._dm_threads`` — the
same scoping ``open_message_thread`` uses), and the card is posted only
into that pair's thread, with this caller always one of the two
participants. There is no way to post into a thread the caller isn't in;
with no existing thread there is nowhere honest to put the card, so it
says so instead of claiming one. A place that can't be located, or a
start time that has already passed (``date_plan.propose_plan`` raises
for it), likewise returns the plain reason and posts nothing.

The blocking Firestore/Places work runs in a thread
(``asyncio.to_thread``), like the endpoint's own ``_post`` —
``gemini.generate_reply`` awaits this in the text tool loop, and livekit
``function_tool`` awaits it in voice. This module makes NO model-provider
call: inference stays on the existing LiveKit-routed path.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Awaitable, Callable

import date_plan as date_plan_mod
import places_client
from pair_key import sorted_pair_key

from ._base import Skill
from .app_control_mirror import _best_thread, _dm_threads

logger = logging.getLogger("ayma.app_control")

DESCRIPTION = (
    "Plan a date for the user with one of their matches: post the "
    "date-plan card (a place + a time) into their existing DM "
    "conversation with that person — on an explicit ask to plan or set "
    "up a date with someone, once a place and a time are known. This is "
    "the ONLY way a date-plan card can be posted from chat; merely "
    "talking about a plan never posts one. The card goes into the user's "
    "own DM thread with the named person (never a thread they aren't "
    "in), where both people can approve it. If there is no existing "
    "conversation with that person, no card can be posted — say so "
    "plainly instead of describing a plan as if it were posted."
)

DECLARATION = {
    "name": "propose_date_plan",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "person": {
                "type": "string",
                "description": "the match's name, as the user said it",
            },
            "place_name": {
                "type": "string",
                "description": "the place for the date, as the user named it",
            },
            "time_label": {
                "type": "string",
                "description": (
                    "the time as the user said it, e.g. 'Friday at 8 PM'"
                ),
            },
            "starts_at": {
                "type": "string",
                "description": (
                    "the start time in ISO 8601 when it can be pinned "
                    "down, e.g. 2026-11-20T20:00:00-08:00"
                ),
            },
            "address": {
                "type": "string",
                "description": "the place's address, if the user gave one",
            },
        },
        "required": ["person", "place_name"],
    },
}

_WHO_WITH = (
    "Who's the date with? Ask the user which of their matches the date "
    "is with, then call propose_date_plan again once they name someone — "
    "never post a date card for a pair they didn't name."
)

_WHAT_PLACE = (
    "Where's the date? Ask the user for the place, then call "
    "propose_date_plan again once they name one — a date card needs a "
    "real place."
)

# The success line's prefix. tool_labels gates this tool's "Posted your
# date plan card" chip on it, so a failed attempt (no thread, unlocatable
# place, past time) never shows a success chip — the same contract as
# the image tools' success markers (founder report 2026-11-09).
SUCCESS_PREFIX = "done — posted the date plan card"


def _post_card(db, uid: str, other: str, place_name: str, address: str,
               time_label: str, starts_at: str) -> str:
    """The propose endpoint's write path, in-process: resolve the place
    when no coordinates came with the ask, build the plan, append the
    card to the pair's thread. Returns the new message id.

    Raises ``ValueError`` with a user-ready reason when the plan can't
    be built — a place that isn't locatable, or (once the past-time
    guard is in ``date_plan.propose_plan``) a start time that has
    already passed. Nothing is written in that case.
    """
    lat, lng, place_kind = None, None, ""
    resolved = places_client.resolve_place(place_name or address)
    if resolved:
        lat = resolved.get("lat")
        lng = resolved.get("lng")
        place_kind = str(resolved.get("place_kind") or "")
    if lat is None and lng is None and not address:
        raise ValueError(
            f"I couldn't pin down where {place_name} is — a more "
            "specific place name or an address would help.")
    plan = date_plan_mod.propose_plan(
        place_name=place_name, address=address, lat=lat, lng=lng,
        time_label=time_label, starts_at=starts_at, proposer_uid=uid,
        place_kind=place_kind)
    thread_id = sorted_pair_key(uid, other)
    return date_plan_mod.post_date_plan_message(
        db, thread_id, sorted((uid, other)), plan)


def _bind(db, uid: str) -> Callable[..., Awaitable[str]]:
    async def propose_date_plan(person: str = "", place_name: str = "",
                                time_label: str = "",
                                starts_at: str = "",
                                address: str = "") -> str:
        asked = (person or "").strip()
        if not asked:
            return _WHO_WITH
        place = (place_name or "").strip()
        if not place:
            return _WHAT_PLACE
        threads = await asyncio.to_thread(_dm_threads, db, uid)
        target, ambiguous = _best_thread(threads, asked)
        if ambiguous:
            names = ", ".join(t["name"] for t in ambiguous)
            return (
                f"There's more than one conversation that could be "
                f"'{asked}': {names}. Ask the user which one they mean "
                "— don't guess, and don't post a card yet."
            )
        if target is None:
            return (
                f"couldn't post a date card: there's no existing "
                f"conversation with '{asked}' to post it in — the card "
                "lives in the user's DM thread with that person. Tell "
                "them plainly, and suggest they message the person "
                "first (or open that conversation and use Plan a date "
                "there). Never claim a card was posted."
            )
        other = target["other"]
        full = target["name"]
        try:
            await asyncio.to_thread(
                _post_card, db, uid, other, place,
                (address or "").strip(), (time_label or "").strip(),
                (starts_at or "").strip())
        except ValueError as exc:
            # The write path's reasons are user-ready (a place that
            # isn't locatable; a start time that has already passed) —
            # relay the reason plainly; no card was posted.
            return f"couldn't post the date card: {exc}"
        except Exception:  # noqa: BLE001
            logger.exception(
                "date plan: posting the card failed for %s", uid)
            return (
                "couldn't post the date card just now — tell the user "
                "it didn't work and they can try again. Never claim a "
                "card was posted."
            )
        when = (time_label or "").strip()
        return (
            f"{SUCCESS_PREFIX} in your conversation with {full}: "
            f"{place}" + (f" — {when}" if when else "")
            + ". Tell the user it's there, and that both of them can "
            "approve it in the thread."
        )

    return propose_date_plan


SKILL = Skill(declaration=DECLARATION, bind=_bind)
