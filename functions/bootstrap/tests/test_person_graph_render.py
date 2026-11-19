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


def test_emergent_bullet_renders_verbatim_not_doubled():
    # a migrated story bullet has prompt == answer; it must render once
    # ("I love hiking."), never "I love hiking.: I love hiking.".
    g = _graph(
        {
            "emergent.x": {
                "prompt": "I love hiking.", "section": "interests", "level": 2,
                "answer": "I love hiking.", "answer_type": "narrative",
                "visibility": "public",
            }
        }
    )
    pub = render.public_sections(g)
    interests = next(s for s in pub if s["page_type"] == "interests")
    assert interests["bullets"] == ["I love hiking."]


def test_cross_section_bullets_deduplicate_to_first_home_section():
    g = _graph(
        {
            "emergent.roots": {
                "prompt": "Born in San Jose.", "section": "family", "level": 2,
                "answer": "Born in San Jose.", "answer_type": "narrative",
                "visibility": "public",
            },
            "emergent.roots_dup": {
                "prompt": "Born in San Jose.", "section": "location", "level": 2,
                "answer": "Born in San Jose.", "answer_type": "narrative",
                "visibility": "public",
            },
        }
    )
    pub = render.public_sections(g)
    all_bullets = [(s["page_type"], b) for s in pub for b in s["bullets"]]
    assert all_bullets == [("family", "Born in San Jose.")]


def test_public_sections_preserves_family_bullets_and_single_copy_bullets():
    # Regression test for NOTE 227: Family public bullets are rendered,
    # cross-section duplicates render once under the primary home, and single-copy
    # bullets in other sections are preserved.
    nodes = {
        # 1 private + 5 public family nodes
        "emergent.fam_priv": {
            "prompt": "Private family fact.", "section": "family", "level": 2,
            "answer": "Private family fact.", "answer_type": "narrative",
            "visibility": "private",
        },
        "emergent.fam_pub1": {
            "prompt": "Talks frequently with parents.", "section": "family", "level": 2,
            "answer": "Talks frequently with parents.", "answer_type": "narrative",
            "visibility": "public",
        },
        "emergent.fam_pub2": {
            "prompt": "Raised in a warm family.", "section": "family", "level": 2,
            "answer": "Raised in a warm family.", "answer_type": "narrative",
            "visibility": "public",
        },
        "emergent.fam_pub3": {
            "prompt": "First to graduate college.", "section": "family", "level": 2,
            "answer": "First to graduate college.", "answer_type": "narrative",
            "visibility": "public",
        },
        "emergent.fam_pub4": {
            "prompt": "Respects family traditions.", "section": "family", "level": 2,
            "answer": "Respects family traditions.", "answer_type": "narrative",
            "visibility": "public",
        },
        "emergent.fam_pub5": {
            "prompt": "Deep connection inspires fatherhood.", "section": "family", "level": 2,
            "answer": "Deep connection inspires fatherhood.", "answer_type": "narrative",
            "visibility": "public",
        },
        # Duplicate of fam_pub2 homed under location
        "emergent.loc_dup": {
            "prompt": "Raised in a warm family.", "section": "location", "level": 2,
            "answer": "Raised in a warm family.", "answer_type": "narrative",
            "visibility": "public",
        },
        # Single-copy bullet under goals
        "emergent.goal1": {
            "prompt": "Working to cultivate physical fitness.", "section": "goals", "level": 2,
            "answer": "Working to cultivate physical fitness.", "answer_type": "narrative",
            "visibility": "public",
        },
    }
    pub = render.public_sections(_graph(nodes))
    fam_section = next((s for s in pub if s["page_type"] == "family"), None)
    assert fam_section is not None
    assert len(fam_section["bullets"]) == 5
    assert fam_section["bullets"] == [
        "Talks frequently with parents.",
        "Raised in a warm family.",
        "First to graduate college.",
        "Respects family traditions.",
        "Deep connection inspires fatherhood.",
    ]
    goals_section = next((s for s in pub if s["page_type"] == "goals"), None)
    assert goals_section is not None
    assert goals_section["bullets"] == ["Working to cultivate physical fitness."]
    # The duplicate in location was dropped (and since location has no other bullets, no location section)
    assert not any(s["page_type"] == "location" for s in pub)


def test_no_visibility_node_defaults_private_in_render():
    # Scout live finding: overlay nodes with NO visibility field were rendering
    # public. A no-visibility, non-allow-list node must not appear publicly.
    g = _graph({"childhood_hardship_narrative": {"answer": "A hard year."}})
    pub = render.public_sections(g)
    assert not any("hard year" in b for s in pub for b in s["bullets"])
    # but it IS in the owner's Your Story (private shown there)
    secs = render.story_sections(g)["sections"]
    fam = _texts(secs, "family")
    assert "A hard year." in fam


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
            # gender_identity is an identity field the photo header does NOT show,
            # so it keeps the identity section present on the public profile; the
            # header fields (age/name/location) are suppressed there (NOTE 261).
            "gender_identity": {"answer": "Female", "visibility": "public"},
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
    # date_of_birth is a header field — suppressed on the public profile (shown
    # once, in the photo header), so no age/DOB bullet appears in About Me.
    assert not any(t.startswith("Age:") for t in ident["bullets"])
    assert not any("1994-02-02" in t for t in ident["bullets"])


