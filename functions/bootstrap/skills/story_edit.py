"""Story-edit tools — available only when the Ayma chat is opened in a sheet
from the Your Story editor (``story_page_id`` on the chat request).

Ayma works on the highlighted passage the user brought her: make it private or
public, reword it, or remove it from their profile — and flip the whole
section's visibility. Each tool applies the change deterministically to that
exact passage (never trusting a model-written body) and commits a version so
a revert is always possible.

"Remove from profile" (``remove_from_profile``) is not a hard delete: the
passage stays in the body, wrapped in an inline ``{{ai_only}}`` span
(:func:`story.apply_span_action`'s ``"ai_only"`` action) — gone from the
public view and the normal Story view, still visible (in red) in Ayma's
Notes, and revertible from that section's history like any other edit.

When the chat is instead opened from one entry of the structured career
timeline (``story_timeline_entry_id`` on the chat request — see the Ask Ayma
overlay on a timeline row), two more tools bind scoped to that entry id:
``edit_career_timeline_entry`` / ``delete_career_timeline_entry``, which call
straight through to ``career_timeline.edit_entry`` / ``.delete_entry`` rather
than the passage-offset mechanism above, which doesn't fit structured fields.
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

_REMOVE_DECL = {
    "name": "remove_from_profile",
    "description": (
        "Take the highlighted passage off the user's profile (public view "
        "and their normal Story view) when they want it gone. It is NOT a "
        "hard delete: the passage stays in Ayma's memory and shows up, in "
        "red, under Ayma's Notes — the user can always bring it back."
    ),
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


def _bind_privacy(
    db, uid, *, page_id="", passage="", timeline_entry_id=""  # noqa: ARG001
) -> Callable[..., str]:
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
        story.save_section(
            db, uid, page_id, new_body, allow_hidden_changes=True
        )
        return "made that private" if private else "made that public"

    return set_passage_privacy


def _bind_edit(
    db, uid, *, page_id="", passage="", timeline_entry_id=""  # noqa: ARG001
) -> Callable[..., str]:
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
        story.save_section(
            db, uid, page_id, new_body, allow_hidden_changes=True
        )
        return "updated that passage"

    return edit_passage


def _bind_remove(
    db, uid, *, page_id="", passage="", timeline_entry_id=""  # noqa: ARG001
) -> Callable[..., str]:
    def remove_from_profile() -> str:
        if not page_id or not passage.strip():
            return "highlight the passage you want to remove first"
        try:
            _ref, data = story._require_page(db, uid, page_id)
        except KeyError:
            return "that section is gone"
        body = story._display_body(db, uid, page_id, data)
        new_body = story.apply_span_action(body, passage.strip(), "ai_only")
        if new_body == body:
            return "couldn't find that passage in the section"
        story.save_section(db, uid, page_id, new_body)
        return "took that off your profile — I'll still remember it in my notes"

    return remove_from_profile


def _bind_section(
    db, uid, *, page_id="", passage="", timeline_entry_id=""  # noqa: ARG001
) -> Callable[..., str]:
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


_TIMELINE_EDIT_DECL = {
    "name": "edit_career_timeline_entry",
    "description": (
        "Correct one entry in the user's structured career/education "
        "timeline — its organisation, title/degree, start date, or end "
        "date. Only pass the fields that actually changed."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "org": {"type": "string", "description": "the employer or school"},
            "title_or_degree": {"type": "string"},
            "start": {"type": "string", "description": "e.g. 2020 or 2020-09"},
            "end": {
                "type": "string",
                "description": "e.g. 2022, Present, or empty if unknown",
            },
        },
    },
}

_TIMELINE_DELETE_DECL = {
    "name": "delete_career_timeline_entry",
    "description": (
        "Remove one entry from the user's career/education timeline "
        "entirely — use when they say it shouldn't be there at all."
    ),
    "parameters": {"type": "object", "properties": {}},
}


def _bind_timeline_edit(
    db, uid, *, page_id="", passage="", timeline_entry_id=""  # noqa: ARG001
) -> Callable[..., str]:
    def edit_career_timeline_entry(
        org: str | None = None,
        title_or_degree: str | None = None,
        start: str | None = None,
        end: str | None = None,
    ) -> str:
        if not timeline_entry_id:
            return "no timeline entry is in focus"
        import career_timeline

        changes = {
            k: v
            for k, v in {
                "org": org,
                "title_or_degree": title_or_degree,
                "start": start,
                "end": end,
            }.items()
            if v is not None
        }
        if not changes:
            return "nothing to change"
        return career_timeline.edit_entry(db, uid, timeline_entry_id, changes)

    return edit_career_timeline_entry


def _bind_timeline_delete(
    db, uid, *, page_id="", passage="", timeline_entry_id=""  # noqa: ARG001
) -> Callable[..., str]:
    def delete_career_timeline_entry() -> str:
        if not timeline_entry_id:
            return "no timeline entry is in focus"
        import career_timeline

        return career_timeline.delete_entry(db, uid, timeline_entry_id)

    return delete_career_timeline_entry


SKILLS: list[Skill] = [
    Skill(declaration=_PRIVACY_DECL, bind=_bind_privacy),
    Skill(declaration=_EDIT_DECL, bind=_bind_edit),
    Skill(declaration=_REMOVE_DECL, bind=_bind_remove),
    Skill(declaration=_SECTION_DECL, bind=_bind_section),
    Skill(declaration=_TIMELINE_EDIT_DECL, bind=_bind_timeline_edit),
    Skill(declaration=_TIMELINE_DELETE_DECL, bind=_bind_timeline_delete),
]
