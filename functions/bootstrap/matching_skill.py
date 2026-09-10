"""Pass-2 matching skill — structured-first compatibility scoring
(ARCHITECTURE.md §5.4, §2.6, §5.10 step 4).

Two layers:

1. **Deterministic** (:mod:`match_deterministic`) — the pair's structured
   questionnaire answers drive per-dimension subscores and a set of hard
   dealbreaker ("gate") failures. No LLM, no randomness: identical inputs give
   an identical result.
2. **LLM** (:func:`_run_llm`, temperature 0.0) — fills only the rubric
   dimensions the structured pass could not cover, plus the narrative content:
   ``user_explanation``, ``ai_explanation``, ``shared``, ``tensions`` and
   ``missing``. It is handed the structured numbers and gate failures as
   context so its prose stays consistent with them.

The overall score is the weighted mean of the seven rubric dimensions
(structured where available, LLM otherwise), capped by any gate failure and
then down-weighted for trust flags (§5.5, never excludes).

``score_confidence`` (0..1) reports how much to trust the number: high when
both profiles are well filled in and the dealbreaker gates had their data,
low otherwise. In-process only.
"""

from __future__ import annotations

import json
import logging
from functools import lru_cache
from pathlib import Path

import gemini
import match_deterministic
from wiki_query import read_wiki_context

logger = logging.getLogger("ayma.matching")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "matching_skill.md"

# Each trust flag shaves this fraction off the raw score (capped).
_TRUST_PENALTY = 0.08
_MAX_TRUST_PENALTY = 0.4

# The rubric — key, label, weight — owned by :mod:`match_deterministic` so the
# structured and narrative layers can never drift apart.
_DIMENSIONS: list[tuple[str, str, float]] = match_deterministic.RUBRIC
_DIM_META = {k: (label, w) for k, label, w in _DIMENSIONS}
_DIM_KEYS = [k for k, _, _ in _DIMENSIONS]

_METHOD_NOTE = (
    "This score blends measured questionnaire compatibility with an AI read of "
    "both written profiles. {n} of 7 dimensions were computed deterministically "
    'from structured answers (shown as "measured"); the rest are AI estimates '
    'from the profiles ("estimated"). Any hard dealbreaker caps the overall '
    "score."
)


def _response_schema(dim_keys: list[str]) -> dict:
    return {
        "type": "object",
        "properties": {
            "dimensions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "key": {
                            "type": "string",
                            "enum": dim_keys or _DIM_KEYS,
                        },
                        "score": {"type": "number"},
                        "rationale": {"type": "string"},
                        "evidence": {
                            "type": "array",
                            "items": {"type": "string"},
                        },
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
                "properties": {
                    "A": {"type": "string"},
                    "B": {"type": "string"},
                },
                "required": ["A", "B"],
            },
            "ai_explanation": {"type": "string"},
            "shared": {"type": "array", "items": {"type": "string"}},
            "tensions": {"type": "array", "items": {"type": "string"}},
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


# --- firestore reads -------------------------------------------------------


def _trust_flags(db, uid: str) -> list:
    snap = db.collection("users").document(uid).get()
    flags = (snap.to_dict() or {}).get("trust_flags") or []
    return flags if isinstance(flags, list) else []


def _load_user(db, uid: str) -> tuple[dict, dict]:
    """``(profile_main, questionnaire_store)`` for ``uid``. Best-effort — a
    read failure yields an empty dict so scoring can still run on the wikis."""
    base = db.collection("users").document(uid)
    profile: dict = {}
    try:
        snap = base.collection("profile").document("main").get()
        if snap is not None:
            profile = snap.to_dict() or {}
    except Exception:  # noqa: BLE001
        logger.exception("matching: profile read failed for %s", uid)
    qstore: dict = {}
    try:
        for s in base.collection("questionnaire").stream():
            qstore[s.id] = s.to_dict() or {}
    except Exception:  # noqa: BLE001
        logger.exception("matching: questionnaire read failed for %s", uid)
    return profile, qstore


def _intent_of(profile: dict, qstore: dict) -> str | None:
    return (qstore.get("relationship_intent") or {}).get("value") or profile.get(
        "relationship_intent"
    )


def _completeness_score(profile: dict) -> float:
    try:
        return float((profile.get("completeness") or {}).get("score") or 0.0)
    except (TypeError, ValueError):
        return 0.0


