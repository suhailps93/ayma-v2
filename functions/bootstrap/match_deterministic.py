"""Deterministic structured match scoring (ARCHITECTURE.md §5.4).

Turns the two users' structured questionnaire answers (:mod:`question_tree`,
persisted by :mod:`skills.questionnaire`) into per-dimension compatibility
subscores and a set of hard dealbreaker ("gate") failures — **with no LLM and
no randomness**. The same inputs always produce the same output; the narrative
half of a match report is layered on top by :mod:`matching_skill`.

Scoring rules by node ``kind``
-----------------------------
* ``scale``  — normalised distance ``1 - |a - b| / (max - min)`` → ``0..1``.
* ``bool``   — same ``1.0``; different ``0.2`` (a stated yes/no divergence on a
  hard-filter habit is a real friction, not a rounding error).
* ``multi``  — Jaccard overlap ``|A ∩ B| / |A ∪ B|`` of the picked options. A
  couple of nodes get a softened floor (see ``_SOFT_MULTI``) because "no shared
  tags" there is neutral, not a clash.
* ``enum``   — either an **ordinal** rule (options are a strict spectrum, e.g.
  alcohol Never…Heavy → ``1 - |i_a - i_b| / (n - 1)``) or an explicit
  **compatibility matrix** defined inline per node (``_ENUM_MATRIX``). Same
  option is always ``1.0``; an unlisted different pair falls back to the node's
  documented default.

Gate ("hard filter") failures
-----------------------------
A handful of hard-filter nodes are pass/fail *gates*, not graded dimensions:
relationship intent (casual vs. serious), procreation intent (childfree vs.
wants kids), relocation vs. location, casual exclusivity, an animal-allergy /
pet clash, and — only when both users route to the ``nikah`` tree — sect, halal
diet, riba-free finance, partner-modesty expectation, polygyny stance and
salah. Any gate failure caps the overall score low (``_gate_cap``: 25, minus 5
per additional failure, floor 10) and is surfaced as an explicit dealbreaker.
**Missing data on a gate is never a failure** — it just lowers
``coverage.gate_data_complete``, which feeds the match-confidence measure.

Aggregation
-----------
Every scored node maps to one of the seven rubric dimensions
(:data:`RUBRIC`), weighted by the node's own ``weight`` (1–5). A dimension with
no node answered by *both* users comes back ``None`` so the LLM pass can fill
it. ``structured_overall`` is the rubric-weighted mean of the covered
dimensions, then gate-capped.
"""

from __future__ import annotations

import question_tree

# The seven-dimension rubric shared with :mod:`matching_skill` — key, display
# label, weight (weights sum to 1.0, display order).
RUBRIC: list[tuple[str, str, float]] = [
    ("values", "Values & worldview", 0.22),
    ("life_goals", "Life goals & timeline", 0.20),
    ("attachment", "Attachment & conflict style", 0.16),
    ("personality", "Personality fit", 0.16),
    ("lifestyle", "Lifestyle & daily rhythm", 0.14),
    ("communication", "Communication & emotional needs", 0.08),
    ("interests", "Shared interests", 0.04),
]
RUBRIC_KEYS = [k for k, _, _ in RUBRIC]
_RUBRIC_WEIGHT = {k: w for k, _, w in RUBRIC}

# --- node → rubric dimension -------------------------------------------------

