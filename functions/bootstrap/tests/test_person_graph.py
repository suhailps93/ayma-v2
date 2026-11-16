"""Tests for the person-graph schema + seed⊕overlay merge (Phase 1).

Covers the v7 seed construction, node defaults (levels, section moves, Private
Context removal, common-sense visibility), the merge, emergent nodes, branch
filtering, and boundary validation.
"""

import pytest

import person_graph as pg
import question_tree
from person_graph import (
    GraphNode,
    Link,
    NodeState,
    OverlayNode,
    Provenance,
    Visibility,
    effective_graph,
    merge_node,
    seed,
    seed_node,
    validate_overlay,
)


# --- seed construction -----------------------------------------------------


def test_seed_covers_every_tree_node_with_a_level():
    s = seed()
    assert len(s) == len(question_tree.nodes())  # 104 (100 + 4 Nov-15 adds)
    assert all(n.level >= 1 for n in s.values())


def test_seed_level_counts_match_the_mapping():
    # The original 100 map to L1=9, L2=41, L3=50 (node-level-mapping doc). The
    # 4 Nov-15 About-Me additions plus the 6b "What I'm looking for" open node
    # are all level 2.
    s = seed()
    new_ids = {
        "marital_status", "languages_spoken", "height", "weight",
        "looking_for_description",  # seed v8 (6b) — the open looking-for node
    }
    orig = {nid: n for nid, n in s.items() if nid not in new_ids}
    counts = {1: 0, 2: 0, 3: 0}
    for n in orig.values():
        counts[n.level] += 1
    assert counts == {1: 9, 2: 41, 3: 50}
    assert all(s[i].level == 2 for i in new_ids)


def test_private_context_section_is_gone_and_its_nodes_remap_ayma_only():
    s = seed()
    assert all(n.section != "sensitive" for n in s.values())
    for nid in ("intimacy_pace", "physical_preferences_narrative"):
        assert s[nid].section == "relationships"
        assert s[nid].default_visibility is Visibility.AYMA_ONLY


def test_founder_section_moves_applied():
    s = seed()
    assert s["education_level"].section == "career"
    assert s["financial_comingling"].section == "finances"


def test_common_sense_default_visibility():
    s = seed()
    # Structured personal facts are NOT public by default (Scout 2449 blocker 1)
    # EXCEPT the founder-approved dating-profile allow-list. Non-allow-list
    # facts default private; body/finance facts stay private/ayma_only.
    assert s["financial_security_narrative"].default_visibility is Visibility.PRIVATE
    assert s["height"].default_visibility is Visibility.PRIVATE
    assert s["weight"].default_visibility is Visibility.AYMA_ONLY
    # the founder-approved public set (Nov 15): age/gender/location/interested-in/
    # intent + the open "What I'm looking for" description (seed v8, 6b)
    public_set = {
        "date_of_birth", "gender_identity", "primary_location",
        "target_match_genders", "relationship_intent", "looking_for_description",
    }
    for nid in public_set:
        assert s[nid].default_visibility is Visibility.PUBLIC, nid
    # nothing outside the allow-list (or an explicit public tag) defaults public
    assert all(
        nid in public_set
        for nid, n in s.items()
        if n.default_visibility is Visibility.PUBLIC
    )


def test_seed_section_visibility_matches_production_wiki_line():
    # The graph's per-section default visibility must equal the established
    # wiki_schema line, so a migrated/questionnaire-derived bullet inherits the
    # SAME visibility the equivalent wiki content had — nothing surfaces more
    # publicly than the product already allowed (Scout 2449 visibility check).
    import wiki_schema

    secdef = pg._section_default_visibility()
    for pt in question_tree.ordered_page_types():
        assert secdef[pt].value == wiki_schema.default_visibility_for(pt), pt


def test_sensitive_nodes_never_default_public():
    s = seed()
    for nid, n in s.items():
        if n.sensitive:
            assert n.default_visibility is not Visibility.PUBLIC, nid


