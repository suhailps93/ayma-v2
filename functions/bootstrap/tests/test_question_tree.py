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
    "tier",
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


def test_every_node_has_a_valid_tier():
    for n in qt.nodes():
        assert n.get("tier") in qt.VALID_TIERS, n["id"]
        assert qt.tier(n["id"]) == n["tier"]
    core = set(qt.core_ids())
    assert "relationship_intent" in core
    assert core == {n["id"] for n in qt.nodes() if n["tier"] == "core"}
    # the split is meaningfully two-sided
    assert core and set(n["id"] for n in qt.nodes()) - core


def test_every_intent_section_has_at_least_one_core_node():
    for intent in ("casual", "long_term", "nikah"):
        by_pt: dict[str, set] = {}
        for n in qt.nodes_for_intent(intent):
            by_pt.setdefault(n["page_type"], set()).add(n["tier"])
        for pt, tiers in by_pt.items():
            assert "core" in tiers, (intent, pt)
    # ...and the intent-unset view (branch == "all") on its own
    by_pt = {}
    for n in qt.nodes():
        if n["branch"] == "all":
            by_pt.setdefault(n["page_type"], set()).add(n["tier"])
    for pt, tiers in by_pt.items():
        assert "core" in tiers, pt


def test_sections_for_intent_ordering():
    secs = qt.sections_for_intent("long_term")
    pts = [s["page_type"] for s in secs]
    assert pts[0] == "identity"
    # every section a page_type that actually has nodes for this intent
    assert set(pts) == {n["page_type"] for n in qt.nodes_for_intent("long_term")}
    # ranked by section priority (max node weight) descending
    prios = [s["priority"] for s in secs]
    assert prios == sorted(prios, reverse=True)
    for s in secs:
        assert s["label"] and 1 <= s["priority"] <= 5
    # ties broken by first appearance in the tree
    tree_order = []
    for n in qt.nodes_for_intent("long_term"):
        if n["page_type"] not in tree_order:
            tree_order.append(n["page_type"])
    for a, b in zip(secs, secs[1:]):
        if a["priority"] == b["priority"]:
            assert tree_order.index(a["page_type"]) < tree_order.index(
                b["page_type"]
            )


def test_branch_breakdown():
    counts: dict[str, int] = {}
    for n in qt.nodes():
        counts[n["branch"]] = counts.get(n["branch"], 0) + 1
    assert counts["all"] >= 15
    assert counts["casual"] >= 6
    assert counts["long_term"] >= 8
    assert counts["nikah"] >= 10


# --- depth revamp: family, friends, past relationships, childhood, finances --
#
# Founder feedback: a profile that reached 100% still hadn't touched a
# person's family, friends, past relationships or childhood. These cover
# that gap, in the same node shape as everything else in the tree.

_NEW_DEPTH_NODE_IDS = {
    "family_of_origin_narrative",
    "parental_relationship_narrative",
    "sibling_relationship_narrative",
    "childhood_formative_narrative",
    "childhood_hardship_narrative",
    "closest_friendships_narrative",
    "friendship_role_narrative",
    "past_relationship_narrative",
    "relationship_patterns_narrative",
    "financial_security_narrative",
    "income_comfort_level",
    "retirement_savings_outlook",
    "financial_stress_narrative",
}

# Phrases that mark an `ayma_prompt` as opt-in / non-interrogative — the
# tone the founder asked for on anything touching hardship, trauma or money.
_GENTLE_MARKERS = ("gently", "only if", "never p", "never phrase")


def test_new_depth_nodes_exist_and_are_well_formed():
    by_id = {n["id"]: n for n in qt.nodes()}
    assert _NEW_DEPTH_NODE_IDS <= set(by_id)
    for nid in _NEW_DEPTH_NODE_IDS:
        n = by_id[nid]
        assert _REQUIRED_KEYS <= set(n), nid
        assert n["ayma_prompt"].strip(), nid


def test_family_and_friends_are_universal_not_relationship_planning():
    # Family-of-origin / friends / romantic-history depth is who-they-are
    # backstory, not a future-facing relationship preference, so it belongs
    # on `all` (every intent) like identity/personality already do — unlike
    # the existing family-*planning* nodes (kids, parenting), which stay
    # long_term-only.
    for nid in (
        "family_of_origin_narrative", "parental_relationship_narrative",
        "sibling_relationship_narrative", "childhood_formative_narrative",
        "childhood_hardship_narrative", "closest_friendships_narrative",
        "friendship_role_narrative", "past_relationship_narrative",
        "relationship_patterns_narrative",
    ):
        assert qt.node(nid)["branch"] == "all", nid
    # future-facing family-planning content stays untouched, long_term-only
    assert qt.node("extended_family_boundary")["branch"] == "long_term"
    assert qt.node("parenting_ideology")["branch"] == "long_term"


def test_sensitive_new_nodes_are_never_hard_filters():
    # Childhood hardship and money are soft narrative signal for Ayma's own
    # read of the person, never a pass/fail matching gate — so none of them
    # get mirrored onto `profile/main.qz_*` (see completeness._evaluate /
    # skills.questionnaire._record). That mirror is the only path from the
    # questionnaire store to anything resembling a shared field, so keeping
    # hard_filter off here keeps this content inside the private
    # `users/{uid}/questionnaire` store.
    for nid in (
        "childhood_hardship_narrative", "financial_security_narrative",
        "income_comfort_level", "retirement_savings_outlook",
        "financial_stress_narrative",
    ):
        assert qt.node(nid)["hard_filter"] is False, nid


def test_hardship_and_money_prompts_are_gentle_and_opt_in():
    for nid in ("childhood_hardship_narrative", "financial_stress_narrative"):
        prompt = qt.node(nid)["ayma_prompt"].lower()
        assert any(m in prompt for m in _GENTLE_MARKERS), nid
        # never a bald ask for numbers/specifics
        assert "how much" not in prompt and "net worth" not in prompt


def test_income_question_never_asks_for_a_bald_number():
    prompt = qt.node("income_comfort_level")["ayma_prompt"].lower()
    assert "exact number" not in prompt or "not an exact number" in prompt
    assert "net worth" not in prompt
    opts = qt.node("income_comfort_level")["options"]
    assert "Prefer not to say" in opts
    assert not any(ch.isdigit() for opt in opts for ch in opt), (
        "income comfort should be a qualitative band, not a $ figure"
    )


def test_new_finances_page_type_defaults_to_private():
    import wiki_schema
    assert wiki_schema.default_visibility_for("finances") == "private"
    assert wiki_schema.default_visibility_for("social_circle") == "public"
