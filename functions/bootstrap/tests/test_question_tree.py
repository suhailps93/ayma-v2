import json
from pathlib import Path

import question_tree as qt

_WIKI_PAGE_TYPES = {
    p["type"]
    for p in json.loads(
        (Path(__file__).parents[1] / "wiki_schema.json").read_text()
    )["page_types"]
}

_REQUIRED_KEYS = {
    "id",
    "page_type",
    "branch",
    "label",
    "kind",
    "options",
    "scale",
    "weight",
    "hard_filter",
    "dating_relevant",
    "ayma_prompt",
}


def test_config_loads_and_has_nodes():
    ns = qt.nodes()
    assert len(ns) >= 40
    ids = [n["id"] for n in ns]
    assert len(ids) == len(set(ids)), "node ids must be unique"


def test_every_node_has_the_required_keys_and_valid_enums():
    for n in qt.nodes():
        assert _REQUIRED_KEYS <= set(n), n["id"]
        assert n["page_type"] in _WIKI_PAGE_TYPES, n["id"]
        assert n["branch"] in qt.VALID_BRANCHES, n["id"]
        assert n["kind"] in qt.VALID_KINDS, n["id"]
        assert isinstance(n["weight"], int) and 1 <= n["weight"] <= 5, n["id"]
        assert isinstance(n["hard_filter"], bool), n["id"]
        assert isinstance(n["dating_relevant"], bool), n["id"]
        assert n["ayma_prompt"].strip(), n["id"]


def test_enum_and_multi_nodes_have_options():
    for n in qt.nodes():
        if n["kind"] in ("enum", "multi"):
            assert isinstance(n["options"], list) and len(n["options"]) >= 2, n["id"]
        else:
            assert n["options"] is None, n["id"]


def test_scale_nodes_have_a_scale_block():
    for n in qt.nodes():
        if n["kind"] == "scale":
            s = n["scale"]
            assert set(s) == {"min", "max", "min_label", "max_label"}, n["id"]
            assert s["min"] < s["max"]
        else:
            assert n["scale"] is None, n["id"]


def test_routing_node_exists():
    n = qt.node("relationship_intent")
    assert n["kind"] == "enum"
    assert n["branch"] == "all"
    assert n["hard_filter"] is True
    assert n["options"] == ["Casual", "Long-term", "Marriage", "Not sure yet"]


def test_nodes_for_intent_returns_global_plus_one_branch():
    for intent, branch in (
        ("Casual", "casual"),
        ("Long-term", "long_term"),
        ("Marriage", "long_term"),
        ("Not sure yet", "long_term"),
        (None, "long_term"),
    ):
        got = qt.nodes_for_intent(intent)
        branches = {n["branch"] for n in got}
        assert branches == {"all", branch}
        assert "nikah" not in branches
        # global core is always present
        assert any(n["id"] == "relationship_intent" for n in got)


def test_nikah_branch_is_parked_but_present():
    nikah_nodes = [n for n in qt.nodes() if n["branch"] == "nikah"]
    assert len(nikah_nodes) >= 10
    # never routed to by the questionnaire's own options
    for opt in qt.node("relationship_intent")["options"]:
        assert qt.branch_for_intent(opt) != "nikah"
    # ...but resolvable if asked explicitly
    assert qt.branch_for_intent("nikah") == "nikah"
    got = qt.nodes_for_intent("nikah")
    assert {n["branch"] for n in got} == {"all", "nikah"}


def test_narrative_and_hard_filter_id_helpers():
    narr = set(qt.narrative_ids())
    assert "casual_perfect_night_narrative" in narr
    assert "longterm_crisis_narrative" in narr
    assert all(qt.node(i)["kind"] == "narrative" for i in narr)

    hard = set(qt.hard_filter_ids())
    assert "relationship_intent" in hard
    assert "procreation_intent" in hard
    assert all(qt.node(i)["hard_filter"] for i in hard)


def test_branch_breakdown():
    counts: dict[str, int] = {}
    for n in qt.nodes():
        counts[n["branch"]] = counts.get(n["branch"], 0) + 1
    assert counts["all"] >= 15
    assert counts["casual"] >= 6
    assert counts["long_term"] >= 8
    assert counts["nikah"] >= 10
