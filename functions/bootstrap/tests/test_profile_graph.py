"""Person-graph data (clickable graph visualization)."""

import profile_graph
from tests.test_profile_bullets import FakeDb, _page


def test_owner_graph_has_person_center_section_and_bullet_nodes():
    db = FakeDb()
    _page(db, "u1", "identity", page_type="identity", visibility="public",
          ai_body="I grew up in Lahore. {{private}}A private thing.{{/private}}")
    g = profile_graph.get_graph(db, "u1")
    assert g["center"]["id"] == "me"
    kinds = {n["kind"] for n in g["nodes"]}
    assert kinds == {"person", "section", "bullet"}
    # section node + two bullet nodes under it, edges person->section->bullets
    sec = next(n for n in g["nodes"] if n["kind"] == "section")
    assert sec["page_type"] == "identity" and sec["label"] == "About Me"
    assert {"from": "me", "to": "sec:identity"} in g["edges"]
    ident = next(s for s in g["sections"] if s["page_type"] == "identity")
    assert ident["public"] == 1 and ident["private"] == 1 and ident["total"] == 2


def test_empty_sections_are_hidden_from_the_graph_view():
    db = FakeDb()
    _page(db, "u1", "identity", page_type="identity", visibility="public",
          ai_body="One public thing.")
    g = profile_graph.get_graph(db, "u1")
    section_pts = {s["page_type"] for s in g["sections"]}
    # only the non-empty section shows (career, taste, etc. are hidden)
    assert section_pts == {"identity"}


def test_public_graph_drops_private_and_ai_only_bullets():
    db = FakeDb()
    _page(db, "u1", "identity", page_type="identity", visibility="public",
          ai_body="Public fact. {{private}}Secret.{{/private}} {{ai_only}}Note.{{/ai_only}}")
    g = profile_graph.public_graph(db, "u1")
    texts = [n["text"] for n in g["nodes"] if n["kind"] == "bullet"]
    assert texts == ["Public fact."]
    ident = next(s for s in g["sections"] if s["page_type"] == "identity")
    assert ident["public"] == 1 and ident["private"] == 0 and ident["ai_only"] == 0


def test_public_graph_of_a_fully_private_section_is_empty():
    db = FakeDb()
    _page(db, "u1", "finances", page_type="finances", visibility="private",
          ai_body="My money situation.")
    g = profile_graph.public_graph(db, "u1")
    assert g["sections"] == []
    assert [n for n in g["nodes"] if n["kind"] != "person"] == []
