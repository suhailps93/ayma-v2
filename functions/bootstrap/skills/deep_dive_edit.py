"""Deep-dive (web-search report) edit tools — available only when the Ayma
chat is opened in a sheet from one item on a deep-dive report (``deep_dive_
report_id`` + ``deep_dive_target`` on the chat request).

Ayma works on the highlighted finding the user brought her — the summary, one
claim, one social-profile link, or one "photos of you found online" thumbnail
— and can either revise it with a second Gemini pass over the actual finding
plus the user's feedback (:func:`correct_deep_dive_item`, wired to
``deep_dive.correct_finding``), or remove it outright when the user has
clearly said it's wrong or not theirs (:func:`remove_deep_dive_item`, wired to
``deep_dive.dispute_fact`` / ``dispute_social_link`` / ``dispute_web_image``).
The summary can only be revised, never removed — there's no "summary" the
report keeps without it.

Both tools bind on ``(db, uid, report_id, target)`` — see ``_STORY_REGISTRY``'s
sibling ``skills/story_edit.py`` for the same shape applied to Your Story.
"""

from __future__ import annotations

from typing import Callable

import deep_dive
import token_ledger

from ._base import Skill

_CORRECT_DECL = {
    "name": "correct_deep_dive_item",
    "description": (
        "Revise the highlighted web-search finding (a claim, the summary, a "
        "social-media link, or a photo) based on what the user just told "
        "you, in their own words. Pass their feedback close to verbatim — "
        "a second pass reads the actual finding and the evidence and "
        "decides whether to revise the wording, add a caveat, or leave it. "
        "For an unambiguous \"that's wrong\"/\"not mine\"/\"delete this\", "
        "prefer `remove_deep_dive_item` instead — it's immediate and "
        "doesn't need this second pass."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "feedback": {"type": "string", "description": "the user's correction, in their own words"},
        },
        "required": ["feedback"],
    },
}

_REMOVE_DECL = {
    "name": "remove_deep_dive_item",
    "description": (
        "Delete the highlighted finding outright — a fact, a social-media "
        "link, or a photo — when the user has clearly said it's wrong or "
        "not theirs. Not available for the whole summary (there's nothing "
        "to drop; use `correct_deep_dive_item` instead). This is a real, "
        "immediate removal — it won't resurface on a future re-search."
    ),
    "parameters": {"type": "object", "properties": {}},
}


def _bind_correct(db, uid, *, report_id="", target="") -> Callable[..., str]:
    async def correct_deep_dive_item(feedback: str = "") -> str:
        feedback = (feedback or "").strip()
        if not report_id or not target:
            return "no finding is in focus"
        if not feedback:
            return "tell me what's wrong with it"
        try:
            result = await deep_dive.correct_finding(
                db, uid, report_id, target=target, feedback=feedback
            )
        except PermissionError:
            return "corrections are only available on your own report"
        except token_ledger.TokenCapExceeded:
            return "you're out of message credits right now — try again after reloading"
        if result is None:
            return "couldn't find that on the report — it might already be gone"
        return result.get("reply") or "got it — updated"

    return correct_deep_dive_item


def _bind_remove(db, uid, *, report_id="", target="") -> Callable[..., str]:
    def remove_deep_dive_item() -> str:
        if not report_id or not target:
            return "no finding is in focus"
        if target == "summary":
            return "the summary can't be deleted outright — tell me what's wrong and I'll revise it"
        kind, _, ident = target.partition(":")
        try:
            if kind == "fact":
                result = deep_dive.dispute_fact(db, uid, report_id, ident)
            elif kind == "social":
                result = deep_dive.dispute_social_link(db, uid, report_id, ident)
            elif kind == "photo":
                result = deep_dive.dispute_web_image(db, uid, report_id, ident)
            else:
                return "not sure what to remove"
        except PermissionError:
            return "removal is only available on your own report"
        if result is None:
            return "couldn't find that on the report — it might already be gone"
        return "done — I've taken that off your report and it won't come back on a future search"

    return remove_deep_dive_item


SKILLS: list[Skill] = [
    Skill(declaration=_CORRECT_DECL, bind=_bind_correct),
    Skill(declaration=_REMOVE_DECL, bind=_bind_remove),
]
