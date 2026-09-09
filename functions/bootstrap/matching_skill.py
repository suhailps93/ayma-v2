"""Pass-2 matching skill — wiki-to-wiki compatibility (ARCHITECTURE.md §5.4,
§2.6, §5.10 step 4).

Scores a pair on a fixed, research-grounded rubric of seven weighted
dimensions (values, life goals, lifestyle, personality, attachment/conflict,
communication, shared interests). The model rates each dimension 0-100 with a
rationale and the concrete evidence; the overall score is the weighted mean,
computed here (never trusted from the model), then down-weighted for trust
flags (§5.5, never excludes). In-process only.
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

# The rubric. Weights sum to 1.0. Order = display order.
_DIMENSIONS: list[tuple[str, str, float]] = [
    ("values", "Values & worldview", 0.22),
    ("life_goals", "Life goals & timeline", 0.20),
    ("attachment", "Attachment & conflict style", 0.16),
    ("personality", "Personality fit", 0.16),
    ("lifestyle", "Lifestyle & daily rhythm", 0.14),
    ("communication", "Communication & emotional needs", 0.08),
    ("interests", "Shared interests", 0.04),
]
_DIM_META = {k: (label, w) for k, label, w in _DIMENSIONS}
_DIM_KEYS = [k for k, _, _ in _DIMENSIONS]

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "dimensions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "key": {"type": "string", "enum": _DIM_KEYS},
                    "score": {"type": "number"},
                    "rationale": {"type": "string"},
                    "evidence": {"type": "array", "items": {"type": "string"}},
                    "confidence": {
                        "type": "string",
                        "enum": ["low", "medium", "high"],
                    },
                },
                "required": ["key", "score", "rationale"],
            },
        },
        "user_explanation": {
            "type": "object",
            "properties": {"A": {"type": "string"}, "B": {"type": "string"}},
            "required": ["A", "B"],
        },
        "ai_explanation": {"type": "string"},
        "shared": {"type": "array", "items": {"type": "string"}},
        "tensions": {"type": "array", "items": {"type": "string"}},
        # The concrete topics the wikis didn't cover well enough to score with
        # confidence — what the user should fill in to sharpen the number.
        "missing": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["dimensions", "user_explanation", "ai_explanation"],
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


def _shape_dimensions(raw) -> list[dict]:
    """One entry per rubric dimension, in display order, filled from the
    model's array (missing / malformed -> a neutral 50/low)."""
    by_key = {}
    if isinstance(raw, list):
        for d in raw:
            if isinstance(d, dict) and d.get("key") in _DIM_META:
                by_key[d["key"]] = d
    out = []
    for key, label, weight in _DIMENSIONS:
        d = by_key.get(key, {})
        try:
            score = max(0.0, min(100.0, float(d.get("score", 50))))
        except (TypeError, ValueError):
            score = 50.0
        conf = str(d.get("confidence", "low")).lower()
        if conf not in ("low", "medium", "high"):
            conf = "low"
        out.append(
            {
                "key": key,
                "label": label,
                "weight": weight,
                "score": round(score, 1),
                "rationale": str(d.get("rationale", "")).strip(),
                "evidence": _str_list(d.get("evidence"), 4),
                "confidence": conf,
            }
        )
    return out


def _overall_from_dimensions(dims: list[dict]) -> float:
    """Weighted mean of the dimension scores, on 0-1."""
    total_w = sum(d["weight"] for d in dims) or 1.0
    return sum(d["score"] / 100.0 * d["weight"] for d in dims) / total_w


async def score_pair(
    db, uid_a: str, uid_b: str, *, charge_uid: str | None = None
) -> dict:
    """Return ``{score, raw_score, dimensions, user_explanation, ai_explanation,
    shared, tensions, trust_flags}``. Raises if a user has no wiki to judge."""
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
        # Deterministic scoring: the same two wikis must return the same
        # numbers every time (§5.4). Variance comes only from a wiki change.
        temperature=0.0,
    )
    if not isinstance(result, dict):
        raise ValueError("matching skill returned a non-object")

    dims = _shape_dimensions(result.get("dimensions"))
    raw = _overall_from_dimensions(dims)
    ue = result.get("user_explanation") or {}
    return {
        "score": _apply_trust_penalty(raw, flags_a, flags_b),
        "raw_score": round(raw, 4),
        "dimensions": dims,
        "user_explanation": {
            uid_a: str(ue.get("A", "")).strip(),
            uid_b: str(ue.get("B", "")).strip(),
        },
        "ai_explanation": str(result.get("ai_explanation", "")).strip(),
        "shared": _str_list(result.get("shared"), 6),
        "tensions": _str_list(result.get("tensions"), 5),
        "missing": _str_list(result.get("missing"), 6),
        "trust_flags": {uid_a: flags_a, uid_b: flags_b},
    }
