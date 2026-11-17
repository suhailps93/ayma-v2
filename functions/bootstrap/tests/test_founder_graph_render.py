"""Founder graph-render defect (Nov 17 2026): his real graph rendered EMPTY on
every new surface — Your Story empty, public profile "Nothing public yet", the
person graph a bundle of lines with no nodes.

Root cause: ``merge_node`` RAISED for any emergent node missing
prompt/section/level, and ``effective_graph`` called it for every overlay node
with no catch — so his 54 "minimal" nodes (stored with only answer/provenance/
state, from legacy/partial writes) made ``effective()`` throw, blanking EVERY
surface. 216 of 226 of his nodes also carry no parent (they're keyed by a
``section`` field, which the renderer already supports — a parentless node shows
under its section). Nothing was lost; the crash was the whole problem.

Fix: emergent nodes default the missing structural fields (section→misc, level
→1, prompt→the answer) instead of raising, plus a per-node safety net in
effective_graph. This pins his shape so it never blanks the graph again.
"""

import person_graph as pg
import person_graph_tree as tree


def _founder_shape() -> dict:
    """An overlay with the three shapes his real graph has: minimal nodes (no
    section/level/prompt), parentless section-keyed nodes (some public), and an
    ordinary one — none linked into a parent tree."""
    overlay: dict = {}
    # 54-style minimal nodes: only answer/provenance/state.
    for i in range(5):
        overlay[f"emergent.min{i}"] = {
            "answer": f"a bare fact {i}",
            "provenance": "stated",
            "state": "answered",
        }
    # Parentless section-keyed nodes; a couple public.
    overlay["emergent.pub1"] = {
        "prompt": "Hobby", "section": "interests", "level": 1,
        "answer": "rock climbing", "visibility": "public",
    }
    overlay["emergent.priv1"] = {
        "prompt": "Job", "section": "career", "level": 1,
        "answer": "analyst in Lisbon",  # defaults private
    }
    return overlay


def test_minimal_nodes_do_not_blank_the_effective_graph():
    g = pg.effective_graph(_founder_shape(), intent=None)
    # Did NOT raise; every emergent node survived.
    assert "emergent.min0" in g
    m = g["emergent.min0"]
    # Minimal node homed as a renderable loose fact in Little Extras.
    assert m.section == "misc"
    assert m.level == 1
    assert m.answer == "a bare fact 0"
    assert m.prompt  # derived from the answer, never empty


def test_story_renders_his_sections_and_bullets():
    g = pg.effective_graph(_founder_shape(), intent=None)
    t = tree.node_tree(g, surface="story")
    by_section = {s["page_type"]: s["nodes"] for s in t["sections"] if s["nodes"]}
    # His parentless section-keyed nodes render under their sections.
    assert "interests" in by_section
    assert "career" in by_section
    # The minimal nodes render in Little Extras, not lost.
    assert len(by_section.get("misc", [])) == 5


def test_public_profile_shows_exactly_the_public_nodes():
    g = pg.effective_graph(_founder_shape(), intent=None)
    t = tree.node_tree(g, surface="publicProfile")
    texts = [
        n["text"]
        for s in t["sections"]
        for n in s["nodes"]
    ]
    assert "rock climbing" in texts  # the one public node
    assert "analyst in Lisbon" not in texts  # private
    assert "a bare fact 0" not in texts  # minimal → private default


def test_one_unparseable_node_does_not_blank_the_rest():
    overlay = {
        "emergent.ok": {"prompt": "P", "section": "misc", "level": 1,
                        "answer": "kept"},
        # a value that OverlayNode can't even coerce would be skipped, not fatal;
        # simulate with a non-dict (store never writes this, but be defensive).
        "emergent.bad": "not a dict",
    }
    g = pg.effective_graph(overlay, intent=None)
    assert "emergent.ok" in g and g["emergent.ok"].answer == "kept"
