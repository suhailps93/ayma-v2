"""Tests for the person-graph renders (Phase 3): story / public / persona."""

import person_graph as pg
import person_graph_render as render
import question_tree
from person_graph import ChildBullet, Visibility, effective_graph


def _graph(overlay, intent="long_term"):
    return effective_graph(overlay, intent=intent)


def _texts(sections, page_type):
    for s in sections:
        if s["page_type"] == page_type:
            return [b["text"] for b in s["bullets"]]
    return []


# --- story render ----------------------------------------------------------


def test_story_shows_public_and_private_not_ayma_only():
    g = _graph(
        {
            "date_of_birth": {"answer": "1994-02-02", "visibility": "public"},
            "financial_security_narrative": {
                "answer": "Security means freedom to me.",
                "visibility": "private",
            },
            "weight": {"answer": "lean build", "visibility": "ayma_only"},
        }
    )
    out = render.story_sections(g)
    secs = out["sections"]
    assert out["visibilities"] == ["public", "private"]
    # every canonical section present (empty ones included for the editor)
    assert {s["page_type"] for s in secs} >= set(question_tree.ordered_page_types())
    ident = _texts(secs, "identity")
    assert any(t.startswith("Age:") for t in ident)  # DOB shows as age
    assert not any("1994-02-02" in t for t in ident)  # raw birthdate never shown
    assert "lean build" not in " ".join(ident)  # ayma_only never in Your Story
    fin = _texts(secs, "finances")
    assert any("freedom" in t for t in fin)  # private shown in Your Story


def test_story_narrative_is_verbatim_structured_is_labelled():
    g = _graph(
        {
            "financial_security_narrative": {"answer": "I sleep better debt-free."},
            "alcohol_consumption": {"answer": "Never"},
        }
    )
    secs = render.story_sections(g)["sections"]
    fin = _texts(secs, "finances")
    assert "I sleep better debt-free." in fin  # narrative verbatim
    life = _texts(secs, "lifestyle")
    assert any(t.startswith("Alcohol") and "Never" in t for t in life)  # labelled


def test_structured_values_render_humanised_not_raw():
    # Scout 2449 blocker 2: DOB rendered as a raw Firestore timestamp and
    # booleans as "true". Dates show a date; booleans show Yes/No.
    g = _graph(
        {
            "date_of_birth": {"answer": "1993-03-05 20:00:00+00:00", "visibility": "private"},
            "smoking_vaping": {"answer": True, "visibility": "private"},
        }
    )
    secs = render.story_sections(g)["sections"]
    ident = _texts(secs, "identity")
    # DOB shows as a plain age number, never the raw timestamp or full date
    assert any(t.startswith("Age:") for t in ident)
    assert not any("20:00:00" in t or "1993-03-05" in t for t in ident)
    life = _texts(secs, "lifestyle")
    assert any(t.endswith(": Yes") for t in life)
    assert not any("true" in t.lower() for t in life)


def test_meta_sentinel_answers_do_not_render():
    # Scout 2449 blocker 3: "skipped" / "addressed" placeholders are not bullets.
    g = _graph(
        {
            "family_of_origin_narrative": {"answer": "skipped", "visibility": "private"},
            "childhood_formative_narrative": {"answer": "addressed", "visibility": "private"},
            "sibling_relationship_narrative": {"answer": "Close with my sister.", "visibility": "private"},
        }
    )
    fam = _texts(render.story_sections(g)["sections"], "family")
    assert "Close with my sister." in fam
    assert not any(t.strip().lower() in ("skipped", "addressed") for t in fam)
    assert not any("skipped" in t.lower() or "addressed" in t.lower() for t in fam)


def test_story_includes_children_as_bullets():
    ov = {
        "taste_music": {
            "answer": "Taylor Swift",
            "visibility": "public",
            "children": [
                {"text": "Seen her live 4 times", "visibility": "public"},
                {"text": "A private note", "visibility": "private"},
            ],
        }
    }
    secs = render.story_sections(_graph(ov))["sections"]
    taste = _texts(secs, "taste")
    assert any("Taylor Swift" in t for t in taste)
    assert "Seen her live 4 times" in taste
    assert "A private note" in taste  # Your Story shows private


# --- public render ---------------------------------------------------------


def test_public_shows_only_public_and_drops_empty_sections():
    g = _graph(
        {
            "date_of_birth": {"answer": "1994-02-02", "visibility": "public"},
            "financial_security_narrative": {
                "answer": "A private money thought.",
                "visibility": "private",
            },
        }
    )
    pub = render.public_sections(g)
    pts = {s["page_type"] for s in pub}
    assert "identity" in pts
    assert "finances" not in pts  # all-private section hidden on public profile
    ident = next(s for s in pub if s["page_type"] == "identity")
    assert any(t.startswith("Age:") for t in ident["bullets"])  # age, not raw DOB
    assert not any("1994-02-02" in t for t in ident["bullets"])


def test_public_child_visibility_is_independent_of_parent():
    ov = {
        "taste_music": {
            "answer": "Taylor Swift",
            "visibility": "public",
            "children": [{"text": "A private note", "visibility": "private"}],
        }
    }
    pub = render.public_sections(_graph(ov))
    taste = next(s for s in pub if s["page_type"] == "taste")
    assert "Taylor Swift" in taste["bullets"]
    assert "A private note" not in taste["bullets"]  # private child hidden publicly


# --- persona prose ---------------------------------------------------------


def test_persona_prose_owner_vs_public_vs_ayma_only():
    g = _graph(
        {
            "date_of_birth": {"answer": "1994-02-02", "visibility": "public"},
            "financial_security_narrative": {
                "answer": "Private money thought.",
                "visibility": "private",
            },
            "weight": {"answer": "lean", "visibility": "ayma_only"},
        }
    )
    owner = render.persona_prose(g)
    public = render.persona_prose(g, public_only=True)
    full = render.persona_prose(g, include_ayma_only=True)

    assert "Private money thought." in owner
    assert "Private money thought." not in public  # viewer persona = public only
    assert "lean" not in owner  # ayma_only excluded from owner persona
    assert "lean" in full  # only Ayma's own grounding sees ayma_only


def test_section_order_preserved_in_renders():
    g = _graph(
        {
            "financial_security_narrative": {"answer": "money", "visibility": "public"},
            "date_of_birth": {"answer": "1994-02-02", "visibility": "public"},
        }
    )
    pub = render.public_sections(g)
    orders = [question_tree.section_order(s["page_type"]) for s in pub]
    assert orders == sorted(orders)  # identity (0) before finances (13)
