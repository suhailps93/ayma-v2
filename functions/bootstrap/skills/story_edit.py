"""Story-edit tools — available only when the Ayma chat is opened in a sheet
from the Your Story editor (``story_page_id`` on the chat request).

Ayma works on the highlighted passage the user brought her: make it private or
public, reword it, or drop it — and flip the whole section's visibility. Each
tool applies the change deterministically to that exact passage (never trusting
a model-written body) and commits a version so a revert is always possible.
"""

from __future__ import annotations

from typing import Callable

import story
import token_ledger  # noqa: F401 - kept for parity with other skills

from ._base import Skill

_PRIVACY_DECL = {
    "name": "set_passage_privacy",
    "description": (
        "Hide the highlighted passage from the user's public profile, or make "
        "it public again. Only the highlighted passage changes."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "private": {
                "type": "boolean",
                "description": "true to hide it, false to make it public",
            }
        },
        "required": ["private"],
    },
}

_EDIT_DECL = {
    "name": "edit_passage",
    "description": (
        "Replace the highlighted passage with a rewritten version. Pass the "
        "full replacement text for that passage only — not the whole section."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "new_text": {"type": "string", "description": "the replacement text"}
        },
        "required": ["new_text"],
    },
}

_DELETE_DECL = {
    "name": "delete_passage",
    "description": "Remove the highlighted passage from the section entirely.",
    "parameters": {"type": "object", "properties": {}},
}

_SECTION_DECL = {
    "name": "set_section_privacy",
    "description": (
        "Make the WHOLE section private or public — use only when the user "
        "clearly means the whole section, not the highlighted passage."
    ),
    "parameters": {
        "type": "object",
        "properties": {"private": {"type": "boolean"}},
        "required": ["private"],
    },
}


def _bind_privacy(db, uid, *, page_id="", passage="") -> Callable[..., str]:
    def set_passage_privacy(private: bool = True) -> str:
        if not page_id or not passage.strip():
            return "highlight the passage you want to change first"
        try:
            _ref, data = story._require_page(db, uid, page_id)
        except KeyError:
            return "that section is gone"
        body = story._display_body(db, uid, page_id, data)
        new_body = story.apply_span_action(
            body, passage.strip(), "private" if private else "public"
        )
        if new_body == body:
            return "couldn't find that passage in the section"
        story.save_section(db, uid, page_id, new_body)
        return "made that private" if private else "made that public"

    return set_passage_privacy


def _bind_edit(db, uid, *, page_id="", passage="") -> Callable[..., str]:
    def edit_passage(new_text: str = "") -> str:
        new_text = (new_text or "").strip()
        if not page_id or not passage.strip():
            return "highlight the passage you want to reword first"
        if not new_text:
            return "give me the replacement wording"
        try:
            _ref, data = story._require_page(db, uid, page_id)
        except KeyError:
            return "that section is gone"
        body = story._display_body(db, uid, page_id, data)
        if passage.strip() not in body:
            return "couldn't find that passage in the section"
        new_body = body.replace(passage.strip(), new_text, 1)
        story.save_section(db, uid, page_id, new_body)
        return "updated that passage"

    return edit_passage


def _bind_delete(db, uid, *, page_id="", passage="") -> Callable[..., str]:
    def delete_passage() -> str:
        if not page_id or not passage.strip():
            return "highlight the passage you want to remove first"
        try:
            _ref, data = story._require_page(db, uid, page_id)
        except KeyError:
            return "that section is gone"
        body = story._display_body(db, uid, page_id, data)
        new_body = story.apply_span_action(body, passage.strip(), "delete")
        if new_body == body:
            return "couldn't find that passage in the section"
        story.save_section(db, uid, page_id, new_body.strip())
        return "removed that passage"

    return delete_passage


def _bind_section(db, uid, *, page_id="", passage="") -> Callable[..., str]:  # noqa: ARG001
    def set_section_privacy(private: bool = True) -> str:
        if not page_id:
            return "no section in focus"
        try:
            story.set_visibility(
                db, uid, page_id, "private" if private else "public"
            )
        except KeyError:
            return "that section is gone"
        return (
            "the whole section is private now"
            if private
            else "the whole section is public now"
        )

    return set_section_privacy


SKILLS: list[Skill] = [
    Skill(declaration=_PRIVACY_DECL, bind=_bind_privacy),
    Skill(declaration=_EDIT_DECL, bind=_bind_edit),
    Skill(declaration=_DELETE_DECL, bind=_bind_delete),
    Skill(declaration=_SECTION_DECL, bind=_bind_section),
]
