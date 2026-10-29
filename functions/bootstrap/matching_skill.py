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

The overall score is the weighted mean of the rubric dimensions that actually
have real backing (structured where available, LLM otherwise) — a dimension
neither pass could ground in evidence from both people is **omitted**, not
defaulted to a neutral number, and its weight is excluded from the mean
rather than silently diluting it. The result is capped by any soft gate
failure (and zeroed by a hard dealbreaker — gender/orientation, partner age,
location), then down-weighted for trust flags (§5.5, never excludes).

``score_confidence`` (0..1) reports how much to trust the number: high when
both profiles are well filled in and the dealbreaker gates had their data,
low otherwise. In-process only.
"""

from __future__ import annotations

import json
import logging
from functools import lru_cache
from pathlib import Path

import ai_assessment
import gemini
import match_deterministic
from llm_provider import get_user_brain_provider
import matching_schema
import question_tree
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
    "both written profiles. {n} of {shown} dimensions shown were computed "
    'deterministically from structured answers (shown as "measured"); the '
    'rest are AI estimates from the profiles ("estimated").{omitted} Any hard '
    "dealbreaker caps the overall score."
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
) -> tuple[list[dict], list[str]]:
    """``(dims, omitted_keys)``. ``dims`` has one entry per rubric dimension
    that has real backing — structured where the deterministic pass covered
    it (``source: "structured"``), the model's own scored entry otherwise
    (``source: "llm"``). A dimension the model was asked to score but did not
    return is **left out of ``dims`` entirely** (and listed in
    ``omitted_keys``) rather than defaulted to a neutral score — the prompt
    instructs the model to omit a key exactly when neither wiki gives it real
    evidence for both people, and a fabricated 50/low would misrepresent that
    as a measured judgment."""
    llm_by_key = _shape_llm(llm_raw, set(llm_keys))
    out: list[dict] = []
    omitted: list[str] = []
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
        d = llm_by_key.get(key)
        if d is None:
            # The model had no solid evidence for this one — respect that
            # and leave it out rather than inventing a number.
            omitted.append(key)
            continue
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
    return out, omitted


def _overall_from_dimensions(dims: list[dict]) -> float:
    """Weighted mean of the dimension scores actually present, on 0-1. A
    dimension omitted for lack of evidence (see :func:`_merge_dimensions`)
    is simply not in ``dims`` — the remaining dimensions' weights are
    renormalised over their own total rather than the omitted one silently
    contributing a fabricated number."""
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
    # Unified Brain (§13.10): the user's chosen brain drives matching (JSON
    # scoring); Muse Spark supports json, so it is honoured, else Gemini.
    result = await get_user_brain_provider(uid, "matching", needs="json").generate_json(
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


def _assessment_block(who: str, digest: str) -> str:
    return (
        f"AYMA'S PRIVATE ASSESSMENT OF {who} — behavioural judgments (red/green "
        f"flags with evidence) Ayma formed from {who}'s own conversations and "
        "DMs. Additive context: weigh it in the dimensions you score, in "
        "`ai_explanation`, and in `tensions`; never quote or reveal it to "
        "either person:\n"
        f"{digest.strip() or 'none yet'}"
    )


# Open-ended questionnaire answers the matcher reads verbatim. They are the
# person's own words on dimensions the structured pass cannot score (what they
# do for work, their hard no's, their money plan), so the narrative can check
# one person's stated dealbreakers against the other's profile. Sensitive
# narratives (physical preferences) are deliberately left out.
_STATED_TEXT_NODE_IDS = (
    "dealbreakers_narrative",
    "career_role_narrative",
    "career_trajectory_narrative",
    "financial_strategy_narrative",
    "pet_peeves_narrative",
    "argument_repair_narrative",
    "hobbies_recharge_narrative",
)
_STATED_TEXT_MAX_CHARS = 500


def _stated_answers_block(who: str, qstore: dict) -> str:
    lines = []
    for nid in _STATED_TEXT_NODE_IDS:
        value = str((qstore.get(nid) or {}).get("value") or "").strip()
        if not value or value.lower().startswith("chose not to share"):
            continue
        label = (question_tree.node(nid) or {}).get("label", nid)
        lines.append(f"- {label}: {value[:_STATED_TEXT_MAX_CHARS]}")
    return (
        f"STATED ANSWERS FROM {who} — their own words in the questionnaire. "
        f"Check {who}'s dealbreakers against the other person's profile; a "
        "dealbreaker the other person clearly trips belongs in `tensions`:\n"
        + ("\n".join(lines) or "none yet")
    )


def _llm_contents(
    wiki_a: str,
    wiki_b: str,
    flags_a: list,
    flags_b: list,
    intent: str,
    structured: dict,
    dim_keys: list[str],
    assess_a: str = "",
    assess_b: str = "",
    q_a: dict | None = None,
    q_b: dict | None = None,
) -> str:
    covered = {
        k: {"score": v["score"], "evidence": v["evidence"]}
        for k, v in structured["dimensions"].items()
        if v is not None
    }
    return (
        f"WIKI A:\n{wiki_a}\n\nWIKI B:\n{wiki_b}\n\n"
        f"{_assessment_block('A', assess_a)}\n\n"
        f"{_assessment_block('B', assess_b)}\n\n"
        f"{_stated_answers_block('A', q_a or {})}\n\n"
        f"{_stated_answers_block('B', q_b or {})}\n\n"
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
    # The `assessment` page (ai_assessment.py) is Ayma's judgment layer — it
    # is handed to the model separately below as an explicitly labeled block
    # (via its compact digest), so it is kept OUT of the generic wiki dump
    # rather than riding along unlabeled inside "WIKI A".
    _wiki_excludes = frozenset({ai_assessment.PAGE_TYPE})
    wiki_a = read_wiki_context(db, uid_a, exclude_page_types=_wiki_excludes)
    wiki_b = read_wiki_context(db, uid_b, exclude_page_types=_wiki_excludes)
    if not wiki_a or not wiki_b:
        raise ValueError("both users need a wiki to score compatibility")
    assess_a = ai_assessment.digest(db, uid_a)
    assess_b = ai_assessment.digest(db, uid_b)

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
        wiki_a, wiki_b, flags_a, flags_b, intent, structured, llm_keys,
        assess_a, assess_b, q_a, q_b,
    )
    result = await _run_llm(contents, llm_keys, uid=charge_uid or uid_a)

    dims, omitted_keys = _merge_dimensions(
        structured["dimensions"], result.get("dimensions"), llm_keys
    )
    raw = _overall_from_dimensions(dims)
    if structured["gate_failures"]:
        if match_deterministic.is_hard_dealbreaker(structured["gate_failures"]):
            # A hard dealbreaker (gender/orientation, partner age, location)
            # zeroes the match — never a 10–25 floor (BUG B).
            raw = 0.0
        else:
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

    # Surface every dimension omitted for lack of evidence under "missing",
    # even if the model's own `missing` list didn't name it — the score
    # legitimately excludes it and the report shouldn't just go quiet about
    # why there are fewer than 7 dimensions.
    missing = _str_list(result.get("missing"), 6)
    missing_low = " ".join(missing).lower()
    for k in omitted_keys:
        if len(missing) >= 6:
            break
        label = _DIM_META[k][0]
        if label.lower() not in missing_low:
            missing.append(label)
            missing_low += " " + label.lower()

    omitted_note = (
        f" {len(omitted_keys)} dimension(s) were left out — not enough "
        "real evidence on both sides yet."
        if omitted_keys
        else ""
    )

    return {
        "score": score,
        "raw_score": round(raw, 4),
        "structured_score": structured["structured_overall"],
        "dimensions": dims,
        "omitted_dimensions": omitted_keys,
        "user_explanation": {
            uid_a: str(ue.get("A", "")).strip(),
            uid_b: str(ue.get("B", "")).strip(),
        },
        "ai_explanation": str(result.get("ai_explanation", "")).strip(),
        "shared": _str_list(result.get("shared"), 6),
        "tensions": _str_list(result.get("tensions"), 5),
        "missing": missing,
        "trust_flags": {uid_a: flags_a, uid_b: flags_b},
        "score_confidence": conf,
        "confidence_note": note,
        "gate_failures": structured["gate_failures"],
        "method": _METHOD_NOTE.format(
            n=covered_n, shown=len(dims), omitted=omitted_note
        ),
    }


# --- persisted match doc reader ------------------------------------------


def read_match(db, match_id: str) -> dict | None:
    """The persisted ``matches/{match_id}`` doc — the exact payload
    ``main.py``'s ``_match_job`` writes from this module's own
    :func:`score_pair` result, keyed by :func:`pair_key.sorted_pair_key`.
    ``None`` when the pair has never been scored. The ONE place that reads
    this doc's raw shape, so a second reader (``report_adapters.match_blocks``
    today) never re-derives the Firestore path — mirrors ``deep_dive
    .read_dive`` for this producer."""
    snap = db.collection(matching_schema.MATCHES_COLLECTION).document(match_id).get()
    if not snap.exists:
        return None
    return snap.to_dict() or {}
