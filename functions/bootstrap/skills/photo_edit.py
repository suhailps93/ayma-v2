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

``edit_photo`` (founder request 2026-09-16 — "make this into a studio
photo") sends the photo + the user's instruction to Gemini's image-edit
model (LOCKED in ``config.py``), moderates the result the same as any other
photo entering the app, uploads it to Storage, and hands the caller's
mutable ``result`` dict the ``image_path``/``image_url`` so ``main.py`` can
attach it to the chat reply and the durable transcript — the tool's own
return value is only the short text fed back to the model.
"""

from __future__ import annotations

import logging
import uuid
from typing import Callable

import failure_log
import gemini
import photo_moderation
import photo_notes
import token_ledger
from config import CONFIG

from ._base import Skill

logger = logging.getLogger("ayma.photo_edit")

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


def _bind(
    db, uid, *,
    url: str = "", source: str = "",
    image: tuple[bytes, str] | None = None,
    result: dict | None = None,
) -> Callable[..., str]:  # noqa: ARG001
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


def _bind_delete(
    db, uid, *,
    url: str = "", source: str = "",
    image: tuple[bytes, str] | None = None,
    result: dict | None = None,
) -> Callable[..., str]:  # noqa: ARG001
    def delete_photo() -> str:
        if not url:
            return "no photo in focus"
        photo_notes.hide_photo(db, uid, url, source=source)
        return "done — removed that photo"

    return delete_photo


_EDIT_DECL = {
    "name": "edit_photo",
    "description": (
        "Use Gemini's image-edit model to generate an edited version of THIS "
        "specific photo — the one currently in focus in this chat — per the "
        "user's instruction (e.g. 'make this a studio photo', 'give it a "
        "plain background', 'brighten this up'). Only call this when they've "
        "actually asked for an edited version of the photo itself, not for "
        "general photo advice. The edited photo is delivered directly in the "
        "chat as your own message — just briefly say what you did, don't "
        "describe the image back in text."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "instruction": {
                "type": "string",
                "description": (
                    "what to change about the photo, in the user's own words"
                ),
            },
        },
        "required": ["instruction"],
    },
}


def _store_generated_photo(uid: str, image_bytes: bytes, mime_type: str) -> tuple[str, str]:
    """Upload an ``edit_photo`` result to Storage and return
    ``(storage_path, download_url)``. Same upload shape as
    ``voice_preview._store`` (a fresh download token per object); the URL
    itself reuses ``public_profile._photo_url`` rather than re-deriving it."""
    from firebase_admin import storage

    from public_profile import _photo_url

    ext = "png" if "png" in (mime_type or "").lower() else "jpg"
    path = f"ayma_generated/{uid}/{uuid.uuid4().hex}.{ext}"
    blob = storage.bucket(CONFIG.storage_bucket).blob(path)
    blob.metadata = {"firebaseStorageDownloadTokens": str(uuid.uuid4())}
    blob.upload_from_string(image_bytes, content_type=mime_type or "image/png")
    return path, (_photo_url(path) or "")


def _bind_edit(
    db, uid, *,  # noqa: ARG001 - db unused, kept for the shared bind signature
    url: str = "", source: str = "",
    image: tuple[bytes, str] | None = None,
    result: dict | None = None,
) -> Callable[..., object]:
    async def edit_photo(instruction: str = "") -> str:
        # Unlike update_photo_note/delete_photo, this tool never touches
        # ``photo_notes`` — ``url`` is only ever a key into that store, which
        # a freshly attached chat photo (no existing profile/story record)
        # doesn't have. The only real requirement is having the bytes, so a
        # plain attach-and-ask ("make him a wolf" on a photo just dropped
        # into the main chat) can use this too, not only "Chat about it" on
        # an existing photo.
        if image is None:
            return (
                "I can't actually see that photo right now, so I can't edit "
                "it — try attaching it again."
            )
        instruction = instruction.strip()
        if not instruction:
            return "tell me what you'd like changed about the photo"

        img_bytes, mime = image
        try:
            new_bytes, new_mime = await gemini.edit_image(
                img_bytes, mime, instruction,
                uid=uid, feature=token_ledger.FEATURE_PHOTO_EDIT,
            )
        except token_ledger.TokenCapExceeded:
            return token_ledger.out_of_credits_message(token_ledger.CONTEXT_PHOTO_EDIT)
        except Exception as exc:  # noqa: BLE001 - model refusal/transient error
            failure_log.record_failure(
                db, uid, "edit_photo", exc, surface="text"
            )
            logger.warning(
                "edit_photo: image model call failed for %s", uid, exc_info=True
            )
            return (
                "I couldn't generate that edited photo just now "
                f"({exc}) — let me just give you some advice instead."
            )

        try:
            mod = await photo_moderation.moderate(new_bytes, new_mime, uid=uid)
        except Exception:  # noqa: BLE001
            mod = {"allowed": False, "reason": "moderation_error"}
        if not mod.get("allowed"):
            return (
                "I generated something, but it didn't pass our photo safety "
                "check, so I won't send it — let's stick with advice instead."
            )

        try:
            path, url_out = _store_generated_photo(uid, new_bytes, new_mime)
        except Exception as exc:  # noqa: BLE001
            failure_log.record_failure(
                db, uid, "edit_photo", exc, surface="text"
            )
            logger.warning(
                "edit_photo: storage upload failed for %s", uid, exc_info=True
            )
            return f"I made the edit but couldn't save it just now ({exc})."

        if result is not None:
            result["image_path"] = path
            result["image_url"] = url_out
        return "done — sent the edited photo in the chat"

    return edit_photo


SKILLS: list[Skill] = [
    Skill(declaration=_DECL, bind=_bind),
    Skill(declaration=_DELETE_DECL, bind=_bind_delete),
    Skill(declaration=_EDIT_DECL, bind=_bind_edit),
]
