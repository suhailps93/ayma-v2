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
    for s in secs:
        assert s["label"] and 1 <= s["priority"] <= 5
        # the label is now the founder's canonical section title
        assert s["label"] == qt.section_title(s["page_type"])


def test_sections_for_intent_canonical_order():
    """Sections follow the canonical founder order from the metadata block
    (tree v6), not node weight — any section present in the tree appears in the
    same relative order as :func:`ordered_page_types`."""
    canonical = list(qt.ordered_page_types())
    # the founder's explicit leading order
    assert canonical[:9] == [
        "identity",
        "looking_for",
        "dealbreakers",
        "career",
        "personality",
        "interests",
        "family",
        "goals",
        "values",
    ]
    # private sections sit at the tail, relationships last. Private Context was
    # removed as a section (founder, 2026-11-15); its 2 nodes remapped to
    # Relationships as ayma_only, so the tail is Little Extras, Finances,
    # Relationships.
    assert canonical[-3:] == ["misc", "finances", "relationships"]
    for intent in (None, "long_term", "casual"):
        pts = [s["page_type"] for s in qt.sections_for_intent(intent)]
        present = [pt for pt in canonical if pt in pts]
        # every present canonical section appears in canonical order and leads
        # any straggler (a tree page_type missing from the metadata block)
        assert pts[: len(present)] == present


def test_branch_breakdown():
    counts: dict[str, int] = {}
    for n in qt.nodes():
        counts[n["branch"]] = counts.get(n["branch"], 0) + 1
    assert counts["all"] >= 15
    assert counts["casual"] >= 4
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


# --- coverage v2: dating-relevant dimensions (docs/PROFILE_COVERAGE.md) -----

_COVERAGE_V2_ALL = {
    "partner_age_min", "partner_age_max", "geographic_flexibility",
    "existing_children", "partner_children_openness", "career_role_narrative",
    "career_trajectory_narrative", "work_schedule_pattern", "religion_affiliation",
    "political_orientation", "stress_support_style", "dealbreakers_narrative",
    "love_language_ranking", "communication_density", "physical_activity_level",
    "diet_style", "hobbies_recharge_narrative", "travel_style", "pet_peeves_narrative",
}
_COVERAGE_V2_LONG_TERM = {
    "dating_to_marriage_timeline", "children_count", "future_family_proximity",
    "household_roles", "financial_strategy_narrative", "early_retirement_intent",
    "housing_preference", "spending_philosophy", "argument_repair_narrative",
}


def test_coverage_v2_nodes_are_routed_to_the_right_branches():
    all_ids = {n["id"] for n in qt.nodes() if n["branch"] == "all"}
    lt_ids = {n["id"] for n in qt.nodes() if n["branch"] == "long_term"}
    assert _COVERAGE_V2_ALL <= all_ids
    assert _COVERAGE_V2_LONG_TERM <= lt_ids
    # a casual dater is still asked the universal dating-logistics basics
    casual = {n["id"] for n in qt.nodes_for_intent("casual")}
    assert {"partner_age_min", "dealbreakers_narrative", "love_language_ranking"} <= casual


def test_tree_version_is_bumped_past_the_shallow_tree():
    assert qt.version() >= 2


def test_sensitive_nodes_are_optional_and_offer_a_decline():
    sensitive = [n for n in qt.nodes() if n.get("sensitive")]
    assert {n["id"] for n in sensitive} >= {
        "religion_affiliation", "political_orientation", "intimacy_pace",
        "physical_preferences_narrative",
    }
    for n in sensitive:
        assert n.get("optional") is True, n["id"]
        assert "optional" in n["ayma_prompt"], n["id"]
        if n["kind"] == "enum":
            assert "Prefer not to say" in n["options"], n["id"]


def test_enum_options_do_not_shadow_each_other():
    # option matching is substring-based, so no option of a v2 node may contain
    # another (older nodes such as gender_identity predate this rule)
    for n in qt.nodes():
        if n["id"] not in _COVERAGE_V2_ALL | _COVERAGE_V2_LONG_TERM:
            continue
        opts = n["options"] or []
        low = [o.casefold() for o in opts]
        for i, a in enumerate(low):
            for j, b in enumerate(low):
                assert i == j or a not in b, (n["id"], opts[i], opts[j])


def test_intimacy_and_physical_preference_nodes_live_on_a_private_page():
    import wiki_schema
    for nid in ("intimacy_pace", "physical_preferences_narrative"):
        pt = qt.node(nid)["page_type"]
        assert wiki_schema.default_visibility_for(pt) == "private", nid


def test_every_new_dimension_is_documented_in_the_coverage_doc():
    doc = (Path(__file__).parents[3] / "docs" / "PROFILE_COVERAGE.md").read_text()
    for nid in _COVERAGE_V2_ALL | _COVERAGE_V2_LONG_TERM:
        assert f"`{nid}`" in doc, nid


def test_section_meta_canonical_names_and_subtitles():
    """Tree v6 carries founder section names, subtitles and a full order."""
    assert qt.version() >= 6
    meta = qt.section_meta()
    # the renames the founder called out
    assert qt.section_title("identity") == "About Me"
    assert qt.section_title("goals") == "Life Goals"
    assert qt.section_title("misc") == "Little Extras"
    assert meta["goals"].get("name_locked") is True
    # the new split-out section exists with a subtitle
    assert "looking_for" in meta
    assert qt.section_subtitle("looking_for")
    # every section has a non-empty title + subtitle and a distinct order
    orders = [m["order"] for m in meta.values()]
    assert len(orders) == len(set(orders))
    for pt, m in meta.items():
        assert m["title"].strip() and m["subtitle"].strip(), pt
    # unknown page_type falls back, never raises
    assert qt.section_title("not_a_real_type") == "Not A Real Type"
    assert qt.section_subtitle("not_a_real_type") == ""


def test_relationships_private_by_default_finances_sensitive_too():
    """Private-by-default sections (founder order): relationships, finances,
    sensitive. Default visibility is owned by wiki_schema, not the tree."""
    import wiki_schema
    for pt in ("relationships", "finances", "sensitive"):
        assert wiki_schema.default_visibility_for(pt) == "private", pt
    # looking_for was split out public (age range public; specifics go private
    # at the bullet level, not the section level)
    assert wiki_schema.default_visibility_for("looking_for") == "public"
