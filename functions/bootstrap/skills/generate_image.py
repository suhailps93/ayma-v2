"""``generate_image`` — Ayma can generate a brand-new image in chat (founder
request 2026-09-26: "create a caricature of myself" → "now render the image"
got "I don't have the tools to generate actual images here").

Text-to-image on the same LOCKED Gemini image model ``edit_photo`` already
uses (``CONFIG.GEMINI_IMAGE_EDIT_MODEL`` — it generates as well as edits), and
the exact same delivery path: moderate the result like any other photo
entering the app, upload it via ``photo_edit._store_generated_photo``, and
hand ``image_path``/``image_url`` to the caller's mutable ``result`` sink
(``main._ChatCtx.photo_edit_result``) so ``main.py`` attaches it to the chat
reply and the durable transcript. The tool's own return value is only the
short text fed back to the model.

``use_my_photo="yes"`` grounds the generation in the user's most recent chat
photo (the same latest-chat-image lookup ``face_report`` uses), so "a
caricature of MYSELF" looks like them and not a generic face. That reference
photo is identity-checked with the same face-match the shared-photo verdict
uses (``deep_dive_images.classify_face_match`` against the user's own profile
embeddings): a photo that is confidently someone else is refused — we never
generate another real person's likeness. The same rule for prompt-only
requests ("draw the girl I matched with") lives in the tool description,
where the model can apply it to names/context the backend can't resolve.

Text chat only — voice has no image delivery surface (see
``skills.__init__._TEXT_ONLY_REGISTRY``).
"""

from __future__ import annotations

import logging
from typing import Callable

import gemini
import photo_moderation
import token_ledger

from ._base import Skill
from .photo_edit import _store_generated_photo

logger = logging.getLogger("ayma.generate_image")

DECLARATION = {
    "name": "generate_image",
    "description": (
        "Generate a brand-new image from a text prompt and send it in the "
        "chat (a caricature, an avatar, a scene, an outfit idea — anything "
        "they ask you to create/draw/render). Compose a complete, "
        "self-contained prompt from the conversation. Set use_my_photo='yes' "
        "whenever the image should look like the user themselves (e.g. 'a "
        "caricature of me') so their latest chat photo grounds the likeness. "
        "Never generate an image depicting another real member or any "
        "identifiable real person who isn't the user — decline and say why. "
        "The image is delivered directly in the chat as your own message — "
        "briefly say what you made, don't describe it back in text."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "prompt": {
                "type": "string",
                "description": (
                    "full self-contained description of the image to generate"
                ),
            },
            "style": {
                "type": "string",
                "description": (
                    "optional style hint, e.g. 'watercolor', 'pixar-style 3D', "
                    "'pencil sketch'"
                ),
            },
            "use_my_photo": {
                "type": "string",
                "enum": ["yes", "no"],
                "description": (
                    "'yes' to use the user's latest chat photo as the "
                    "likeness reference (an image OF them)"
                ),
            },
        },
        "required": ["prompt"],
    },
}

_NO_REFERENCE = (
    "I can't see a recent photo of you in this chat to base it on — share "
    "one here and I'll generate it from that."
)
_NOT_SELF = (
    "that latest photo doesn't look like you, and I only generate a real "
    "person's likeness for the account holder themselves — share a photo of "
    "you and I'll use that instead."
)


def _self_reference_image(db, uid: str) -> tuple[tuple[bytes, str] | None, str]:
    """The user's most recent chat photo as ``(bytes, mime)``, identity-checked
    — ``(image, "")`` when usable, ``(None, <text for the model>)`` when not.

    Reuses ``face_report._latest_chat_image`` (the one latest-chat-image
    lookup) + ``media_embed.download_bytes``, then the same face-match
    mechanism as ``main._classify_shared_photo`` / the shared-photo verdict:
    confidently someone else → refuse (never another person's likeness);
    ``self``/``unknown`` (no reference photos to compare against, or the
    check failed) → proceed, matching ``face_report``'s permissiveness on
    the same photo."""
    import media_embed

    from .face_report import _latest_chat_image

    path = _latest_chat_image(db, uid)
    if not path:
        return None, _NO_REFERENCE
    try:
        image_bytes, mime = media_embed.download_bytes(path)
    except Exception:  # noqa: BLE001 - deleted/expired object
        return None, _NO_REFERENCE
    if _classify_reference(db, uid, image_bytes, mime) == "not_self":
        return None, _NOT_SELF
    return (image_bytes, mime), ""


def _classify_reference(db, uid: str, image_bytes: bytes, mime: str) -> str:
    """``"self"`` / ``"not_self"`` / ``"unknown"`` for the reference photo —
    the same embed + face-match ``main._classify_shared_photo`` runs on a
    freshly shared chat photo. Never raises; anything missing/failing is
    ``"unknown"``."""
    import deep_dive_images
    import media_embed

    try:
        refs = deep_dive_images.reference_embeddings_for(db, uid)
        if not refs:
            return "unknown"
        emb = media_embed.embed_image_bytes(image_bytes, mime)
        return deep_dive_images.classify_face_match(emb, refs)
    except Exception:  # noqa: BLE001
        logger.warning(
            "generate_image: reference identity check failed for %s", uid,
            exc_info=True,
        )
        return "unknown"


def _bind(
    db, uid: str, *, result: dict | None = None
) -> Callable[..., object]:
    async def generate_image(
        prompt: str = "", style: str = "", use_my_photo: str = ""
    ) -> str:
        prompt = prompt.strip()
        if not prompt:
            return "tell me what you'd like me to create"
        style = style.strip()
        full_prompt = f"{prompt}\n\nStyle: {style}" if style else prompt

        reference: tuple[bytes, str] | None = None
        if use_my_photo.strip().lower() == "yes":
            reference, refusal = _self_reference_image(db, uid)
            if refusal:
                return refusal

        try:
            new_bytes, new_mime = await gemini.generate_image(
                full_prompt, image=reference,
                uid=uid, feature=token_ledger.FEATURE_IMAGE_GEN,
            )
        except token_ledger.TokenCapExceeded:
            return token_ledger.out_of_credits_message(
                token_ledger.CONTEXT_IMAGE_GEN
            )
        except Exception as exc:  # noqa: BLE001 - model refusal/transient error
            logger.warning(
                "generate_image: image model call failed for %s", uid,
                exc_info=True,
            )
            return f"I couldn't generate that image just now ({exc})."

        try:
            mod = await photo_moderation.moderate(new_bytes, new_mime)
        except Exception:  # noqa: BLE001
            mod = {"allowed": False, "reason": "moderation_error"}
        if not mod.get("allowed"):
            return (
                "I generated something, but it didn't pass our photo safety "
                "check, so I won't send it."
            )

        try:
            path, url_out = _store_generated_photo(uid, new_bytes, new_mime)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "generate_image: storage upload failed for %s", uid,
                exc_info=True,
            )
            return f"I made the image but couldn't save it just now ({exc})."

        if result is not None:
            result["image_path"] = path
            result["image_url"] = url_out
        return "done — sent the image in the chat"

    return generate_image


SKILL = Skill(declaration=DECLARATION, bind=_bind)
