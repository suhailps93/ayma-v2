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
    # The About Me (identity) standard fields are the founder order. "Interested
    # in" is NOT here — it is a What-I'm-Looking-For fact (founder build 2509).
    # Group by the seed SECTION, not the within-section order rank.
    def _by_section(section):
        return [
            pg.standard_label(i)
            for i in sorted(pg.STANDARD_FIELDS,
                            key=lambda x: pg.STANDARD_FIELDS[x]["order"])
            if pg.seed_node(i) is not None and pg.seed_node(i).section == section
        ]

    assert _by_section("identity") == ["Name", "Age", "Gender", "Location",
                                       "Ethnic & cultural origin"]
    # What I'm Looking For standard fields, fixed order: Interested in first, then
    # partner age preference (the min/max pair), relocation/travel radius,
    # geographic flexibility (founder builds 2507/2509).
    looking_for = [
        i
        for i in sorted(pg.STANDARD_FIELDS, key=lambda x: pg.STANDARD_FIELDS[x]["order"])
        if pg.seed_node(i) is not None and pg.seed_node(i).section == "looking_for"
    ]
    assert looking_for == ["target_match_genders", "partner_age_min",
                           "partner_age_max", "relocation_radius",
                           "geographic_flexibility"]
    assert pg.standard_label("target_match_genders") == "Interested in"
    assert pg.standard_label("relocation_radius") == "Relocation / travel radius"
    assert pg.standard_label("geographic_flexibility") == "Geographic flexibility"
    assert pg.standard_label("partner_age_min") == "Partner age preference"


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
    # "Interested in" is no longer an About Me field (founder 2509) — it renders
    # under What I'm Looking For, so the identity standard set omits it.
    assert [n["standard_label"] for n in std] == [
        "Name", "Age", "Gender", "Location", "Ethnic & cultural origin",
    ]

    # every restating emergent node is suppressed (no surviving text); the
    # distinct fact survives. The standard rows keep the BARE value as their text
    # (the client prepends the label), so "South Asian" appears once — as the row.
    surviving_ids = {n["id"] for n in ident["nodes"] if n["text"]}
    for dup_id in (
        "emergent.editor.identity.11",  # "Ethnic and cultural origin: South Asian"
        "emergent.editor.identity.4",   # "Age: N"
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


def test_editor_bullet_with_differently_worded_label_restates_standard_fact():
    """NOTE 252 leg 28 (build 2493 FAIL, Daniel fixture): the editor bullet
    "Gender identity: Man" rendered BESIDE the standard Gender row "Man". Its own
    label ("Gender identity") is not the standard field label ("Gender"), so the
    label+value token set ({gender, identity, man}) never equalled the field's
    ({gender, man}) and the bullet survived — the Gender pair Scout saw twice. The
    render must suppress it (its colon tail is the bare value), while a genuinely
    distinct fact in the section survives."""
    overlay = {
        "gender_identity": {"answer": "Man", "state": "answered", "visibility": "public"},
        # editor import bullet whose label differs by a word from the field label
        "emergent.editor.identity.1": {
            "prompt": "Gender identity: Man", "section": "identity", "level": 2,
            "answer_type": "narrative", "answer": "Gender identity: Man",
            "state": "answered", "visibility": "public",
        },
        # a genuinely distinct identity fact must NOT be over-suppressed
        "emergent.story.identity.9": {
            "prompt": "Grounded and reflective", "section": "identity", "level": 2,
            "answer_type": "narrative", "answer": "Grounded and reflective",
            "state": "answered", "visibility": "public",
        },
    }
    g = _graph(overlay)
    t = tree.node_tree(g, surface="story")
    ident = next(s for s in t["sections"] if s["page_type"] == "identity")
    surviving = {n["id"] for n in ident["nodes"] if n["text"]}
    # the standard Gender row stays (bare value); the restating bullet is dropped
    gender_row = next(n for n in ident["nodes"] if n["id"] == "gender_identity")
    assert gender_row["text"] == "Man"
    assert "emergent.editor.identity.1" not in surviving, "Gender restatement not suppressed"
    assert "emergent.story.identity.9" in surviving
    # "Man" is not repeated anywhere in the section
    def _all_texts(nodes):
        for n in nodes:
            if n.get("text"):
                yield n["text"]
            yield from _all_texts(n.get("children", []))
    assert list(_all_texts(ident["nodes"])).count("Gender identity: Man") == 0


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


# --- founder 2509: public-profile header de-dup + "Interested in" placement --


def _public_overlay():
    """A public-profile overlay: name/age/location/gender public (the identity
    header fields + Gender), plus Interested in, plus a name PROSE bullet."""
    return {
        "legal_first_name": {"answer": "Arun", "state": "answered",
                             "visibility": "public"},
        "date_of_birth": {"answer": "1992-03-04", "state": "answered",
                          "visibility": "public"},
        "gender_identity": {"answer": "Man", "state": "answered",
                            "visibility": "public"},
        "primary_location": {"answer": "San Jose", "state": "answered",
                             "visibility": "public"},
        "target_match_genders": {"answer": ["Women"], "state": "answered",
                                 "visibility": "public"},
        # a NAME prose bullet — must be LEFT ALONE (not a standard-field row)
        "emergent.story.identity.name": {
            "prompt": "His full name is Arun Kumar", "section": "identity",
            "level": 2, "answer_type": "narrative",
            "answer": "His full name is Arun Kumar",
            "state": "answered", "visibility": "public",
        },
    }


def test_public_profile_omits_header_fields_from_about_me():
    """Founder build 2509: the public profile's photo header already shows
    name/age/location, so About Me must NOT repeat them as standard rows. Gender
    (not a header field) stays. The name PROSE bullet is untouched."""
    g = _graph(_public_overlay())
    pub = tree.node_tree(g, surface="publicProfile")
    ident = next(s for s in pub["sections"] if s["page_type"] == "identity")
    ids = {n["id"] for n in ident["nodes"]}
    # the three header-equivalent standard rows are gone from About Me
    assert "legal_first_name" not in ids
    assert "date_of_birth" not in ids
    assert "primary_location" not in ids
    # Gender is NOT a header field, so its row stays in About Me
    assert any(n["id"] == "gender_identity" and n["standard"] for n in ident["nodes"])
    # the NAME PROSE bullet is untouched (not a standard row — left alone)
    texts = [n["text"] for n in ident["nodes"] if n["text"]]
    assert "His full name is Arun Kumar" in texts


def test_story_keeps_header_fields_in_about_me():
    """Your Story has no photo header (just a cover), so there is no duplication:
    name/age/location DO render as About Me rows there (founder 2509 scope note —
    the de-dup is public-surface only)."""
    g = _graph(_public_overlay())
    story = tree.node_tree(g, surface="story")
    ident = next(s for s in story["sections"] if s["page_type"] == "identity")
    ids = {n["id"] for n in ident["nodes"]}
    assert "legal_first_name" in ids
    assert "date_of_birth" in ids
    assert "primary_location" in ids


def test_interested_in_renders_under_looking_for_not_about_me():
    """Founder build 2509: "Interested in" (``target_match_genders``) is a
    What-I'm-Looking-For fact, not an About Me one — it renders under the
    looking_for section on BOTH the public profile and Your Story (a section
    assignment, so it moves everywhere), never under identity."""
    g = _graph(_public_overlay())
    for surface in ("publicProfile", "story"):
        t = tree.node_tree(g, surface=surface)
        ident = next((s for s in t["sections"] if s["page_type"] == "identity"), None)
        assert ident is not None
        assert "target_match_genders" not in {n["id"] for n in ident["nodes"]}, surface
        looking = next(s for s in t["sections"] if s["page_type"] == "looking_for")
        row = next(n for n in looking["nodes"] if n["id"] == "target_match_genders")
        assert row["standard"] is True
        assert row["standard_label"] == "Interested in"
        # it leads the Looking-For section (lowest standard rank there)
        std_ids = [n["id"] for n in looking["nodes"] if n["standard"]]
        assert std_ids[0] == "target_match_genders"


# --- NOTE 264: fact-based header/duplicate suppression on the GRAPH-TREE path -
# The app's public profile is rendered by GraphTreeView from
# ``node_tree(surface="publicProfile")``. NOTE 263 fixed the Living-Report render
# path (``person_graph_render.public_sections``), but the id-only drop still lived
# here, so the ``emergent.editor.identity.*`` header / Interested-in DUPLICATES
# leaked into About Me on device (Scout NOTE 264 FAIL, build 2517). These pins put
# the SAME real demo-test1 fixture shape through the tree path.


def _editor_identity_node(text: str) -> dict:
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


def _note264_real_fixture():
    """The EXACT demo-test1 shape (users/demo-test1/graph/main on ayma-staging):
    canonical seed nodes carry only an answer; the leak is the three
    ``emergent.editor.identity.*`` duplicates that actually render in About Me."""
    return _graph(
        {
            "legal_first_name": {"answer": "Daniel Reyes"},
            "date_of_birth": {"answer": "1997-02-10"},
            "gender_identity": {"answer": "Man"},
            "primary_location": {"answer": "Austin, TX, United States"},
            "ethnic_cultural_origin": {"answer": ["Hispanic / Latino"]},
            "target_match_genders": {"answer": ["Women"]},
            "emergent.editor.identity.0": _editor_identity_node("Age: 29"),
            "emergent.editor.identity.1": _editor_identity_node("Gender identity: Man"),
            "emergent.editor.identity.4": _editor_identity_node("Interested in: Women"),
        }
    )


def _section_texts(t, page_type):
    """Every rendered text in a section's node-trees (recursing children), or
    ``None`` when the section is not present on this surface."""
    sec = next((s for s in t["sections"] if s["page_type"] == page_type), None)
    if sec is None:
        return None
    out: list[str] = []

    def walk(nodes):
        for n in nodes:
            if n.get("text"):
                out.append(n["text"])
            walk(n.get("children", []))

    walk(sec["nodes"])
    return out


def test_note264_graphtree_public_drops_editor_identity_header_duplicates():
    # The fail Scout filed on 2517: /profile/graph/tree?surface=publicProfile still
    # showed Age 29 / Austin / "Interested in: Women" in About Me because the
    # id-only drop missed the editor duplicates. The fix routes the same
    # fact-based placement (render._public_fact_placement) through this path.
    g = _note264_real_fixture()
    pub = tree.node_tree(g, surface="publicProfile")
    ident = _section_texts(pub, "identity") or []
    looking = _section_texts(pub, "looking_for")

    # (a) name / age / location never render in About Me (the photo header shows
    # them once) — catches the editor duplicates, not just the canonical ids.
    assert "Daniel Reyes" not in ident
    assert not any(t.startswith("Age:") for t in ident), ident
    assert "Age: 29" not in ident
    assert not any("Austin" in t for t in ident), ident

    # (b) The "Interested in: Women" editor duplicate leaves About Me entirely and
    # the fact renders exactly ONCE under What I'm Looking For — here as the
    # canonical ``target_match_genders`` row (the tree keeps a standard row's label
    # and value apart, so its bullet text is the value "Women"). No duplicate of
    # the fact across the two sections, and nothing Interested-in in About Me.
    assert looking is not None
    women = [t for t in looking if "Women" in t]
    assert len(women) == 1, looking
    assert not any("Women" in t for t in ident), ident
    assert not any("Interested in" in t for t in ident), ident

    # (c) Gender is NOT a photo-header field, so it still renders in About Me
    # exactly once (the stale editor duplicate is dropped; the surviving row is
    # the single source). Removing it would erase gender from the public profile.
    gender_rows = [t for t in ident if "Gender" in t or t == "Man"]
    assert len(gender_rows) == 1, ident


def test_note264_graphtree_story_keeps_header_fields():
    # The suppression is PUBLIC-profile only (it sits under a photo header). Your
    # Story has no photo header, so the header fields MUST still render there.
    g = _note264_real_fixture()
    story = tree.node_tree(g, surface="story")
    ident = next(s for s in story["sections"] if s["page_type"] == "identity")
    ids = {n["id"] for n in ident["nodes"]}
    assert "date_of_birth" in ids
    assert "primary_location" in ids


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


def test_career_dated_entries_render_as_an_editable_timeline_date_ordered():
    """Build 2502: the Career section renders its DATED children as a timeline
    view — each a ``timeline_entry`` visual, ordered by date MOST RECENT FIRST
    (the CV / LinkedIn convention), each editable through the usual node path
    (``editable`` True on the owner story surface, so the tap opens the node
    chat with its controls). Seeded out of date order to prove the ordering."""
    overlay = {
        "emergent.story.career.old": {
            "prompt": "Intern at Acme", "section": "career", "level": 2,
            "answer_type": "narrative", "answer": "Intern at Acme",
            "state": "answered", "visibility": "public",
            "links": [{"target": "x", "type": "same_topic", "dated": "2016-06"}],
        },
        "emergent.story.career.new": {
            "prompt": "Founder at Ayma", "section": "career", "level": 2,
            "answer_type": "narrative", "answer": "Founder at Ayma",
            "state": "answered", "visibility": "public",
            "links": [{"target": "x", "type": "same_topic", "dated": "2024-01"}],
        },
        "emergent.story.career.mid": {
            "prompt": "Senior engineer at Globex", "section": "career", "level": 2,
            "answer_type": "narrative", "answer": "Senior engineer at Globex",
            "state": "answered", "visibility": "public",
            "links": [{"target": "x", "type": "same_topic", "dated": "2020-03"}],
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    career = next(s for s in t["sections"] if s["page_type"] == "career")
    dated = [n for n in career["nodes"] if n["dated"]]
    # every dated career child is a timeline entry, editable, and date-ordered
    # most recent first (2024 → 2020 → 2016)
    assert [n["dated"] for n in dated] == ["2024-01", "2020-03", "2016-06"]
    assert all(n["visual"]["type"] == "timeline_entry" for n in dated)
    assert all(n["editable"] is True for n in dated)


def test_career_without_dates_renders_bullets_not_a_fabricated_timeline():
    """Build 2502: a Career section with NO dated children (the founder's graph
    today — only prose + his LinkedIn URL) renders plain ``gist_row`` bullets,
    never a timeline fabricated from undated prose. The timeline populates ONLY
    once dated role/company nodes exist."""
    overlay = {
        "emergent.story.career.0": {
            "prompt": "I did my BTech in Mahatma Gandhi University",
            "section": "career", "level": 2, "answer_type": "narrative",
            "answer": "I did my BTech in Mahatma Gandhi University.",
            "state": "answered", "visibility": "public",
        },
        "emergent.story.career.1": {
            "prompt": "Works as an autonomous system integration engineer",
            "section": "career", "level": 2, "answer_type": "narrative",
            "answer": "Works as an autonomous system integration engineer.",
            "state": "answered", "visibility": "public",
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    career = next(s for s in t["sections"] if s["page_type"] == "career")
    assert career["nodes"], "undated career section still renders its prose"
    assert all(n["dated"] == "" for n in career["nodes"])
    assert all(n["visual"]["type"] == "gist_row" for n in career["nodes"])
    assert not any(n["visual"]["type"] == "timeline_entry" for n in career["nodes"])


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


def test_read_time_default_prose_interest_node_is_a_gist_row_bullet():
    """REGRESSION (founder build 2495): a plain PROSE interests fact with no
    stored visual derives a ``gist_row`` BULLET — never a chip/card bubble. A
    single prose sentence is not discrete items, so no structure is fabricated
    from it ("I would rather have bullet points")."""
    overlay = {
        "emergent.story.interests.0": {
            "prompt": "I love long trail runs in the hills on weekends",
            "section": "interests", "level": 2,
            "answer_type": "narrative",
            "answer": "I love long trail runs in the hills on weekends",
            "state": "answered", "visibility": "public",
        },
    }
    t = tree.node_tree(_graph(overlay), surface="story")
    node = next(
        n for s in t["sections"] for n in s["nodes"]
        if n["id"] == "emergent.story.interests.0"
    )
    assert node["visual"]["type"] == "gist_row"


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
