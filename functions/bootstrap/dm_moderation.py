"""DM text moderation — Gemini safety pass (launch-readiness audit Task 1).

Scoped **only** to direct messages between matched users (``dm_ops.py`` /
the ``/dm/{thread_id}/messages`` send path). Never touches ``/chat`` or
``/chat/stream`` — Ayma keeps replying to everything, unconditionally.

Founder's explicit policy for DMs (the opposite of ``photo_moderation.py``,
which holds/rejects): **never block the send.** A flagged verdict only
annotates the stored message so the recipient/record can see it — the text
always goes through. Fails **open**: if the model call errors, the message
is sent unflagged rather than held or delayed.
"""

from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path

import gemini

logger = logging.getLogger("ayma.dm")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "dm_moderation.md"

_SCHEMA = {
    "type": "object",
    "properties": {
        "flagged": {"type": "boolean"},
        "reason": {"type": "string"},
        "categories": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["flagged", "reason", "categories"],
}

_UNFLAGGED: dict = {"flagged": False, "reason": "", "categories": []}


@lru_cache(maxsize=1)
def _prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


async def moderate(text: str) -> dict:
    """Return ``{flagged, reason, categories}`` for a DM text message.

    Never blocks or delays the send in the caller — this is advisory only.
    ``enforce_cap=False`` so a sender's credit balance can never make this
    check (and therefore the send) fail. On any model/parse failure this
    fails **open**: unflagged, so a moderation hiccup never blocks a DM.
    """
    if not text.strip():
        return dict(_UNFLAGGED)
    try:
        result = await gemini.generate_json(
            text,
            system_prompt=_prompt(),
            response_schema=_SCHEMA,
            enforce_cap=False,
        )
    except Exception:  # noqa: BLE001
        logger.exception("DM text moderation call failed — sending unflagged")
        return dict(_UNFLAGGED)

    if not isinstance(result, dict) or "flagged" not in result:
        return dict(_UNFLAGGED)
    return {
        "flagged": bool(result.get("flagged")),
        "reason": str(result.get("reason", "")).strip(),
        "categories": [
            str(c) for c in (result.get("categories") or []) if str(c).strip()
        ],
    }