_NODE_DIMENSION: dict[str, str] = {
    # global core
    "ethnic_cultural_origin": "values",
    "attachment_style": "attachment",
    "social_energy": "lifestyle",
    "cognitive_processing": "personality",
    "conflict_communication": "attachment",
    "circadian_rhythm": "lifestyle",
    "cleanliness_index": "lifestyle",
    "alcohol_consumption": "lifestyle",
    "smoking_vaping": "lifestyle",
    "cannabis_substances": "lifestyle",
    "pets_owned": "lifestyle",
    "relationship_intent": "life_goals",
    "relocation_radius": "life_goals",
    # casual branch
    "love_language_ranking": "communication",
    "physical_activity_level": "interests",
    "spontaneity_index": "personality",
    "communication_density": "communication",
    "exclusivity_expectations": "values",
    "financial_splitting": "lifestyle",
    # long_term branch
    "capital_vs_experiential": "lifestyle",
    "career_integration_vector": "life_goals",
    "financial_comingling": "values",
    "procreation_intent": "life_goals",
    "extended_family_boundary": "values",
    "parenting_ideology": "values",
    "conversational_friction_demand": "communication",
    "core_existential_anchor": "values",
    # nikah branch
    "islamic_sect": "values",
    "madhhab_adherence": "values",
    "salah_frequency": "values",
    "halal_dietary": "lifestyle",
    "riba_free_finance": "values",
    "modesty_observance_self": "values",
    "modesty_expectation_partner": "values",
    "free_mixing_boundary": "values",
    "wali_involvement": "life_goals",
    "mahr_philosophy": "values",
    "polygyny_stance": "life_goals",
}

# enum nodes whose options form a strict spectrum — scored by index distance.
_ORDINAL_ENUMS = {
    "alcohol_consumption",
    "cannabis_substances",
    "physical_activity_level",
    "relocation_radius",
    "financial_comingling",
    "salah_frequency",
    "halal_dietary",
}

# multi nodes where "no overlap" is neutral rather than a clash: score is
# lifted onto ``floor + (1 - floor) * jaccard``.
_SOFT_MULTI = {"ethnic_cultural_origin": 0.55}

