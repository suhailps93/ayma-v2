"""Tests for completeness tiers over the person graph (Phase 6a)."""

import person_graph_completeness as comp
import question_tree
from person_graph import effective_graph

_INTENT = "long_term"


def _answer_up_to_level(max_level):
    """An overlay answering every seed node on the long_term branch up to and
    including ``max_level``."""
    ov = {}
    for n in question_tree.nodes_for_intent(_INTENT):
        if int(n.get("level", 2)) <= max_level:
            ov[n["id"]] = {"answer": "x"}
    return ov


def _tier(overlay):
    return comp.compute_tier(effective_graph(overlay, intent=_INTENT))


def test_empty_graph_is_surface_and_not_matchable():
    out = _tier({})
    assert out["tier"] == comp.SURFACE
    assert out["matchable"] is False


def test_level1_only_is_surface():
    out = _tier(_answer_up_to_level(1))
    assert out["tier"] == comp.SURFACE
    assert out["levels"][1]["pct"] == 100
    assert out["levels"][2]["pct"] < 100
    assert out["matchable"] is False


def test_levels_1_2_complete_is_core_and_matchable():
    out = _tier(_answer_up_to_level(2))
    assert out["tier"] == comp.CORE
    assert out["matchable"] is True
    assert out["levels"][2]["pct"] == 100
    assert out["levels"][3]["pct"] < 100


def test_whole_seed_answered_is_deep():
    out = _tier(_answer_up_to_level(3))
    assert out["tier"] == comp.DEEP
    assert out["matchable"] is True
    assert all(out["levels"][lv]["pct"] == 100 for lv in (1, 2, 3))


def test_emergent_growth_beyond_seed_is_uncharted():
    ov = _answer_up_to_level(3)
    # grow two emergent nodes in two sections, one deep
    ov["emergent.a"] = {"prompt": "A", "section": "family", "level": 4, "answer": "x"}
    ov["emergent.b"] = {"prompt": "B", "section": "career", "level": 6, "answer": "y"}
    out = _tier(ov)
    assert out["tier"] == comp.UNCHARTED
    assert out["uncharted"]["emergent_count"] == 2
    assert out["uncharted"]["breadth"] == 2
    assert out["uncharted"]["depth"] == 6


def test_emergent_nodes_never_lower_a_percentage():
    # a half-answered L2 graph, then add emergent nodes: the L2 pct must not drop
    ov = {}
    l2 = [n["id"] for n in question_tree.nodes_for_intent(_INTENT)
          if int(n.get("level", 2)) == 2]
    for nid in l2[: len(l2) // 2]:
        ov[nid] = {"answer": "x"}
    before = _tier(ov)["levels"][2]["pct"]
    ov["emergent.z"] = {"prompt": "Z", "section": "misc", "level": 5, "answer": "x"}
    after = _tier(ov)["levels"][2]["pct"]
    assert after == before  # growth never enters the seed denominator
