"""Photo tools — available only when the Ayma chat is opened in a sheet from
"Chat about it" on one photo in Your Story (``photo_url`` on the chat
request).

The user talks about that one photo — "that's not me, that's my brother",
"that's from my sister's wedding" — and Ayma writes it down as that photo's
note: what it is, and whether it's really the user. Deterministic, like the
story-edit tools: the model supplies the note text, this module is the only
thing that ever writes it.

She can also remove the photo itself if asked ("remove this" / "you do it")
— ``delete_photo`` calls the same ``photo_notes.hide_photo`` soft-delete the
app's own Delete button already uses.
"""

from __future__ import annotations

from typing import Callable

import photo_notes

from ._base import Skill

_DECL = {
    "name": "update_photo_note",
    "description": (
        "Record what the photo being discussed is, and/or whether it's "
        "really the user, based on what they just told you. Use is_user "
        "only when they've actually said so (e.g. 'that's not me')."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "note": {
                "type": "string",
                "description": "a short note on what the photo shows / context",
            },
            "is_user": {
                "type": "string",
                "enum": ["yes", "no"],
                "description": "whether the photo is really the account holder",
            },
        },
    },
}

_DELETE_DECL = {
    "name": "delete_photo",
    "description": (
        "Remove THIS specific photo — the one currently in focus in this "
        "chat — from the user's profile/story. Use only when they've "
        "explicitly asked to remove/delete/take down this photo (e.g. "
        "'remove this', 'delete it', 'you do it'), not for a general "
        "question about photos. Same as tapping Delete on it in the app: "
        "it comes off their profile/story right away; it isn't a request "
        "you need to confirm again."
    ),
    "parameters": {"type": "object", "properties": {}},
}


def _bind(db, uid, *, url: str = "", source: str = "") -> Callable[..., str]:  # noqa: ARG001
    def update_photo_note(note: str = "", is_user: str = "") -> str:
        if not url:
            return "no photo in focus"
        try:
            photo_notes.set_context(
                db, uid, url,
                context=note.strip() or None,
                is_user=is_user.strip().lower() or None,
            )
        except ValueError as exc:
            return str(exc)
        if is_user.strip().lower() == "no":
            return "noted — I won't treat that photo as being of you"
        return "noted"

    return update_photo_note


def _bind_delete(db, uid, *, url: str = "", source: str = "") -> Callable[..., str]:  # noqa: ARG001
    def delete_photo() -> str:
        if not url:
            return "no photo in focus"
        photo_notes.hide_photo(db, uid, url, source=source)
        return "done — removed that photo"

    return delete_photo


SKILLS: list[Skill] = [
    Skill(declaration=_DECL, bind=_bind),
    Skill(declaration=_DELETE_DECL, bind=_bind_delete),
]