def test_four_values_promotions_are_level_2():
    s = seed()
    for nid in (
        "religiosity_importance",
        "partner_religion_requirement",
        "political_orientation",
        "politics_partner_alignment",
    ):
        assert s[nid].level == 2, nid


# --- merge: seed ⊕ overlay -------------------------------------------------


def test_merge_seed_only_uses_defaults():
    n = merge_node(seed_node("date_of_birth"), None, "date_of_birth")
    assert n.state is NodeState.NOT_ASKED
    assert n.visibility is Visibility.PUBLIC  # DOB is on the public allow-list (as age)
    assert n.answer is None
    assert n.emergent is False


def test_merge_answer_sets_state_answered():
    ov = OverlayNode(answer="1994-02-02", provenance=Provenance.STATED)
    n = merge_node(seed_node("date_of_birth"), ov, "date_of_birth")
    assert n.answer == "1994-02-02"
    assert n.state is NodeState.ANSWERED
    assert n.provenance is Provenance.STATED


def test_overlay_visibility_and_weight_override_seed():
    ov = OverlayNode(visibility=Visibility.PRIVATE, weight=0.95)
    n = merge_node(seed_node("date_of_birth"), ov, "date_of_birth")
    assert n.visibility is Visibility.PRIVATE  # user override beats public default
    assert n.weight == 0.95


def test_emergent_node_is_overlay_defined_and_private():
    ov = OverlayNode(
        prompt="Collects vintage synths",
        section="misc",
        level=4,
        answer="Owns a Juno-106",
    )
    n = merge_node(None, ov, "emergent.synths")
    assert n.emergent is True
    assert n.section == "misc"
    assert n.level == 4
    assert n.visibility is Visibility.PRIVATE
    assert n.state is NodeState.ANSWERED


def test_emergent_node_missing_definition_raises():
    with pytest.raises(ValueError):
        merge_node(None, OverlayNode(answer="x"), "emergent.bad")


# --- effective graph + branch filtering ------------------------------------


def test_effective_graph_applies_overlay_and_filters_branch():
    overlay = {
        "date_of_birth": {"answer": "1994-02-02"},
        "emergent.synths": {
            "prompt": "Collects vintage synths",
            "section": "misc",
            "level": 4,
        },
    }
    g = effective_graph(overlay, intent="casual")
    assert g["date_of_birth"].answer == "1994-02-02"
    assert g["emergent.synths"].emergent is True
    # a long_term-only node must not appear on a casual graph
    lt_only = [
        n["id"]
        for n in question_tree.nodes()
        if n["branch"] == "long_term"
    ]
    assert lt_only, "expected some long_term-only nodes"
    assert all(nid not in g for nid in lt_only)


def test_effective_graph_includes_whole_branch_when_empty_overlay():
    g = effective_graph({}, intent="long_term")
    expected = {
        n["id"]
        for n in question_tree.nodes_for_intent("long_term")
    }
    assert set(g) == expected


# --- boundary validation ---------------------------------------------------


def test_validate_overlay_rejects_bad_visibility():
    with pytest.raises(Exception):
        validate_overlay({"date_of_birth": {"visibility": "secret"}})


def test_validate_overlay_rejects_unknown_fields():
    with pytest.raises(Exception):
        validate_overlay({"date_of_birth": {"not_a_field": 1}})


def test_link_strict_type_ok_and_free_requires_label():
    Link(target="a", type="elaborates")  # strict, fine
    Link(target="a", type="free", label="mentor_of")  # free with label, fine
    with pytest.raises(Exception):
        Link(target="a", type="free")  # free without label
    with pytest.raises(Exception):
        Link(target="a", type="made_up_type")  # unknown type


def test_confidence_bounds_enforced():
    with pytest.raises(Exception):
        OverlayNode(confidence=1.5)