# Explicit compatibility matrices for the categorical enums. Key: frozenset of
# the two option strings. Value tuple: (table, default_for_unlisted_pairs).
# Same option is handled before the table and always scores 1.0.
_ENUM_MATRIX: dict[str, tuple[dict[frozenset, float], float]] = {
    "attachment_style": (
        {
            frozenset({"Secure", "Anxious-Preoccupied"}): 0.6,
            frozenset({"Secure", "Dismissive-Avoidant"}): 0.6,
            frozenset({"Secure", "Fearful-Avoidant"}): 0.5,
            frozenset({"Anxious-Preoccupied", "Dismissive-Avoidant"}): 0.2,
            frozenset({"Anxious-Preoccupied", "Fearful-Avoidant"}): 0.35,
            frozenset({"Dismissive-Avoidant", "Fearful-Avoidant"}): 0.3,
        },
        0.4,
    ),
    "circadian_rhythm": (
        {
            frozenset({"Early Morning Lark", "Balanced / Standard Day"}): 0.6,
            frozenset({"Balanced / Standard Day", "Deep Night Owl"}): 0.6,
            frozenset({"Early Morning Lark", "Deep Night Owl"}): 0.3,
        },
        0.4,
    ),
    "conflict_communication": (
        {
            frozenset(
                {
                    "Immediate confrontation and resolution",
                    "Cool-down period before verbal processing",
                }
            ): 0.45,
            frozenset(
                {
                    "Cool-down period before verbal processing",
                    "Written / structured mediation",
                }
            ): 0.6,
            frozenset(
                {
                    "Immediate confrontation and resolution",
                    "Written / structured mediation",
                }
            ): 0.3,
        },
        0.4,
    ),
    "cognitive_processing": (
        {
            frozenset(
                {
                    "Hyper-Rational / Analytical",
                    "Action-Oriented Pragmatist",
                }
            ): 0.6,
            frozenset(
                {
                    "Hyper-Rational / Analytical",
                    "Intuitive / Emotional-First",
                }
            ): 0.4,
            frozenset(
                {
                    "Intuitive / Emotional-First",
                    "Action-Oriented Pragmatist",
                }
            ): 0.5,
        },
        0.45,
    ),
    "communication_density": (
        {
            frozenset(
                {
                    "Constant text-pinging throughout the day",
                    "Single evening catch-up call",
                }
            ): 0.5,
            frozenset(
                {
                    "Single evening catch-up call",
                    "Strictly logistics-based messaging",
                }
            ): 0.55,
            frozenset(
                {
                    "Constant text-pinging throughout the day",
                    "Strictly logistics-based messaging",
                }
            ): 0.2,
        },
        0.4,
    ),
    # two options — same 1.0, different is the default
    "conversational_friction_demand": ({}, 0.35),
    "exclusivity_expectations": ({}, 0.2),
    "career_integration_vector": (
        {
            frozenset(
                {
                    "Hustle / High-Growth Executive",
                    "Balanced 9-to-5 / Priority on Leisure",
                }
            ): 0.5,
            frozenset(
                {
                    "Balanced 9-to-5 / Priority on Leisure",
                    "Intentionally retiring early / Alternative lifestyle",
                }
            ): 0.6,
            frozenset(
                {
                    "Hustle / High-Growth Executive",
                    "Intentionally retiring early / Alternative lifestyle",
                }
            ): 0.25,
        },
        0.4,
    ),
    "parenting_ideology": (
        {
            frozenset(
                {
                    "Highly structured / Authoritative / Traditional",
                    "Gentle / Unstructured / Progressive",
                }
            ): 0.3,
            frozenset(
                {
                    "Gentle / Unstructured / Progressive",
                    "Focus on early-childhood independence",
                }
            ): 0.6,
            frozenset(
                {
                    "Highly structured / Authoritative / Traditional",
                    "Focus on early-childhood independence",
                }
            ): 0.5,
        },
        0.4,
    ),
    "core_existential_anchor": (
        {
            frozenset({"Career & Innovation", "Creativity & Artistry"}): 0.6,
            frozenset({"Creativity & Artistry", "Community & Service"}): 0.5,
            frozenset({"Community & Service", "Family Preservation"}): 0.7,
            frozenset({"Community & Service", "Spiritual Growth"}): 0.7,
            frozenset({"Family Preservation", "Spiritual Growth"}): 0.7,
            frozenset({"Career & Innovation", "Family Preservation"}): 0.35,
            frozenset({"Career & Innovation", "Spiritual Growth"}): 0.35,
            frozenset({"Career & Innovation", "Community & Service"}): 0.45,
            frozenset({"Creativity & Artistry", "Family Preservation"}): 0.45,
            frozenset({"Creativity & Artistry", "Spiritual Growth"}): 0.5,
        },
        0.45,
    ),
    "financial_splitting": (
        {
            frozenset(
                {"Alternating rounds", "Absolute 50/50 down to the cent"}
            ): 0.8,
            frozenset({"Initiator pays", "High-income partner covers"}): 0.7,
            frozenset({"Alternating rounds", "Initiator pays"}): 0.55,
            frozenset({"Alternating rounds", "High-income partner covers"}): 0.5,
            frozenset(
                {"Absolute 50/50 down to the cent", "Initiator pays"}
            ): 0.45,
            frozenset(
                {
                    "Absolute 50/50 down to the cent",
                    "High-income partner covers",
                }
            ): 0.4,
        },
        0.5,
    ),
    "islamic_sect": ({}, 0.2),
    "madhhab_adherence": ({}, 0.4),
    "modesty_observance_self": ({}, 0.5),
    "free_mixing_boundary": ({}, 0.5),
    "wali_involvement": ({}, 0.55),
    "mahr_philosophy": ({}, 0.6),
    "modesty_expectation_partner": ({}, 0.35),
    "polygyny_stance": ({}, 0.25),
}

# --- intent resolution ----------------------------------------------------


def pair_intent(intent_a: str | None, intent_b: str | None) -> str:
    """The questionnaire branch a *pair* is scored against: the more serious of
    the two. If either routes to ``casual`` the pair is casual; ``nikah`` only
    when both route to ``nikah``; otherwise ``long-term``."""
    ba = question_tree.branch_for_intent(intent_a)
    bb = question_tree.branch_for_intent(intent_b)
    if "casual" in (ba, bb):
        return "casual"
    if ba == "nikah" and bb == "nikah":
        return "nikah"
    return "long-term"