def _first_name(profile: dict) -> str:
    name = str(profile.get("name") or "").strip()
    return name.split()[0] if name else ""


# --- scoring maths -------------------------------------------------------


def _apply_trust_penalty(score: float, flags_a: list, flags_b: list) -> float:
    penalty = min(
        _MAX_TRUST_PENALTY, (len(flags_a) + len(flags_b)) * _TRUST_PENALTY
    )
    return max(0.0, min(1.0, score - penalty))


def _shape_llm(raw, wanted: set[str]) -> dict[str, dict]:
    by_key: dict[str, dict] = {}
    if isinstance(raw, list):
        for d in raw:
            if isinstance(d, dict) and d.get("key") in wanted:
                by_key[d["key"]] = d
    return by_key


def _structured_rationale(label: str, n_nodes: int, score: float) -> str:
    unit = "answer" if n_nodes == 1 else "answers"
    return (
        f"Measured from {n_nodes} matching questionnaire {unit}: "
        f"{round(score)}/100 compatibility on {label.lower()}."
    )


def _merge_dimensions(
    structured_dims: dict, llm_raw, llm_keys: list[str]
) -> list[dict]:
    """One entry per rubric dimension, in display order. Structured where the
    deterministic pass covered it (``source: "structured"``), the model's
    number otherwise (``source: "llm"``; missing/malformed → neutral
    50/low)."""
    llm_by_key = _shape_llm(llm_raw, set(llm_keys))
    out: list[dict] = []
    for key, label, weight in _DIMENSIONS:
        s = structured_dims.get(key)
        if s is not None:
            covered = list(s.get("covered_nodes") or [])
            n = len(covered)
            out.append(
                {
                    "key": key,
                    "label": label,
                    "weight": weight,
                    "score": round(float(s["score"]), 1),
                    "rationale": _structured_rationale(
                        label, n, float(s["score"])
                    ),
                    "evidence": list(s.get("evidence") or [])[:4],
                    "confidence": "high" if n >= 2 else "medium",
                    "source": "structured",
                    "covered_nodes": covered,
                }
            )
            continue
        d = llm_by_key.get(key, {})
        try:
            sc = max(0.0, min(100.0, float(d.get("score", 50))))
        except (TypeError, ValueError):
            sc = 50.0
        conf = str(d.get("confidence", "low")).lower()
        if conf not in ("low", "medium", "high"):
            conf = "low"
        out.append(
            {
                "key": key,
                "label": label,
                "weight": weight,
                "score": round(sc, 1),
                "rationale": str(d.get("rationale", "")).strip(),
                "evidence": _str_list(d.get("evidence"), 4),
                "confidence": conf,
                "source": "llm",
                "covered_nodes": [],
            }
        )
    return out


def _overall_from_dimensions(dims: list[dict]) -> float:
    """Weighted mean of the dimension scores, on 0-1."""
    total_w = sum(d["weight"] for d in dims) or 1.0
    return sum(d["score"] / 100.0 * d["weight"] for d in dims) / total_w


def _confidence(
    comp_a: float,
    comp_b: float,
    coverage: dict,
    llm_keys: list[str],
    name_a: str,
    name_b: str,
) -> tuple[float, str]:
    """``(score_confidence 0..1, one-line note)``.

    ``score_confidence = 0.5·min(completeness) + 0.3·structured_coverage
    + 0.2·gate_data_completeness`` — high only when both profiles are detailed
    *and* the dealbreaker gates had the data they needed."""
    comp = min(comp_a, comp_b) / 100.0
    cov = float(coverage.get("structured_fraction") or 0.0)
    gate = float(coverage.get("gate_data_complete") or 0.0)
    conf = round(max(0.0, min(1.0, 0.5 * comp + 0.3 * cov + 0.2 * gate)), 2)

    topic = ""
    if llm_keys:
        topic = f", especially around {_DIM_META[llm_keys[0]][0].lower()}"

    if conf >= 0.66:
        note = (
            "High confidence — both profiles are detailed and the dealbreaker "
            "checks had the data they needed."
        )
    elif conf >= 0.4:
        note = f"Medium confidence — some gaps remain{topic}."
    else:
        low = name_a if comp_a <= comp_b else name_b
        note = (
            f"Lower confidence — {low or 'one of you'} hasn't filled in enough "
            f"yet{topic}."
        )
    return conf, note


