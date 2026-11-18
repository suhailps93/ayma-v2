"""Tests for the Node Visualiser tree render (Contract 2 + 3) and the store
actions it is backed by: standard classification, fixed order, visibility
filtering, the split-bullet (mixed) subtree colour, the visibility cascade, and
the delete-with-descendant-count."""

import person_graph as pg
import person_graph_store as store
import person_graph_tree as tree
from person_graph import Visibility

from test_person_graph_store import FakeDb, _profile  # reuse the Firestore fake


def _graph(overlay):
    return pg.effective_graph(overlay, intent="long_term")


# --- Contract 2: standard classification -----------------------------------


def test_standard_fields_marked_in_canonical_order():
    g = _graph({})
    name = g["legal_first_name"]
    assert name.standard is True
    assert name.standard_field_label == "Name"
    assert name.standard_field_order == 0
    # a conversational seed node is NOT standard
    assert g["marital_status"].standard is False
    # the six About Me standard fields are the founder order
    labels = [
        pg.standard_label(i)
        for i in sorted(pg.STANDARD_FIELDS, key=lambda x: pg.STANDARD_FIELDS[x]["order"])
    ]
    assert labels == ["Name", "Age", "Gender", "Location", "Interested in",
                      "Ethnic & cultural origin"]


# --- fixed order: standard children render first ---------------------------