# --- value coercion -----------------------------------------------------------


def _norm(s) -> str:
    return " ".join(str(s if s is not None else "").strip().casefold().split())


def _canon_enum(value, options: list[str]) -> str | None:
    if value is None:
        return None
    v = _norm(value)
    if not v:
        return None
    for o in options:
        if _norm(o) == v:
            return o
    for o in options:
        oc = _norm(o)
        if v in oc or oc in v:
            return o
    return None


def _to_int(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _to_bool(value):
    if isinstance(value, bool):
        return value
    s = _norm(value)
    if s in ("true", "yes", "1"):
        return True
    if s in ("false", "no", "0"):
        return False
    return None


def _typed_value(node: dict, profile: dict, qstore: dict):
    """The typed value for ``node`` for one user — from the questionnaire doc,
    the ``profile/main`` ``qz_*`` mirror, or a derivable profile field. ``None``
    when the user has not answered it."""
    nid = node["id"]
    kind = node["kind"]
    entry = qstore.get(nid) or {}
    raw = entry.get("value")
    mirror = profile.get(f"qz_{nid}")

    if nid == "primary_location":
        loc = profile.get("location") or mirror or (
            raw if isinstance(raw, str) else None
        )
        loc = (loc or "").strip()
        return loc or None

    if kind == "enum":
        for src in (mirror, raw):
            opt = _canon_enum(src, node["options"] or [])
            if opt:
                return opt
        return None
    if kind == "multi":
        vals = None
        if isinstance(mirror, list):
            vals = mirror
        elif isinstance(raw, list):
            vals = raw
        elif isinstance(raw, str):
            vals = [p.strip() for p in raw.split(",")]
        if not vals:
            return None
        out: list[str] = []
        for v in vals:
            opt = _canon_enum(v, node["options"] or [])
            if opt and opt not in out:
                out.append(opt)
        return out or None
    if kind == "scale":
        for src in (mirror, raw):
            n = _to_int(src)
            if n is not None:
                return n
        return None
    if kind == "bool":
        for src in (mirror, raw):
            b = _to_bool(src)
            if b is not None:
                return b
        return None
    return None  # narrative — the deterministic pass ignores it


# --- per-node subscores (0..1) ---------------------------------------------


def _scale_subscore(node: dict, a: int, b: int) -> float:
    s = node["scale"] or {}
    lo, hi = int(s.get("min", 1)), int(s.get("max", 10))
    span = hi - lo or 1
    return round(1.0 - min(abs(a - b), span) / span, 3)


def _enum_subscore(node_id: str, a: str, b: str) -> float:
    if a == b:
        return 1.0
    if node_id == "madhhab_adherence" and "Flexible / General Principles" in (a, b):
        return 0.75
    if node_id == "islamic_sect" and "Just Muslim / Non-denominational" in (a, b):
        return 0.7
    if node_id in _ORDINAL_ENUMS:
        opts = (question_tree.node(node_id) or {}).get("options") or []
        try:
            ia, ib = opts.index(a), opts.index(b)
        except ValueError:
            return 0.5
        span = (len(opts) - 1) or 1
        return round(1.0 - abs(ia - ib) / span, 3)
    spec = _ENUM_MATRIX.get(node_id)
    if not spec:
        return 0.4
    table, default = spec
    return table.get(frozenset({a, b}), default)


def _jaccard(a: list[str], b: list[str]) -> float:
    sa, sb = set(a), set(b)
    if not sa and not sb:
        return 1.0
    union = sa | sb
    return len(sa & sb) / len(union) if union else 1.0


def _multi_subscore(node_id: str, a: list[str], b: list[str]) -> float:
    j = _jaccard(a, b)
    floor = _SOFT_MULTI.get(node_id)
    if floor is not None:
        return round(floor + (1.0 - floor) * j, 3)
    return round(j, 3)


def _node_subscore(node: dict, a, b) -> float:
    kind = node["kind"]
    if kind == "scale":
        return _scale_subscore(node, int(a), int(b))
    if kind == "enum":
        return _enum_subscore(node["id"], a, b)
    if kind == "bool":
        return 1.0 if bool(a) == bool(b) else 0.2
    if kind == "multi":
        return _multi_subscore(node["id"], list(a), list(b))
    return 0.5


def _fmt(v) -> str:
    if isinstance(v, list):
        return "{" + ", ".join(str(x) for x in v) + "}"
    if isinstance(v, bool):
        return "yes" if v else "no"
    return str(v)


# --- gates ---------------------------------------------------------------------


def _gate_relationship_intent(ta, tb, pa, pb):
    va, vb = ta.get("relationship_intent"), tb.get("relationship_intent")
    if not (va and vb):
        return None
    serious = {"Long-term", "Marriage"}
    s = {va, vb}
    if "Casual" in s and (s & serious):
        want = sorted(s & serious)[0].lower()
        return f"One is here for something casual; the other wants {want}."
    return None


def _gate_procreation(ta, tb, pa, pb):
    va, vb = ta.get("procreation_intent"), tb.get("procreation_intent")
    if not (va and vb):
        return None
    childfree = "Absolutely non-negotiably childfree"
    wants = {
        "Want children within 1-3 years",
        "Want children within 4-7 years",
        "Open to adoption / fostering",
    }
    s = {va, vb}
    if childfree in s and (s & wants):
        return "One is firmly childfree; the other wants children."
    return None


def _gate_relocation(ta, tb, pa, pb):
    va, vb = ta.get("relocation_radius"), tb.get("relocation_radius")
    if not (va and vb):
        return None
    la = (pa.get("location") or pa.get("qz_primary_location") or "").strip().lower()
    lb = (pb.get("location") or pb.get("qz_primary_location") or "").strip().lower()
    if not la or not lb:
        return None
    if la == lb or la in lb or lb in la:
        return None
    stay_put = {"Within my city", "Within ~50 km"}
    if va in stay_put and vb in stay_put:
        return (
            f"They live in different places ({pa.get('location') or la} vs "
            f"{pb.get('location') or lb}) and neither will relocate far."
        )
    return None


def _gate_exclusivity(ta, tb, pa, pb):
    va, vb = ta.get("exclusivity_expectations"), tb.get("exclusivity_expectations")
    if not (va and vb):
        return None
    excl = "Exclusively seeing one person at a time during casual phases"
    multi = "Multi-dating completely acceptable until explicit consensus"
    if {va, vb} == {excl, multi}:
        return (
            "One expects exclusivity while things are casual; the other wants "
            "multi-dating open."
        )
    return None


def _gate_animal_allergies(ta, tb, pa, pb):
    aller_a = set(ta.get("animal_allergies") or []) - {"None"}
    aller_b = set(tb.get("animal_allergies") or []) - {"None"}
    pets_a = set(ta.get("pets_owned") or []) - {"None"}
    pets_b = set(tb.get("pets_owned") or []) - {"None"}
    hit = (aller_a & pets_b) | (aller_b & pets_a)
    if hit:
        return (
            f"Animal-allergy clash: one lives with {', '.join(sorted(hit))}, "
            "the other is allergic."
        )
    return None


def _gate_sect(ta, tb, pa, pb):
    va, vb = ta.get("islamic_sect"), tb.get("islamic_sect")
    if not (va and vb) or va == vb:
        return None
    wildcard = {"Just Muslim / Non-denominational", "Sufi"}
    if va in wildcard or vb in wildcard:
        return None
    return f"Different schools of Islam ({va} / {vb})."


def _gate_halal(ta, tb, pa, pb):
    va, vb = ta.get("halal_dietary"), tb.get("halal_dietary")
    if not (va and vb):
        return None
    if {va, vb} == {
        "Strictly Halal certified meats only",
        "No dietary restrictions",
    }:
        return "One keeps a strict halal diet; the other has no dietary restrictions."
    return None


def _gate_riba(ta, tb, pa, pb):
    va, vb = ta.get("riba_free_finance"), tb.get("riba_free_finance")
    if va is None or vb is None:
        return None
    if va != vb:
        return (
            "One requires fully riba-free (interest-free) finances; the other "
            "does not."
        )
    return None


def _gate_modesty(ta, tb, pa, pb):
    va = ta.get("modesty_expectation_partner")
    vb = tb.get("modesty_expectation_partner")
    if not (va and vb):
        return None
    if {va, vb} == {
        "Strict requirement for Hijab / Niqab",
        "Complete freedom / no requirement",
    }:
        return "Incompatible expectations of a partner's modest dress."
    return None


def _gate_polygyny(ta, tb, pa, pb):
    va, vb = ta.get("polygyny_stance"), tb.get("polygyny_stance")
    if not (va and vb):
        return None
    if {va, vb} == {
        "Intentionally looking for a polygynous arrangement",
        "Strictly monogamous marriage contract clause required",
    }:
        return "One wants a polygynous arrangement; the other requires a monogamy clause."
    return None


def _gate_salah(ta, tb, pa, pb):
    va, vb = ta.get("salah_frequency"), tb.get("salah_frequency")
    if not (va and vb):
        return None
    if {va, vb} == {
        "Consistently prays all 5 daily prayers on time",
        "Prays occasionally (Friday / Eid only)",
    }:
        return "A wide gap in daily prayer practice."
    return None


# node_id, display label, node_ids that must be answered by BOTH for the gate
# to count as "had its data", checker.
_GATE_SPECS = [
    ("relationship_intent", "Relationship intent",
     ["relationship_intent"], _gate_relationship_intent),
    ("relocation_radius", "Relocation / location",
     ["relocation_radius", "primary_location"], _gate_relocation),
    ("animal_allergies", "Animal allergies vs. pets",
     ["animal_allergies"], _gate_animal_allergies),
    ("procreation_intent", "Kids & timeline",
     ["procreation_intent"], _gate_procreation),
    ("exclusivity_expectations", "Exclusivity while casual",
     ["exclusivity_expectations"], _gate_exclusivity),
    ("islamic_sect", "School of Islam", ["islamic_sect"], _gate_sect),
    ("halal_dietary", "Halal diet", ["halal_dietary"], _gate_halal),
    ("riba_free_finance", "Riba-free finance",
     ["riba_free_finance"], _gate_riba),
    ("modesty_expectation_partner", "Partner modesty expectation",
     ["modesty_expectation_partner"], _gate_modesty),
    ("polygyny_stance", "Polygyny stance", ["polygyny_stance"], _gate_polygyny),
    ("salah_frequency", "Daily prayer", ["salah_frequency"], _gate_salah),
]


def _gate_cap(n_failures: int) -> float:
    """Overall-score ceiling (0..100) once ``n_failures`` gates have failed."""
    return max(10.0, 25.0 - 5.0 * (n_failures - 1))


# --- public API -------------------------------------------------------------


def score_structured(
    profile_a: dict,
    questionnaire_a: dict,
    profile_b: dict,
    questionnaire_b: dict,
    intent: str,
) -> dict:
    """Deterministic structured scoring for one pair.

    ``profile_*`` is the user's ``profile/main`` dict (with the ``qz_*``
    mirrors); ``questionnaire_*`` is ``{node_id: {value, source, ...}}``.
    ``intent`` selects the questionnaire branch — pass :func:`pair_intent` of
    the two users' relationship intents.

    Returns::

        {
          "gate_failures": [{node_id, label, reason}],
          "dimensions": {rubric_key: {score, from, covered_nodes, evidence}
                                     | None},
          "structured_overall": 0..100,
          "coverage": {structured_fraction, gate_data_complete,
                       node_coverage, covered_dimensions, llm_dimensions},
        }
    """
    profile_a = profile_a or {}
    profile_b = profile_b or {}
    questionnaire_a = questionnaire_a or {}
    questionnaire_b = questionnaire_b or {}

    nodes = question_tree.nodes_for_intent(intent)
    tree_ids = {n["id"] for n in nodes}

    # Typed value maps for every node in the tree (value or None).
    ta = {n["id"]: _typed_value(n, profile_a, questionnaire_a) for n in nodes}
    tb = {n["id"]: _typed_value(n, profile_b, questionnaire_b) for n in nodes}

    # --- gates ---
    gate_failures: list[dict] = []
    gate_total = 0
    gate_with_data = 0
    for node_id, label, needs, checker in _GATE_SPECS:
        if node_id not in tree_ids:
            continue
        gate_total += 1
        if all(ta.get(k) is not None and tb.get(k) is not None for k in needs):
            gate_with_data += 1
        reason = checker(ta, tb, profile_a, profile_b)
        if reason:
            gate_failures.append(
                {"node_id": node_id, "label": label, "reason": reason}
            )

    # --- graded dimensions ---
    per_dim: dict[str, dict] = {
        k: {"weighted": 0.0, "weight": 0.0, "covered_nodes": [], "evidence": []}
        for k in RUBRIC_KEYS
    }
    scoreable = 0
    both_answered = 0
    for n in nodes:
        nid = n["id"]
        dim = _NODE_DIMENSION.get(nid)
        if dim is None or n["kind"] == "narrative":
            continue
        scoreable += 1
        a, b = ta.get(nid), tb.get(nid)
        if a is None or b is None:
            continue
        both_answered += 1
        sub = _node_subscore(n, a, b)
        w = float(n.get("weight", 1))
        bucket = per_dim[dim]
        bucket["weighted"] += sub * w
        bucket["weight"] += w
        bucket["covered_nodes"].append(nid)
        bucket["evidence"].append(
            f"{n['label']}: {_fmt(a)} vs {_fmt(b)} → {round(sub * 100)}/100"
        )

    dimensions: dict[str, dict | None] = {}
    for k in RUBRIC_KEYS:
        bucket = per_dim[k]
        if bucket["weight"] <= 0:
            dimensions[k] = None
            continue
        dimensions[k] = {
            "score": round(100.0 * bucket["weighted"] / bucket["weight"], 1),
            "from": "structured",
            "covered_nodes": bucket["covered_nodes"],
            "evidence": bucket["evidence"],
        }

    covered_keys = [k for k in RUBRIC_KEYS if dimensions[k] is not None]
    llm_keys = [k for k in RUBRIC_KEYS if dimensions[k] is None]

    # structured_overall = rubric-weighted mean of the covered dimensions.
    if covered_keys:
        tw = sum(_RUBRIC_WEIGHT[k] for k in covered_keys)
        structured_overall = sum(
            dimensions[k]["score"] * _RUBRIC_WEIGHT[k] for k in covered_keys
        ) / tw
    else:
        structured_overall = 0.0
    if gate_failures:
        structured_overall = min(
            structured_overall, _gate_cap(len(gate_failures))
        )

    return {
        "gate_failures": gate_failures,
        "dimensions": dimensions,
        "structured_overall": round(structured_overall, 1),
        "coverage": {
            "structured_fraction": round(
                len(covered_keys) / len(RUBRIC_KEYS), 3
            ),
            "gate_data_complete": (
                round(gate_with_data / gate_total, 3) if gate_total else 1.0
            ),
            "node_coverage": (
                round(both_answered / scoreable, 3) if scoreable else 0.0
            ),
            "covered_dimensions": covered_keys,
            "llm_dimensions": llm_keys,
        },
    }
