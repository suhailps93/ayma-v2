"""Deterministic structured match scoring (``match_deterministic``)."""

import match_deterministic as md


def _q(**kv):
    """Build a questionnaire store: node_id -> {"value": ..., "source": ...}."""
    return {k: {"value": v, "source": "stated"} for k, v in kv.items()}


# --- intent resolution ------------------------------------------------------


def test_pair_intent_takes_the_more_serious_branch():
    assert md.pair_intent("Casual", "Marriage") == "casual"
    assert md.pair_intent("Long-term", "Marriage") == "long-term"
    assert md.pair_intent("nikah", "nikah") == "nikah"
    assert md.pair_intent("nikah", "Long-term") == "long-term"
    assert md.pair_intent(None, None) == "long-term"


# --- scale distance -------------------------------------------------------


def test_scale_node_distance_is_normalised():
    # social_energy is a 1..10 scale mapped to the lifestyle dimension.
    close = md.score_structured(
        {}, _q(social_energy="6"), {}, _q(social_energy="5"), "long-term"
    )
    far = md.score_structured(
        {}, _q(social_energy="1"), {}, _q(social_energy="10"), "long-term"
    )
    assert close["dimensions"]["lifestyle"]["score"] > (
        far["dimensions"]["lifestyle"]["score"]
    )
    # |1-10| / 9 == 1.0 -> subscore 0.
    assert far["dimensions"]["lifestyle"]["score"] == 0.0
    # |6-5| / 9 -> subscore ~0.889 -> ~88.9
    assert 88.0 <= close["dimensions"]["lifestyle"]["score"] <= 89.5


# --- enum matrix -------------------------------------------------------


def test_enum_matrix_secure_vs_anxious_vs_avoidant():
    assert md._enum_subscore("attachment_style", "Secure", "Secure") == 1.0
    assert md._enum_subscore(
        "attachment_style", "Secure", "Anxious-Preoccupied"
    ) == 0.6
    assert md._enum_subscore(
        "attachment_style", "Anxious-Preoccupied", "Dismissive-Avoidant"
    ) == 0.2
    # circadian: lark + lark = 1, lark + owl = 0.3
    assert md._enum_subscore(
        "circadian_rhythm", "Early Morning Lark", "Early Morning Lark"
    ) == 1.0
    assert md._enum_subscore(
        "circadian_rhythm", "Early Morning Lark", "Deep Night Owl"
    ) == 0.3
    # ordinal enum: Never..Heavy over 4 options
    assert md._enum_subscore("alcohol_consumption", "Never", "Heavy") == 0.0
    assert round(
        md._enum_subscore("alcohol_consumption", "Never", "Rare Social"), 3
    ) == round(1 - 1 / 3, 3)


# --- multi Jaccard -------------------------------------------------------


def test_multi_node_uses_jaccard_overlap():
    both_none = md.score_structured(
        {}, _q(pets_owned="None"), {}, _q(pets_owned="None"), "long-term"
    )
    half = md.score_structured(
        {},
        _q(pets_owned="Cats, Dogs"),
        {},
        _q(pets_owned="Dogs"),
        "long-term",
    )
    # {None} vs {None} -> full overlap on the lifestyle dimension bucket.
    assert both_none["dimensions"]["lifestyle"]["score"] == 100.0
    # {Cats,Dogs} vs {Dogs} -> jaccard 1/2 -> 50.
    assert half["dimensions"]["lifestyle"]["score"] == 50.0


# --- dimension aggregation weights by node weight ----------------------------


def test_dimension_aggregates_by_node_weight():
    # attachment dimension draws from attachment_style (weight 5) and
    # conflict_communication (weight 4). Perfect match on the heavy node,
    # weak match on the lighter one -> weighted toward the heavy node.
    res = md.score_structured(
        {},
        _q(
            attachment_style="Secure",
            conflict_communication="Immediate confrontation and resolution",
        ),
        {},
        _q(
            attachment_style="Secure",
            conflict_communication="Written / structured mediation",
        ),
        "long-term",
    )
    dim = res["dimensions"]["attachment"]
    assert set(dim["covered_nodes"]) == {"attachment_style", "conflict_communication"}
    # (1.0*5 + 0.3*4) / 9 = 0.6889 -> 68.9
    assert 68.0 <= dim["score"] <= 69.5
    assert any("Attachment style" in e for e in dim["evidence"])


def test_uncovered_dimension_is_null():
    res = md.score_structured(
        {}, _q(attachment_style="Secure"), {}, _q(attachment_style="Secure"),
        "long-term",
    )
    assert res["dimensions"]["attachment"] is not None
    assert res["dimensions"]["interests"] is None
    assert "interests" in res["coverage"]["llm_dimensions"]
    assert "attachment" in res["coverage"]["covered_dimensions"]


def test_one_sided_answer_is_not_covered():
    # Only A answered -> the node cannot produce a pair subscore.
    res = md.score_structured(
        {}, _q(attachment_style="Secure"), {}, {}, "long-term"
    )
    assert res["dimensions"]["attachment"] is None