def _editor_identity(idx: str, text: str) -> dict:
    """An ``emergent.editor.identity.<idx>`` overlay node in the EXACT shape a
    header/structured-fact import writes it (verified live against demo-test1 on
    ayma-staging, NOTE 263): a public ``narrative`` bullet in the ``identity``
    section whose prompt/answer is the "Label: value" text — a plain duplicate of
    a standard fact, carrying no link back to the fact it restates."""
    return {
        "prompt": text,
        "answer": text,
        "answer_type": "narrative",
        "section": "identity",
        "visibility": "public",
        "state": "answered",
        "provenance": "stated",
        "level": 2,
    }


def test_note263_editor_identity_duplicates_drop_and_relocate_real_fixture():
    # NOTE 263 (build 2515, verified against the LIVE staging deploy, server-side
    # — story_public computes from the graph, no cache): the batch-2515 id-based
    # drop (``n.id in HEADER_FIELD_IDS``) never matched the bullets that actually
    # render in About Me — those are ``emergent.editor.identity.*`` DUPLICATES
    # (Age / Gender / Interested-in). The canonical seed nodes carry only an answer
    # in the overlay (section/visibility come from the seed); the duplicates are
    # the leak. This is the EXACT demo-test1 shape pulled from
    # users/demo-test1/graph/main on ayma-staging, through the render path Scout
    # sees: report_adapters._public_bullet_sections ->
    # public_profile.public_bullet_sections -> render.public_sections(graph).
    g = _graph(
        {
            # Canonical seed nodes — overlay carries only the answer, exactly as
            # stored (no section/visibility: those resolve from the seed).
            "legal_first_name": {"answer": "Daniel Reyes"},
            "date_of_birth": {"answer": "1997-02-10"},
            "gender_identity": {"answer": "Man"},
            "primary_location": {"answer": "Austin, TX, United States"},
            "ethnic_cultural_origin": {"answer": ["Hispanic / Latino"]},
            "target_match_genders": {"answer": ["Women"]},
            # The duplicates that actually render in About Me on the live profile.
            "emergent.editor.identity.0": _editor_identity("0", "Age: 29"),
            "emergent.editor.identity.1": _editor_identity(
                "1", "Gender identity: Man"
            ),
            "emergent.editor.identity.4": _editor_identity(
                "4", "Interested in: Women"
            ),
        }
    )
    pub = render.public_sections(g)
    ident = next(s["bullets"] for s in pub if s["page_type"] == "identity")
    looking = next(
        (s["bullets"] for s in pub if s["page_type"] == "looking_for"), None
    )

    # (a) name / age / location do NOT appear in About Me — the photo header shows
    # them once. Catches BOTH the canonical seed node AND its editor duplicate.
    assert "Daniel Reyes" not in ident
    assert not any(t.startswith("Age:") for t in ident)
    assert "Age: 29" not in ident
    assert not any("Austin" in t for t in ident)

    # (b) "What I am Looking For" EXISTS and contains "Interested in …" — the
    # mis-sectioned identity duplicate is relocated to looking_for, so the section
    # appears and its bullet is present.
    assert looking is not None
    interested = [t for t in looking if t.startswith("Interested in:")]
    assert len(interested) == 1
    assert "Women" in interested[0]

    # (c) "Interested in" does NOT remain in About Me / identity.
    assert not any("Interested in" in t for t in ident)

    # Gender is NOT a photo-header field (the header shows only name/age/location,
    # and the client never reads the top-level `gender` payload field), so Gender
    # MUST still render in About Me — exactly once, from the canonical node, with
    # the stale editor duplicate dropped. Removing it would erase gender from the
    # public profile entirely (NOTE 263 render analysis).
    gender_rows = [t for t in ident if "Gender" in t or t == "Man"]
    assert len(gender_rows) == 1


def test_note263_interested_in_relocates_even_when_canonical_is_private():
    # The relocation must materialise What I'm Looking For even when the section's
    # own canonical bullets are private: the editor-identity "Interested in" is the
    # only public looking_for bullet and still surfaces there, out of About Me.
    g = _graph(
        {
            "gender_identity": {"answer": "Man", "visibility": "public"},
            # Canonical target_match_genders private -> contributes no public
            # bullet on its own; partner-age etc. are private seed defaults.
            "target_match_genders": {"answer": ["Women"], "visibility": "private"},
            "emergent.editor.identity.4": _editor_identity(
                "4", "Interested in: Women"
            ),
        }
    )
    pub = render.public_sections(g)
    ident = next(s["bullets"] for s in pub if s["page_type"] == "identity")
    looking = next(
        (s["bullets"] for s in pub if s["page_type"] == "looking_for"), None
    )
    assert looking is not None
    assert any(t.startswith("Interested in:") for t in looking)
    assert not any("Interested in" in t for t in ident)


def test_note261_your_story_keeps_header_rows_no_photo_header():
    # The suppression is PUBLIC-profile only (it sits under a photo header). Your
    # Story has no photo header, so the same header fields MUST still render there
    # (f41191d2 / NOTE 261: a render-placement rule, not a data change).
    g = _graph(
        {
            "legal_first_name": {"answer": "Sam", "visibility": "public"},
            "date_of_birth": {"answer": "1996-01-01", "visibility": "public"},
            "primary_location": {"answer": "Austin", "visibility": "public"},
        }
    )
    ident = _texts(render.story_sections(g)["sections"], "identity")
    assert "Sam" in ident
    assert any(t.startswith("Age:") for t in ident)
    assert any("Austin" in t for t in ident)


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
