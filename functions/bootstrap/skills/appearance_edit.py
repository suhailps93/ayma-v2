"""Appearance-report edit tools — available only when the Ayma chat is opened
in a sheet from one finding on the Appearance report (``appearance_finding_id``
on the chat request): a ``physical_attributes.fields()`` attribute, or the
literal ``"face"`` / ``"body"``.

Ayma works on the highlighted finding the user brought her, either revising it
with a second Gemini pass over the actual finding, evidence photos, and the
user's feedback (:func:`correct_appearance_item`, wired to
``appearance.correct_finding``), or — for a single attribute only, never
face/body which have no stated/computed split — clearing the user's stated
override back to whatever the photo analysis shows
(:func:`clear_appearance_item`, wired to ``appearance.clear_finding``).

Both tools bind on ``(db, uid, finding_id)`` — see ``skills/story_edit.py`` /
``skills/deep_dive_edit.py`` for the same shape applied elsewhere.
"""

from __future__ import annotations

from typing import Callable

import appearance
import token_ledger

from ._base import Skill

_CORRECT_DECL = {
    "name": "correct_appearance_item",
    "description": (
        "Revise the highlighted appearance finding — an attribute, the "
        "Face report, or the Physique report — based on what the user just "
        "told you, in their own words. Pass their feedback close to "
        "verbatim."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "feedback": {"type": "string", "description": "the user's correction, in their own words"},
        },
        "required": ["feedback"],
    },
}

_CLEAR_DECL = {
    "name": "clear_appearance_item",
    "description": (
        "Remove the user's stated override for the highlighted attribute "
        "entirely, reverting it to whatever your photo analysis shows (or "
        "unknown, if none). Only for a single attribute — not available for "
        "the Face or Physique report, which don't have a stated/computed "
        "split; use `correct_appearance_item` for those instead."
    ),
    "parameters": {"type": "object", "properties": {}},
}


def _bind_correct(db, uid, *, finding_id="") -> Callable[..., str]:
    async def correct_appearance_item(feedback: str = "") -> str:
        feedback = (feedback or "").strip()
        if not finding_id:
            return "no finding is in focus"
        if not feedback:
            return "tell me what's wrong with it"
        try:
            result = await appearance.correct_finding(db, uid, finding_id, feedback)
        except KeyError:
            return "that finding isn't on your report"
        except ValueError:
            return "tell me what's wrong with it"
        except token_ledger.TokenCapExceeded:
            return token_ledger.out_of_credits_message(token_ledger.CONTEXT_CORRECTION)
        if not result.get("ok", True):
            return result.get("reply") or "that didn't look like a valid value — try rephrasing"
        return result.get("reply") or "got it — updated"

    return correct_appearance_item


def _bind_clear(db, uid, *, finding_id="") -> Callable[..., str]:
    async def clear_appearance_item() -> str:
        if not finding_id:
            return "no finding is in focus"
        if finding_id in ("face", "body"):
            return "the Face and Physique reports can't be cleared, only corrected — tell me what's wrong"
        try:
            await appearance.clear_finding(db, uid, finding_id)
        except KeyError:
            return "that finding isn't on your report"
        return "done — cleared your stated value, it'll go back to whatever your photos show"

    return clear_appearance_item


SKILLS: list[Skill] = [
    Skill(declaration=_CORRECT_DECL, bind=_bind_correct),
    Skill(declaration=_CLEAR_DECL, bind=_bind_clear),
]
