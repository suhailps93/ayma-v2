"""Gist-first rendering (less-text-heavy program, Part 1) — the shared gist
derivation and its surfacing on every node tree.

Pins the contract Parts 2/3 depend on: the field is ``gist``; a STORED gist
wins; a node with none gets a GENERALIZABLE fallback (first sentence, else a
word-boundary-trimmed summary); the full prose (``text``) is never dropped.
"""

import node_gist
import person_graph as pg
import person_graph_tree as tree
import report_tree


# --- the shared helper -----------------------------------------------------


def test_stored_gist_wins():
    assert node_gist.derive_gist("some long prose here", stored="Punchy line") == "Punchy line"


def test_fallback_is_the_first_sentence():
    g = node_gist.derive_gist(
        "I grew up in Lisbon. Then I moved to Berlin for work and stayed a decade."
    )
    assert g == "I grew up in Lisbon"


def test_fallback_trims_a_long_single_sentence_on_a_word_boundary():
    text = (
        "A sprawling run-on description that just keeps going well past any "
        "reasonable headline length without ever reaching a full stop at all"
    )
    g = node_gist.derive_gist(text)
    assert len(g) <= node_gist.GIST_MAX + 1  # +1 for the ellipsis char
    assert g.endswith("…")
    assert g[:-1].strip() == g[:-1]  # no trailing space before the ellipsis
    assert text.startswith(g[:-1])  # it is a clean prefix of the prose
    assert " " == text[len(g[:-1])] or text[len(g[:-1])].isalnum() is False


def test_fallback_collapses_newlines_and_strips_trailing_punctuation():
    assert node_gist.derive_gist("Loves hiking,\n   and climbing.") == "Loves hiking, and climbing"


def test_empty_text_with_no_stored_gist_is_empty():
    assert node_gist.derive_gist("") == ""
    assert node_gist.derive_gist(None) == ""


def test_short_text_is_returned_verbatim_minus_trailing_period():
    assert node_gist.derive_gist("Sam") == "Sam"
    assert node_gist.derive_gist("Brown.") == "Brown"


# --- surfaced on the person-graph tree -------------------------------------


def _graph(overlay):
    return pg.effective_graph(overlay, intent="long_term")


def test_person_graph_tree_node_carries_a_derived_gist_and_keeps_full_prose():
    long_text = (
        "I spent my twenties backpacking across South America. It changed how I "
        "see the world and what I want from a partner."
    )
    overlay = {
        "emergent.story.identity.0": {
            "prompt": long_text, "section": "identity", "level": 2,
            "answer_type": "narrative", "answer": long_text,
            "state": "answered", "visibility": "public",
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    ident = next(s for s in t["sections"] if s["page_type"] == "identity")
    node = next(n for n in ident["nodes"] if n["id"] == "emergent.story.identity.0")
    # the gist is the short first-sentence headline ...
    assert node["gist"] == "I spent my twenties backpacking across South America"
    assert node["gist"] != node["text"]
    # ... and the full prose is still present for the tap-in.
    assert node["text"] == long_text


# --- surfaced on the report tree -------------------------------------------


def test_report_tree_text_node_gets_a_derived_gist():
    long = "Strong jawline and symmetric features. The lighting flatters the face."
    sections = [{"heading": "Face", "blocks": [{"type": "text", "text": long}]}]
    out = report_tree._sections_to_tree(sections)
    node = out[0]["nodes"][0]
    assert node["gist"] == "Strong jawline and symmetric features"
    assert node["text"] == long  # full prose kept


def test_report_tree_stored_gist_on_a_block_is_preserved():
    sections = [
        {"heading": "Face", "blocks": [{"type": "text", "text": "long prose", "gist": "Kept"}]}
    ]
    out = report_tree._sections_to_tree(sections)
    assert out[0]["nodes"][0]["gist"] == "Kept"
