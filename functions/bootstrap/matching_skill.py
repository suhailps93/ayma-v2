"""Pass-2 matching skill — wiki-to-wiki compatibility (ARCHITECTURE.md §5.4,
§2.6, §5.10 step 4).

Reads both users' complete wikis and their trust flags, asks Gemini for a
single ``score`` plus per-user and private explanations, then down-weights the
score for trust flags (never excludes — §5.5). In-process only; the HTTP entry
points are Step 42.
"""

from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path

import gemini
from wiki_query import read_wiki_context

logger = logging.getLogger("ayma.matching")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "matching_skill.md"

# Each trust flag shaves this fraction off the raw score (capped).
_TRUST_PENALTY = 0.08
_MAX_TRUST_PENALTY = 0.4

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "score": {"type": "number"},
        "user_explanation": {
            "type": "object",
            "properties": {"A": {"type": "string"}, "B": {"type": "string"}},
            "required": ["A", "B"],
        },
        "ai_explanation": {"type": "string"},
        "shared": {"type": "array", "items": {"type": "string"}},
        "tensions": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["score", "user_explanation", "ai_explanation"],
}


def _str_list(v, cap: int) -> list[str]:
    if not isinstance(v, list):
        return []
    out = [str(x).strip() for x in v if str(x).strip()]
    return out[:cap]


@lru_cache(maxsize=1)
def _load_prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


def _trust_flags(db, uid: str) -> list:
    snap = db.collection("users").document(uid).get()
    flags = (snap.to_dict() or {}).get("trust_flags") or []
    return flags if isinstance(flags, list) else []


def _apply_trust_penalty(score: float, flags_a: list, flags_b: list) -> float:
    penalty = min(
        _MAX_TRUST_PENALTY, (len(flags_a) + len(flags_b)) * _TRUST_PENALTY
    )
    return max(0.0, min(1.0, score - penalty))


async def score_pair(
    db, uid_a: str, uid_b: str, *, charge_uid: str | None = None
) -> dict:
    """Return ``{score, user_explanation:{<uid_a>,<uid_b>}, ai_explanation,
    trust_flags:{<uid_a>,<uid_b>}}``. Raises if a user has no wiki to judge.

    ``charge_uid`` (defaults to ``uid_a``) is billed for the Gemini call in the
    token ledger — the user who triggered the compatibility check, or the
    subject user on the scheduled cron."""
    wiki_a = read_wiki_context(db, uid_a)
    wiki_b = read_wiki_context(db, uid_b)
    if not wiki_a or not wiki_b:
        raise ValueError("both users need a wiki to score compatibility")

    flags_a, flags_b = _trust_flags(db, uid_a), _trust_flags(db, uid_b)

    contents = (
        f"WIKI A:\n{wiki_a}\n\nWIKI B:\n{wiki_b}\n\n"
        f"TRUST FLAGS A: {flags_a or 'none'}\n"
        f"TRUST FLAGS B: {flags_b or 'none'}"
    )
    result = await gemini.generate_json(
        contents,
        system_prompt=_load_prompt(),
        response_schema=_RESPONSE_SCHEMA,
        uid=charge_uid or uid_a,
        feature="matching",
    )
    if not isinstance(result, dict):
        raise ValueError("matching skill returned a non-object")

    raw = float(result.get("score", 0.0))
    raw = max(0.0, min(1.0, raw))
    ue = result.get("user_explanation") or {}
    return {
        "score": _apply_trust_penalty(raw, flags_a, flags_b),
        "raw_score": raw,
        "user_explanation": {
            uid_a: str(ue.get("A", "")).strip(),
            uid_b: str(ue.get("B", "")).strip(),
        },
        "ai_explanation": str(result.get("ai_explanation", "")).strip(),
        # Mutually-knowable bullet points for the shareable match report.
        "shared": _str_list(result.get("shared"), 6),
        "tensions": _str_list(result.get("tensions"), 5),
        "trust_flags": {uid_a: flags_a, uid_b: flags_b},
    }
