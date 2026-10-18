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
import token_ledger

logger = logging.getLogger("ayma.media")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "photo_moderation.md"

_SCHEMA = {
    "type": "object",
    "properties": {
        "allowed": {"type": "boolean"},
        "reason": {"type": "string"},
        "categories": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["allowed", "reason", "categories"],
}


@lru_cache(maxsize=1)
def _prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


async def moderate(
    image_bytes: bytes, mime_type: str, *, uid: str | None = None
) -> dict:
    """Return ``{allowed, reason, categories}`` for a **profile** photo other
    users will see (§8.4). Held (``allowed: False``) on any model/parse
    failure. Photos the user shares privately with Ayma in chat are NOT run
    through here — Gemini's API safety is the only backstop there."""
    try:
        result = await gemini.generate_json(
            "Review this photo for the dating-app safety policy.",
            system_prompt=_prompt(),
            response_schema=_SCHEMA,
            image=(image_bytes, mime_type),
            uid=uid,
            feature=token_ledger.FEATURE_PHOTO_MODERATION,
            enforce_cap=False,
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