def test_tree_renders_standard_first_then_conversational():
    overlay = {
        "legal_first_name": {"answer": "Sam", "state": "answered"},
        "gender_identity": {"answer": "Woman", "state": "answered"},
        # a conversational emergent fact in the same section
        "emergent.story.identity.0": {
            "prompt": "Grew up in Lisbon", "section": "identity", "level": 2,
            "answer_type": "narrative", "answer": "Grew up in Lisbon",
            "state": "answered", "visibility": "public",
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    ident = next(s for s in t["sections"] if s["page_type"] == "identity")
    ids = [n["id"] for n in ident["nodes"]]
    # standard Name (order 0) before standard Gender (order 2) before the
    # conversational node
    assert ids.index("legal_first_name") < ids.index("gender_identity")
    assert ids.index("gender_identity") < ids.index("emergent.story.identity.0")
    assert ident["nodes"][0]["standard"] is True
    assert ident["nodes"][0]["standard_label"] == "Name"


# --- zero-duplicates render guarantee (founder build 2488) -----------------


def _norm(t):
    import person_graph_index as index_mod

    return index_mod.normalize_text(t)


def test_about_me_shows_each_standard_fact_once_no_duplicate_bullets():
    """Founder build 2488: his About Me showed Ethnic origin x2, Age x2, and
    Gender/Location/Interested-in restated as plain bullets. The same fact lived
    in a standard node AND an editor/story node restating it. The render MUST
    show each standard fact exactly once (the labelled row), dropping every
    restating bullet, in the fixed order — and no section repeats a fact."""
    # a DOB whose age the "Age: N" bullet restates (computed, not hardcoded)
    overlay = {
        "legal_first_name": {"answer": "Arun", "state": "answered"},
        "date_of_birth": {"answer": "1993-06-15", "state": "answered"},
        "gender_identity": {"answer": "Male", "state": "answered", "visibility": "public"},
        "primary_location": {"answer": "San Jose", "state": "answered", "visibility": "public"},
        "target_match_genders": {"answer": ["Women"], "state": "answered", "visibility": "public"},
        "ethnic_cultural_origin": {"answer": "South Asian", "state": "answered"},
    }
    g = _graph(overlay)
    age = g["date_of_birth"].answer and __import__("person_graph_render").node_display_text(
        g["date_of_birth"]
    )
    # the restating editor/story bullets the import minted today (all in identity)
    overlay.update(
        {
            "emergent.editor.identity.11": {
                "prompt": "Ethnic and cultural origin: South Asian",
                "section": "identity", "level": 2, "answer_type": "narrative",
                "answer": "Ethnic and cultural origin: South Asian",
                "state": "answered", "visibility": "private",
            },
            "emergent.editor.identity.4": {
                "prompt": f"Age: {age}", "section": "identity", "level": 2,
                "answer_type": "narrative", "answer": f"Age: {age}",
                "state": "answered", "visibility": "private",
            },
            "emergent.editor.identity.7": {
                "prompt": "Interested in: Women", "section": "identity", "level": 2,
                "answer_type": "narrative", "answer": "Interested in: Women",
                "state": "answered", "visibility": "public",
            },
            "emergent.story.identity.0": {
                "prompt": "Gender: Male", "section": "identity", "level": 2,
                "answer_type": "narrative", "answer": "Gender: Male",
                "state": "answered", "visibility": "public",
            },
            "emergent.story.identity.1": {
                "prompt": "South Asian", "section": "identity", "level": 2,
                "answer_type": "narrative", "answer": "South Asian",
                "state": "answered", "visibility": "private",
            },
            # a genuinely DISTINCT fact must survive (not over-suppressed)
            "emergent.story.identity.2": {
                "prompt": "Grew up in Chennai", "section": "identity", "level": 2,
                "answer_type": "narrative", "answer": "Grew up in Chennai",
                "state": "answered", "visibility": "public",
            },
        }
    )
    g = _graph(overlay)
    t = tree.node_tree(g, surface="story")
    ident = next(s for s in t["sections"] if s["page_type"] == "identity")

    # the six standard fields render, each exactly once, in canonical order
    std = [n for n in ident["nodes"] if n["standard"]]
    assert [n["standard_label"] for n in std] == [
        "Name", "Age", "Gender", "Location", "Interested in", "Ethnic & cultural origin",
    ]

    # every restating emergent node is suppressed (no surviving text); the
    # distinct fact survives. The standard rows keep the BARE value as their text
    # (the client prepends the label), so "South Asian" appears once — as the row.
    surviving_ids = {n["id"] for n in ident["nodes"] if n["text"]}
    for dup_id in (
        "emergent.editor.identity.11",  # "Ethnic and cultural origin: South Asian"
        "emergent.editor.identity.4",   # "Age: N"
        "emergent.editor.identity.7",   # "Interested in: Women"
        "emergent.story.identity.0",    # "Gender: Male"
        "emergent.story.identity.1",    # bare "South Asian"
    ):
        assert dup_id not in surviving_ids, f"{dup_id} restatement not suppressed"
    assert "emergent.story.identity.2" in surviving_ids  # the distinct fact survives
    texts = [n["text"] for n in ident["nodes"] if n["text"]]
    assert texts.count("South Asian") == 1  # only the standard Ethnic row

    # no section repeats a fact: no normalized text appears twice anywhere
    def _all_texts(nodes):
        for n in nodes:
            if n.get("text"):
                yield _norm(n["text"])
            yield from _all_texts(n.get("children", []))

    for s in t["sections"]:
        norms = list(_all_texts(s["nodes"]))
        assert len(norms) == len(set(norms)), f"section {s['page_type']} repeats a fact"


def test_unmerged_graph_collapses_two_distinct_restatement_nodes_in_a_section():
    """NOTE 252 leg 28 (build 2490 FAIL): on an UNMERGED graph, two DISTINCT
    emergent nodes restate the same fact in one section — neither is a standard
    row, and their normalized text DIFFERS by a stopword/punctuation ("Ethnic &
    cultural origin: South Asian" vs "ethnic and cultural origin south asian"), so
    the exact-norm dedup misses them and BOTH rendered twice in Your Story. The
    render must collapse them to one (content-token-set dedup) WITHOUT merging the
    stored data, while a genuinely distinct fact in the same section survives."""
    overlay = {
        "emergent.editor.identity.A": {
            "prompt": "Ethnic & cultural origin: South Asian",
            "section": "identity", "level": 2, "answer_type": "narrative",
            "answer": "Ethnic & cultural origin: South Asian",
            "state": "answered", "visibility": "public",
        },
        "emergent.story.identity.B": {
            "prompt": "ethnic and cultural origin south asian",
            "section": "identity", "level": 2, "answer_type": "narrative",
            "answer": "ethnic and cultural origin south asian",
            "state": "answered", "visibility": "public",
        },
        # a genuinely DISTINCT fact in the same section must NOT be over-suppressed
        "emergent.story.identity.C": {
            "prompt": "Grew up in Chennai",
            "section": "identity", "level": 2, "answer_type": "narrative",
            "answer": "Grew up in Chennai",
            "state": "answered", "visibility": "public",
        },
    }
    g = _graph(overlay)
    # no standard node carries this value — the layer-3 data merge did NOT run here
    assert g["ethnic_cultural_origin"].answer in (None, "", [])
    t = tree.node_tree(g, surface="story")
    ident = next(s for s in t["sections"] if s["page_type"] == "identity")

    def _all_texts(nodes):
        for n in nodes:
            if n.get("text"):
                yield n["text"]
            yield from _all_texts(n.get("children", []))

    texts = list(_all_texts(ident["nodes"]))
    # the fact renders exactly once (content-token sets are unique in the section)
    import person_graph_index as index_mod
    tok_sets = [index_mod.token_set(x) for x in texts if index_mod.token_set(x)]
    assert len(tok_sets) == len(set(tok_sets)), f"section repeats a fact: {texts}"
    # exactly one of the two restatements survives; the distinct fact survives
    surviving = {n["id"] for n in ident["nodes"] if n["text"]}
    assert len(surviving & {"emergent.editor.identity.A", "emergent.story.identity.B"}) == 1
    assert "emergent.story.identity.C" in surviving


def test_public_surface_keeps_fact_when_standard_row_is_private():
    """Privacy: suppression is surface-aware. ``ethnic_cultural_origin`` defaults
    PRIVATE, so it does not render on the public profile; a PUBLIC bullet that
    restates it must therefore NOT be suppressed there (else the fact vanishes
    from the public surface). On the owner surface the standard row renders, so
    the restatement is suppressed there."""
    overlay = {
        "ethnic_cultural_origin": {"answer": "South Asian", "state": "answered"},  # private
        "emergent.editor.identity.0": {
            "prompt": "Ethnic and cultural origin: South Asian",
            "section": "identity", "level": 2, "answer_type": "narrative",
            "answer": "Ethnic and cultural origin: South Asian",
            "state": "answered", "visibility": "public",
        },
    }
    g = _graph(overlay)
    pub = tree.node_tree(g, surface="publicProfile")
    pub_ident = next((s for s in pub["sections"] if s["page_type"] == "identity"), None)
    assert pub_ident is not None
    pub_texts = [n["text"] for n in pub_ident["nodes"] if n["text"]]
    # the public bullet is the ONLY public copy of the fact — it must survive
    assert "Ethnic and cultural origin: South Asian" in pub_texts

    story = tree.node_tree(g, surface="story")
    s_ident = next(s for s in story["sections"] if s["page_type"] == "identity")
    # on the owner surface the standard row renders, so the restatement is dropped
    s_texts = [n["text"] for n in s_ident["nodes"] if n["text"]]
    assert "Ethnic and cultural origin: South Asian" not in s_texts
    assert any(n["standard"] and n["standard_label"] == "Ethnic & cultural origin"
               for n in s_ident["nodes"])


# --- visibility filtering: story vs public ---------------------------------


def test_story_shows_private_public_public_hides_private():
    overlay = {
        "emergent.story.goals.0": {
            "prompt": "Public goal", "section": "goals", "level": 2,
            "answer_type": "narrative", "answer": "Public goal",
            "state": "answered", "visibility": "public",
        },
        "emergent.story.goals.1": {
            "prompt": "Private goal", "section": "goals", "level": 2,
            "answer_type": "narrative", "answer": "Private goal",
            "state": "answered", "visibility": "private",
        },
    }
    g = _graph(overlay)
    story = tree.node_tree(g, surface="story")
    goals_story = next(s for s in story["sections"] if s["page_type"] == "goals")
    texts = {n["text"] for n in goals_story["nodes"]}
    assert texts == {"Public goal", "Private goal"}

    public = tree.node_tree(g, surface="publicProfile")
    goals_pub = next((s for s in public["sections"] if s["page_type"] == "goals"), None)
    assert goals_pub is not None
    assert {n["text"] for n in goals_pub["nodes"]} == {"Public goal"}


def test_public_never_leaks_ayma_only():
    overlay = {
        "emergent.steering.x": {
            "prompt": "Ayma note", "section": "goals", "level": 2,
            "answer_type": "narrative", "answer": "Ayma private note",
            "state": "answered", "visibility": "ayma_only",
        },
    }
    g = _graph(overlay)
    public = tree.node_tree(g, surface="publicProfile", include_ayma_only=True)
    for s in public["sections"]:
        for n in s["nodes"]:
            assert n["visibility"] != "ayma_only"


# --- dated: surfaced only where the node already carries one (Career view) ---


def test_node_dated_surfaced_from_link_dated_only_where_present():
    """The dedicated Career view renders a date only where a node ALREADY has
    one (the first ``Link.dated`` on it). A node with no dated link lists with
    no date; no date is ever invented and no node is migrated."""
    overlay = {
        "emergent.story.career.0": {
            "prompt": "Senior engineer at Acme", "section": "career", "level": 2,
            "answer_type": "narrative", "answer": "Senior engineer at Acme",
            "state": "answered", "visibility": "public",
            "links": [
                {"target": "career_role_narrative", "type": "same_topic",
                 "dated": "2021-06"},
            ],
        },
        "emergent.story.career.1": {
            "prompt": "Studied CS", "section": "career", "level": 2,
            "answer_type": "narrative", "answer": "Studied CS",
            "state": "answered", "visibility": "public",
        },
    }
    g = _graph(overlay)
    t = tree.node_tree(g, surface="story")
    career = next(s for s in t["sections"] if s["page_type"] == "career")
    by_id = {n["id"]: n for n in career["nodes"]}
    assert by_id["emergent.story.career.0"]["dated"] == "2021-06"
    # a node with no dated link lists WITHOUT a date (never invented)
    assert by_id["emergent.story.career.1"]["dated"] == ""
    # every node carries the key, defaulting to "" (the Career view keys on it)
    assert all("dated" in n for n in career["nodes"])


def test_ayma_only_shown_in_story_when_flag_on_hidden_when_off():
    overlay = {
        "emergent.editor.goals.0": {
            "prompt": "Ayma note", "section": "goals", "level": 2,
            "answer_type": "narrative", "answer": "Ayma note",
            "state": "answered", "visibility": "ayma_only",
        },
    }
    g = _graph(overlay)
    on = tree.node_tree(g, surface="story", include_ayma_only=True)
    goals_on = next((s for s in on["sections"] if s["page_type"] == "goals"), None)
    assert goals_on and any(n["visibility"] == "ayma_only" for n in goals_on["nodes"])
    off = tree.node_tree(g, surface="story", include_ayma_only=False)
    goals_off = next((s for s in off["sections"] if s["page_type"] == "goals"), None)
    assert goals_off is None or all(
        n["visibility"] != "ayma_only" for n in goals_off["nodes"]
    )


def test_ayma_only_node_is_not_editable():
    overlay = {
        "emergent.editor.goals.0": {
            "prompt": "Ayma note", "section": "goals", "level": 2,
            "answer_type": "narrative", "answer": "Ayma note",
            "state": "answered", "visibility": "ayma_only",
        },
    }
    g = _graph(overlay)
    t = tree.node_tree(g, surface="story", include_ayma_only=True)
    node = next(
        n for s in t["sections"] for n in s["nodes"]
        if n["id"] == "emergent.editor.goals.0"
    )
    assert node["editable"] is False


# --- Part 2: write-time / read-time VISUAL surfacing -----------------------


def test_every_node_carries_a_visual_descriptor():
    """Every tree node surfaces a ``{type, params, v}`` visual (the thin client
    palette dispatches on it); no node is ever without one."""
    overlay = {
        "legal_first_name": {"answer": "Sam", "state": "answered"},
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    nodes = [n for s in t["sections"] for n in s["nodes"]]
    assert nodes
    for n in nodes:
        assert isinstance(n.get("visual"), dict)
        assert n["visual"].get("type")
        assert "params" in n["visual"] and "v" in n["visual"]


def test_read_time_default_career_node_is_a_timeline_entry():
    """A dated career node with NO stored visual derives a timeline_entry at read
    time (no backfill), carrying its gist as the title and its existing date."""
    overlay = {
        "emergent.story.career.0": {
            "prompt": "Senior engineer at Acme", "section": "career", "level": 2,
            "answer_type": "narrative", "answer": "Senior engineer at Acme",
            "state": "answered", "visibility": "public",
            "links": [{"target": "x", "type": "same_topic", "dated": "2021-06"}],
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    node = next(
        n for s in t["sections"] for n in s["nodes"]
        if n["id"] == "emergent.story.career.0"
    )
    assert node["visual"]["type"] == "timeline_entry"
    assert node["visual"]["params"]["date"] == "2021-06"
    assert node["visual"]["params"]["title"]


def test_read_time_default_interest_node_is_a_chip():
    """A list-like section's node with no stored visual derives a one-item
    chip_set (sibling chips merge into a set in the renderer)."""
    overlay = {
        "emergent.story.interests.0": {
            "prompt": "Rock climbing", "section": "interests", "level": 2,
            "answer_type": "narrative", "answer": "Rock climbing",
            "state": "answered", "visibility": "public",
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    node = next(
        n for s in t["sections"] for n in s["nodes"]
        if n["id"] == "emergent.story.interests.0"
    )
    assert node["visual"]["type"] == "chip_set"
    assert node["visual"]["params"]["items"] == ["Rock climbing"]


def test_stored_visual_wins_over_read_time_default():
    """A writer-stored visual (any palette type, even an unknown/newer one) is
    surfaced untouched — the client falls back to gist_row for one it can't draw."""
    overlay = {
        "emergent.story.interests.0": {
            "prompt": "Rock climbing", "section": "interests", "level": 2,
            "answer_type": "narrative", "answer": "Rock climbing",
            "state": "answered", "visibility": "public",
            "visual": {"type": "small_table", "params": {"columns": ["a"],
                                                          "rows": [["1"]]}, "v": 1},
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    node = next(
        n for s in t["sections"] for n in s["nodes"]
        if n["id"] == "emergent.story.interests.0"
    )
    assert node["visual"]["type"] == "small_table"
    assert node["visual"]["params"]["columns"] == ["a"]


def test_plain_section_node_defaults_to_gist_row():
    """A node in a non-list, non-dated section defaults to gist_row (the universal
    fallback) — no visual is ever forced where the node can't fill its params."""
    overlay = {
        "emergent.story.goals.0": {
            "prompt": "Find my person", "section": "goals", "level": 2,
            "answer_type": "narrative", "answer": "Find my person",
            "state": "answered", "visibility": "public",
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    node = next(
        n for s in t["sections"] for n in s["nodes"]
        if n["id"] == "emergent.story.goals.0"
    )
    assert node["visual"]["type"] == "gist_row"


# --- split bullet: mixed subtree -------------------------------------------


def test_parent_with_mixed_subtree_is_mixed():
    db = FakeDb(_profile("u"))
    parent = store.add_loose_node(db, "u", "My family", section="family")
    store.set_visibility(db, "u", parent, "public")
    pub = store.add_child_node(db, "u", parent, "Public child", visibility="public")
    priv = store.add_child_node(db, "u", parent, "Private child", visibility="private")
    g = store.effective(db, "u")
    t = tree.node_tree(g, surface="story")
    pnode = next(
        n for s in t["sections"] for n in s["nodes"] if n["id"] == parent
    )
    assert pnode["subtree_visibility"] == "mixed"
    # child ids present and nested
    child_ids = {c["id"] for c in pnode["children"]}
    assert pub in child_ids and priv in child_ids


# --- visibility cascade ----------------------------------------------------


def test_visibility_cascade_sets_descendants_exempts_ayma_only():
    db = FakeDb(_profile("u"))
    parent = store.add_loose_node(db, "u", "Root fact", section="family")
    child = store.add_child_node(db, "u", parent, "child", visibility="private")
    grandkid = store.add_child_node(db, "u", child, "grandchild", visibility="private")
    ai = store.add_child_node(db, "u", parent, "ai note", visibility="private")
    store.set_visibility(db, "u", ai, "ayma_only")

    changed = store.set_visibility_cascade(db, "u", parent, "public")
    assert changed >= 3  # parent + child + grandchild
    g = store.effective(db, "u")
    assert g[parent].visibility is Visibility.PUBLIC
    assert g[child].visibility is Visibility.PUBLIC
    assert g[grandkid].visibility is Visibility.PUBLIC
    # ayma_only child is exempt
    assert g[ai].visibility is Visibility.AYMA_ONLY


# --- delete with descendant count ------------------------------------------


def test_delete_count_and_delete_with_descendants():
    db = FakeDb(_profile("u"))
    parent = store.add_loose_node(db, "u", "Root", section="family")
    c1 = store.add_child_node(db, "u", parent, "c1")
    store.add_child_node(db, "u", c1, "c1a")
    store.add_child_node(db, "u", parent, "c2")

    assert store.descendant_count(db, "u", parent) == 3  # c1, c1a, c2
    removed = store.delete_node_with_descendants(db, "u", parent)
    assert removed == 4  # parent + 3 descendants
    assert store.node_overlay_entry(db, "u", parent) == {}


# --- add child at a nested level -------------------------------------------


def test_add_child_at_nested_level():
    db = FakeDb(_profile("u"))
    parent = store.add_loose_node(db, "u", "Root", section="family")  # level 1
    child = store.add_child_node(db, "u", parent, "child")            # level 2
    grand = store.add_child_node(db, "u", child, "grandchild")        # level 3
    g = store.effective(db, "u")
    assert g[child].level == g[parent].level + 1
    assert g[grand].level == g[child].level + 1
    assert g[grand].parent == child


# --- image node embedded under its parent ----------------------------------


def test_set_node_text_edits_emergent_and_retires_history():
    db = FakeDb(_profile("u"))
    nid = store.add_loose_node(db, "u", "Old text", section="family")
    store.set_node_text(db, "u", nid, "New text")
    e = store.node_overlay_entry(db, "u", nid)
    assert e["answer"] == "New text"
    assert any(h["answer"] == "Old text" for h in e.get("history", []))


def test_image_node_nested_under_parent_with_context():
    db = FakeDb(_profile("u"))
    res = store.add_photo_fact(
        db, "u",
        image_url="https://x/img.jpg",
        image_read="A person smiling",
        fact_text="At the beach",
        visibility="public",
    )
    fact_id, image_id = res
    store.set_visibility(db, "u", fact_id, "public")
    g = store.effective(db, "u")
    t = tree.node_tree(g, surface="story")
    fact = next(n for s in t["sections"] for n in s["nodes"] if n["id"] == fact_id)
    img = next((c for c in fact["children"] if c["id"] == image_id), None)
    assert img is not None
    assert img["answer_type"] == "image"
    assert img["image_url"] == "https://x/img.jpg"
    assert img["image_read"] == "A person smiling"
    assert img["is_you"] == "unknown"  # Contract 1 default when field absent
