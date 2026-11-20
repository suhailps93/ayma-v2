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


def test_fallback_long_single_sentence_is_returned_in_full_no_ellipsis():
    # REGRESSION (founder Nov 17, Leg 41 "no text should cut off partially"): a
    # long single-sentence bullet (no full stop to split on) is returned IN FULL
    # — never chopped on a word boundary and never ending in an ellipsis. The
    # inline line wraps to its full height; the gist-first design keeps the full
    # prose in the node's `text` for the tap-in detail.
    text = (
        "A sprawling run-on description that just keeps going well past any "
        "reasonable headline length without ever reaching a full stop at all"
    )
    g = node_gist.derive_gist(text)
    assert "…" not in g
    assert g == text  # the whole line, uncut


def test_fallback_long_first_sentence_is_returned_in_full_no_ellipsis():
    # A long FIRST sentence (with later sentences) is still returned whole — the
    # length budget no longer chops it — while the trailing sentences remain in
    # `text` for the tap-in.
    text = (
        "My long-term goal is to build a company that lets small research teams "
        "ship hardware without a factory of their own. I have been at it for "
        "three years."
    )
    g = node_gist.derive_gist(text)
    assert "…" not in g
    assert g == (
        "My long-term goal is to build a company that lets small research teams "
        "ship hardware without a factory of their own"
    )


def test_fallback_collapses_newlines_and_strips_trailing_punctuation():
    assert node_gist.derive_gist("Loves hiking,\n   and climbing.") == "Loves hiking, and climbing"


def test_empty_text_with_no_stored_gist_is_empty():
    assert node_gist.derive_gist("") == ""
    assert node_gist.derive_gist(None) == ""


def test_short_text_is_returned_verbatim_minus_trailing_period():
    assert node_gist.derive_gist("Sam") == "Sam"
    assert node_gist.derive_gist("Brown.") == "Brown"


def test_trailing_bracket_marker_survives_the_first_sentence_gist():
    # NOTE 279 Leg 3 (render drop): a bullet whose prose ends in a sentence and
    # then a terse trailing bracket tag — the tag is appended metadata, not a
    # second sentence, so the first-sentence gist must KEEP it rather than drop
    # it with the tail. (Earlier NOTE 279 only proved the node `text`
    # round-trips; the default render shows this `gist`, so the marker vanished
    # on the profile + Your Story render while the edit field showed it.)
    assert (
        node_gist.derive_gist("I have a deeply introverted nature. [Scout279]")
        == "I have a deeply introverted nature [Scout279]"
    )
    # A bracket tag already inside the first sentence (single run-on line) is
    # kept as-is — never doubled.
    assert (
        node_gist.derive_gist("My introverted nature [Scout279]")
        == "My introverted nature [Scout279]"
    )
    # Multiple trailing tags, and a tag after an exclamation/question headline.
    assert node_gist.derive_gist("Two tags at end. [a][b]") == "Two tags at end [a][b]"
    assert node_gist.derive_gist("A public fact! Really? [z]") == "A public fact! [z]"


def test_mid_sentence_bracket_is_not_treated_as_a_trailing_marker():
    # A bracket that is NOT at the very end is ordinary prose: the first-sentence
    # rule governs it, no marker-preservation special case fires.
    assert node_gist.derive_gist("Ends mid tag [a] and more.") == "Ends mid tag [a] and more"


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


def test_person_graph_tree_long_about_me_bullet_gist_has_no_ellipsis():
    # REGRESSION (Scout Leg 41): an About-Me free-text bullet that is one long
    # run-on line must surface a gist that is the whole line, never chopped with
    # an ellipsis — the exact founder-failing path on the Story surface.
    long_bullet = (
        "I was born in Dubai and moved to San Jose for school and I care a lot "
        "about building things that outlast the people who made them"
    )
    overlay = {
        "emergent.story.identity.7": {
            "prompt": long_bullet, "section": "identity", "level": 2,
            "answer_type": "narrative", "answer": long_bullet,
            "state": "answered", "visibility": "public",
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    ident = next(s for s in t["sections"] if s["page_type"] == "identity")
    node = next(n for n in ident["nodes"] if n["id"] == "emergent.story.identity.7")
    assert "…" not in node["gist"]
    assert node["gist"] == long_bullet


def test_person_graph_tree_bullet_keeps_its_trailing_marker_on_the_render():
    # NOTE 279 Leg 3 (render drop, both profile + Your Story): the node tree is
    # the single payload BOTH the public-profile render and the Your Story render
    # consume (GraphTreeView → NodeVisualiserSection → `displayGist`). A bullet
    # saved with a trailing bracket marker must surface that marker on the served
    # `gist` (the default-rendered line), not only on the full `text`.
    text = "A quiet night in beats a loud bar, I have an introverted nature. [Scout279]"
    overlay = {
        "emergent.story.identity.3": {
            "prompt": text, "section": "identity", "level": 2,
            "answer_type": "narrative", "answer": text,
            "state": "answered", "visibility": "public",
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    ident = next(s for s in t["sections"] if s["page_type"] == "identity")
    node = next(n for n in ident["nodes"] if n["id"] == "emergent.story.identity.3")
    # the rendered line (gist) still ends in the marker ...
    assert node["gist"].endswith("[Scout279]"), node["gist"]
    # ... and the full prose is intact for the tap-in detail.
    assert node["text"] == text


# --- surfaced on the report tree -------------------------------------------


def test_report_tree_text_node_gets_a_derived_gist():
    long = "Strong jawline and symmetric features. The lighting flatters the face."
    sections = [{"heading": "Face", "blocks": [{"type": "text", "text": long}]}]
    out = report_tree._sections_to_tree(sections)
    node = out[0]["nodes"][0]
    assert node["gist"] == "Strong jawline and symmetric features"
    assert node["text"] == long  # full prose kept


def test_report_tree_long_text_block_gist_has_no_ellipsis():
    # REGRESSION (Scout Leg 41): a report section's prose block that is one long
    # run-on line surfaces a gist that is the whole line — never an ellipsis cut
    # (reports are the same affected family as Story).
    long = (
        "The two share a rare combination of steady temperament and ambitious "
        "goals that tends to predict a durable long-term partnership over time"
    )
    sections = [{"heading": "Summary", "blocks": [{"type": "text", "text": long}]}]
    out = report_tree._sections_to_tree(sections)
    node = out[0]["nodes"][0]
    assert "…" not in node["gist"]
    assert node["gist"] == long
    assert node["text"] == long


def test_report_tree_stored_gist_on_a_block_is_preserved():
    sections = [
        {"heading": "Face", "blocks": [{"type": "text", "text": "long prose", "gist": "Kept"}]}
    ]
    out = report_tree._sections_to_tree(sections)
    assert out[0]["nodes"][0]["gist"] == "Kept"
