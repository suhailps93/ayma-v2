"""Icebreaker chips for a DM thread (ARCHITECTURE.md §6.9).

No separate generation pipeline: the chips are derived on demand from that
pair's ``matches/{matchId}`` compatibility analysis (``ai_explanation`` plus the
requesting user's own ``user_explanation``). If no compatibility check has ever
run for the pair, there is no ``matches`` doc and no chips are shown.
"""

from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path

import gemini
from pair_key import sorted_pair_key

logger = logging.getLogger("ayma.dm")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "icebreakers.md"
_MAX_CHIPS = 4

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "icebreakers": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["icebreakers"],
}


@lru_cache(maxsize=1)
def _load_prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


async def suggest(db, uid: str, other: str) -> list[str]:
    """Return up to four opener chips for ``uid`` to send ``other``.

    Empty list when the pair has no ``matches`` doc yet, or when generation
    fails — icebreakers are a nicety and never block opening a thread.
    """
    match_id = sorted_pair_key(uid, other)
    snap = db.collection("matches").document(match_id).get()
    if not snap.exists:
        return []
    data = snap.to_dict() or {}
    ai_expl = str(data.get("ai_explanation", "")).strip()
    mine = str((data.get("user_explanation") or {}).get(uid, "")).strip()
    if not (ai_expl or mine):
        return []

    contents = (
        "COMPATIBILITY ANALYSIS (private, for grounding only — do not quote):\n"
        f"{ai_expl or '(none)'}\n\n"
        "WHAT THIS USER WAS TOLD ABOUT THE MATCH:\n"
        f"{mine or '(none)'}"
    )
    try:
        result = await gemini.generate_json(
            contents,
            system_prompt=_load_prompt(),
            response_schema=_RESPONSE_SCHEMA,
        )
    except Exception:  # noqa: BLE001
        logger.exception("icebreaker generation failed for %s", match_id)
        return []

    chips = (result or {}).get("icebreakers", []) if isinstance(result, dict) else []
    out: list[str] = []
    for c in chips:
        if isinstance(c, str) and c.strip():
            out.append(c.strip())
    return out[:_MAX_CHIPS]
