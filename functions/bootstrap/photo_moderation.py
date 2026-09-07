"""Photo moderation — Gemini vision safety pass (ARCHITECTURE.md §8.4).

Runs at upload / import / DM time, before a photo is visible to anyone else.
Fails **closed**: if the model call errors, the photo is held (``allowed:
False``, ``reason: "moderation_error"``) rather than published, per §8.4.
"""

from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path

import gemini

logger = logging.getLogger("ayma.media")

_PROMPT_DIR = Path(__file__).with_name("prompts")
_PROMPT_PATH = _PROMPT_DIR / "photo_moderation.md"
# A photo shared privately in chat with Ayma isn't a profile photo — it just
# needs to not be harmful. The profile policy also blocks "screenshots of
# text", which wrongly catches a LinkedIn / CV / flyer the user wants Ayma to
# read (§8.4).
_CHAT_PROMPT_PATH = _PROMPT_DIR / "photo_moderation_chat.md"

_SCHEMA = {
    "type": "object",
    "properties": {
        "allowed": {"type": "boolean"},
        "reason": {"type": "string"},
        "categories": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["allowed", "reason", "categories"],
}


@lru_cache(maxsize=2)
def _prompt(context: str) -> str:
    path = _CHAT_PROMPT_PATH if context == "chat" else _PROMPT_PATH
    return path.read_text(encoding="utf-8").strip()


async def moderate(
    image_bytes: bytes, mime_type: str, *, context: str = "profile"
) -> dict:
    """Return ``{allowed, reason, categories}``. Held (``allowed: False``) on
    any model/parse failure.

    ``context="profile"`` (default) is the strict policy for photos other users
    will see. ``context="chat"`` is the lighter policy for an image the user
    shares privately with Ayma — only genuinely harmful content is held."""
    try:
        result = await gemini.generate_json(
            "Review this image against the safety policy above.",
            system_prompt=_prompt(context),
            response_schema=_SCHEMA,
            image=(image_bytes, mime_type),
        )
    except Exception:  # noqa: BLE001
        logger.exception("photo moderation call failed — holding photo")
        return {"allowed": False, "reason": "moderation_error", "categories": []}

    if not isinstance(result, dict) or "allowed" not in result:
        return {"allowed": False, "reason": "moderation_error", "categories": []}
    return {
        "allowed": bool(result.get("allowed")),
        "reason": str(result.get("reason", "")).strip(),
        "categories": [
            str(c) for c in (result.get("categories") or []) if str(c).strip()
        ],
    }