# --- LLM pass -------------------------------------------------------------


async def _run_llm(
    contents: str, dim_keys: list[str], *, uid: str
) -> dict:
    result = await gemini.generate_json(
        contents,
        system_prompt=_load_prompt(),
        response_schema=_response_schema(dim_keys),
        uid=uid,
        feature="matching",
        # Deterministic scoring: the same inputs must return the same numbers
        # every time (§5.4).
        temperature=0.0,
    )
    if not isinstance(result, dict):
        raise ValueError("matching skill returned a non-object")
    return result


def _llm_contents(
    wiki_a: str,
    wiki_b: str,
    flags_a: list,
    flags_b: list,
    intent: str,
    structured: dict,
    dim_keys: list[str],
) -> str:
    covered = {
        k: {"score": v["score"], "evidence": v["evidence"]}
        for k, v in structured["dimensions"].items()
        if v is not None
    }
    return (
        f"WIKI A:\n{wiki_a}\n\nWIKI B:\n{wiki_b}\n\n"
        f"TRUST FLAGS A: {flags_a or 'none'}\n"
        f"TRUST FLAGS B: {flags_b or 'none'}\n\n"
        f"PAIR INTENT: {intent}\n\n"
        "STRUCTURED SCORING — computed deterministically from both "
        "questionnaires. Treat these dimension numbers as fixed and keep your "
        "narrative consistent with them:\n"
        f"{json.dumps(covered, ensure_ascii=False)}\n\n"
        "DEALBREAKERS ALREADY DETECTED (hard gate failures):\n"
        f"{json.dumps(structured['gate_failures'], ensure_ascii=False) or 'none'}\n\n"
        "DIMENSIONS FOR YOU TO SCORE — no structured data covered these. Score "
        "ONLY these keys (empty list if there are none):\n"
        f"{json.dumps(dim_keys)}"
    )


# --- entry point -------------------------------------------------------------


async def score_pair(
    db, uid_a: str, uid_b: str, *, charge_uid: str | None = None
) -> dict:
    """Return ``{score, raw_score, structured_score, dimensions,
    user_explanation, ai_explanation, shared, tensions, missing, trust_flags,
    score_confidence, confidence_note, gate_failures, method}``. Raises if a
    user has no wiki to judge."""
    wiki_a = read_wiki_context(db, uid_a)
    wiki_b = read_wiki_context(db, uid_b)
    if not wiki_a or not wiki_b:
        raise ValueError("both users need a wiki to score compatibility")

    profile_a, q_a = _load_user(db, uid_a)
    profile_b, q_b = _load_user(db, uid_b)
    flags_a, flags_b = _trust_flags(db, uid_a), _trust_flags(db, uid_b)

    intent = match_deterministic.pair_intent(
        _intent_of(profile_a, q_a), _intent_of(profile_b, q_b)
    )
    structured = match_deterministic.score_structured(
        profile_a, q_a, profile_b, q_b, intent
    )
    llm_keys = list(structured["coverage"]["llm_dimensions"])

    contents = _llm_contents(
        wiki_a, wiki_b, flags_a, flags_b, intent, structured, llm_keys
    )
    result = await _run_llm(contents, llm_keys, uid=charge_uid or uid_a)

    dims = _merge_dimensions(
        structured["dimensions"], result.get("dimensions"), llm_keys
    )
    raw = _overall_from_dimensions(dims)
    if structured["gate_failures"]:
        cap = match_deterministic._gate_cap(
            len(structured["gate_failures"])
        ) / 100.0
        raw = min(raw, cap)
    score = _apply_trust_penalty(raw, flags_a, flags_b)

    conf, note = _confidence(
        _completeness_score(profile_a),
        _completeness_score(profile_b),
        structured["coverage"],
        llm_keys,
        _first_name(profile_a),
        _first_name(profile_b),
    )

    ue = result.get("user_explanation") or {}
    covered_n = len(structured["coverage"]["covered_dimensions"])
    return {
        "score": score,
        "raw_score": round(raw, 4),
        "structured_score": structured["structured_overall"],
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
        "score_confidence": conf,
        "confidence_note": note,
        "gate_failures": structured["gate_failures"],
        "method": _METHOD_NOTE.format(n=covered_n),
    }