# --- gate failures cap the score + are reported ---------------------------


def test_relationship_intent_gate_caps_and_reports():
    res = md.score_structured(
        {},
        _q(
            relationship_intent="Casual",
            attachment_style="Secure",
            social_energy="5",
            circadian_rhythm="Early Morning Lark",
        ),
        {},
        _q(
            relationship_intent="Marriage",
            attachment_style="Secure",
            social_energy="5",
            circadian_rhythm="Early Morning Lark",
        ),
        "long-term",
    )
    assert [g["node_id"] for g in res["gate_failures"]] == ["relationship_intent"]
    assert "casual" in res["gate_failures"][0]["reason"].lower()
    # Every graded node is a perfect match, but the gate caps the overall.
    assert res["structured_overall"] <= 25.0


def test_procreation_childfree_vs_wants_kids_is_a_gate():
    res = md.score_structured(
        {},
        _q(procreation_intent="Absolutely non-negotiably childfree"),
        {},
        _q(procreation_intent="Want children within 1-3 years"),
        "long-term",
    )
    assert any(g["node_id"] == "procreation_intent" for g in res["gate_failures"])
    assert res["structured_overall"] <= 25.0


def test_relocation_gate_needs_incompatible_radius_and_different_cities():
    fail = md.score_structured(
        {"location": "Lisbon"},
        _q(relocation_radius="Within my city"),
        {"location": "Oslo"},
        _q(relocation_radius="Within my city"),
        "long-term",
    )
    assert any(g["node_id"] == "relocation_radius" for g in fail["gate_failures"])

    ok = md.score_structured(
        {"location": "Lisbon"},
        _q(relocation_radius="Globally open / digital nomad"),
        {"location": "Oslo"},
        _q(relocation_radius="Within my city"),
        "long-term",
    )
    assert not any(
        g["node_id"] == "relocation_radius" for g in ok["gate_failures"]
    )


def test_animal_allergy_pet_clash_is_a_gate():
    res = md.score_structured(
        {},
        _q(pets_owned="Cats", animal_allergies="None"),
        {},
        _q(pets_owned="None", animal_allergies="Cats"),
        "long-term",
    )
    assert any(g["node_id"] == "animal_allergies" for g in res["gate_failures"])


def test_two_gate_failures_cap_lower_than_one():
    one = md.score_structured(
        {},
        _q(relationship_intent="Casual"),
        {},
        _q(relationship_intent="Marriage"),
        "long-term",
    )
    two = md.score_structured(
        {},
        _q(
            relationship_intent="Casual",
            procreation_intent="Absolutely non-negotiably childfree",
        ),
        {},
        _q(
            relationship_intent="Marriage",
            procreation_intent="Want children within 1-3 years",
        ),
        "long-term",
    )
    assert len(two["gate_failures"]) == 2
    assert two["structured_overall"] < one["structured_overall"] or (
        one["structured_overall"] == 0.0
    )
    assert md._gate_cap(1) == 25.0
    assert md._gate_cap(2) == 20.0


# --- missing data lowers a confidence input, is not a gate fail ------------


def test_missing_gate_data_lowers_completeness_not_a_failure():
    # Neither user gave procreation_intent -> no gate failure, but the gate
    # "did not have its data".
    res = md.score_structured(
        {}, _q(attachment_style="Secure"), {}, _q(attachment_style="Secure"),
        "long-term",
    )
    assert res["gate_failures"] == []
    assert res["coverage"]["gate_data_complete"] < 1.0

    full = md.score_structured(
        {"location": "Lisbon"},
        _q(
            relationship_intent="Long-term",
            relocation_radius="Anywhere in my country",
            primary_location="Lisbon",
            animal_allergies="None",
            procreation_intent="Want children within 4-7 years",
        ),
        {"location": "Lisbon"},
        _q(
            relationship_intent="Long-term",
            relocation_radius="Anywhere in my country",
            primary_location="Lisbon",
            animal_allergies="None",
            procreation_intent="Want children within 4-7 years",
        ),
        "long-term",
    )
    assert full["coverage"]["gate_data_complete"] == 1.0


# --- repeatability -------------------------------------------------------


def test_repeatable_same_inputs_same_output():
    args = (
        {"location": "Berlin", "qz_relationship_intent": "Long-term"},
        _q(
            attachment_style="Anxious-Preoccupied",
            social_energy="7",
            circadian_rhythm="Deep Night Owl",
            alcohol_consumption="Rare Social",
            pets_owned="Cats, Dogs",
            relationship_intent="Long-term",
            procreation_intent="Want children within 1-3 years",
            core_existential_anchor="Family Preservation",
        ),
        {"location": "Berlin"},
        _q(
            attachment_style="Secure",
            social_energy="4",
            circadian_rhythm="Balanced / Standard Day",
            alcohol_consumption="Weekly",
            pets_owned="Dogs",
            relationship_intent="Marriage",
            procreation_intent="Want children within 4-7 years",
            core_existential_anchor="Community & Service",
        ),
        "long-term",
    )
    first = md.score_structured(*args)
    second = md.score_structured(*args)
    assert first == second
