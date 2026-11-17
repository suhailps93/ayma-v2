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
