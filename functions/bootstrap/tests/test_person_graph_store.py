"""Tests for the person-graph store + the five write tools + registry (Phase 2)."""

import pytest

import person_graph_store as store
from person_graph import NodeState, Provenance, Visibility


# --- a minimal Firestore fake (collection/document/get/set) ----------------


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _DocRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def collection(self, name):
        return _CollRef(self._st, self._key + (name,))

    def get(self):
        return _Snap(self._st.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._st.docs.get(self._key) or {}) if merge else {}
        cur.update(payload)
        self._st.docs[self._key] = cur


class _CollRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def document(self, name):
        return _DocRef(self._st, self._key + (name,))


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


def _profile(uid, intent="long_term"):
    return {("users", uid, "profile", "main"): {"relationship_intent": intent}}


# --- set_answer ------------------------------------------------------------


def test_set_answer_records_and_answers():
    db = FakeDb(_profile("u1"))
    store.set_answer(db, "u1", "date_of_birth", "1994-02-02")
    g = store.effective(db, "u1")
    n = g["date_of_birth"]
    assert n.answer == "1994-02-02"
    assert n.state is NodeState.ANSWERED
    assert n.provenance is Provenance.STATED


def test_set_answer_retires_old_answer_to_history():
    db = FakeDb(_profile("u1"))
    store.set_answer(db, "u1", "procreation_intent", "No kids")
    store.set_answer(db, "u1", "procreation_intent", "Want kids")
    g = store.effective(db, "u1")
    n = g["procreation_intent"]
    assert n.answer == "Want kids"  # live answer is the new one
    assert len(n.history) == 1
    assert n.history[0].answer == "No kids"  # old one retired, never lost


def test_set_answer_rejects_unknown_node():
    db = FakeDb(_profile("u1"))
    with pytest.raises(ValueError):
        store.set_answer(db, "u1", "not_a_real_node", "x")


# --- set_weight / set_visibility -------------------------------------------


def test_set_weight_and_visibility_override_defaults():
    db = FakeDb(_profile("u1"))
    store.set_weight(db, "u1", "taste_music", 0.95)
    store.set_visibility(db, "u1", "taste_music", Visibility.PRIVATE)
    n = store.effective(db, "u1")["taste_music"]
    assert n.weight == 0.95
    assert n.visibility is Visibility.PRIVATE


def test_set_visibility_rejects_bad_value():
    db = FakeDb(_profile("u1"))
    with pytest.raises(ValueError):
        store.set_visibility(db, "u1", "taste_music", "secret")


# --- add_node (emergent) ---------------------------------------------------


def test_add_node_creates_emergent_at_parent_level_plus_one():
    db = FakeDb(_profile("u1"))
    nid = store.add_node(
        db, "u1", "taste_music", "Collects vintage synths", answer="Owns a Juno-106"
    )
    n = store.effective(db, "u1")[nid]
    assert n.emergent is True
    assert n.section == "taste"  # inherits parent's home
    parent_level = store.effective(db, "u1")["taste_music"].level
    assert n.level == parent_level + 1
    assert n.visibility is Visibility.PRIVATE  # emergent default private
    assert n.answer == "Owns a Juno-106"
    assert n.state is NodeState.ANSWERED


def test_add_node_can_nest_under_an_emergent_parent():
    db = FakeDb(_profile("u1"))
    p = store.add_node(db, "u1", "taste_music", "Synths")
    c = store.add_node(db, "u1", p, "Favourite is the Juno-106")
    g = store.effective(db, "u1")
    assert g[c].level == g[p].level + 1
    assert g[c].parent == p


def test_add_node_rejects_unknown_parent():
    db = FakeDb(_profile("u1"))
    with pytest.raises(ValueError):
        store.add_node(db, "u1", "nope", "x")


# --- query_nodes -----------------------------------------------------------


def test_query_nodes_filters_by_section_level_and_state():
    db = FakeDb(_profile("u1"))
    store.set_answer(db, "u1", "date_of_birth", "1994-02-02")

    # one section
    ident = store.query_nodes(db, "u1", section="identity")
    assert ident and all(n.section == "identity" for n in ident)

    # unanswered level-2 nodes only
    open_l2 = store.query_nodes(db, "u1", level=2, state=NodeState.NOT_ASKED)
    assert open_l2 and all(
        n.level == 2 and n.state is NodeState.NOT_ASKED for n in open_l2
    )

    # the answered node is found by state
    answered = store.query_nodes(db, "u1", state=NodeState.ANSWERED)
    assert [n.id for n in answered] == ["date_of_birth"]


def test_query_nodes_min_weight_and_emergent():
    db = FakeDb(_profile("u1"))
    store.set_weight(db, "u1", "taste_music", 0.99)
    nid = store.add_node(db, "u1", "taste_music", "Synths")
    heavy = store.query_nodes(db, "u1", min_weight=0.5)
    assert "taste_music" in {n.id for n in heavy}
    emg = store.query_nodes(db, "u1", emergent=True)
    assert [n.id for n in emg] == [nid]


# --- relationship-type registry --------------------------------------------


def test_registry_has_strict_types_by_default():
    db = FakeDb()
    types = store.get_link_types(db)
    for strict in ("elaborates", "depends_on", "same_topic", "same_person", "contradicts"):
        assert strict in types and types[strict]["strict"] is True


def test_register_free_form_type_is_minted_then_reused():
    db = FakeDb()
    a = store.register_link_type(db, "mentor_of", "A mentored B")
    assert a["strict"] is False
    # reusing the same name returns the canonical definition unchanged (no drift)
    b = store.register_link_type(db, "mentor_of", "something different")
    assert b["definition"] == "A mentored B"
    assert "mentor_of" in store.get_link_types(db)


def test_register_cannot_redefine_a_strict_type():
    db = FakeDb()
    out = store.register_link_type(db, "contradicts", "nope")
    assert out["definition"] == "the two nodes conflict"


def test_new_free_form_type_needs_a_definition():
    db = FakeDb()
    with pytest.raises(ValueError):
        store.register_link_type(db, "brand_new", "")


# --- narrative nodes store the statement once (founder build 2493) ----------


def _find_node(sections: list[dict], node_id: str) -> dict | None:
    """Depth-first search for ``node_id`` across a node_tree's section trees."""
    def walk(nodes):
        for nd in nodes:
            if nd.get("id") == node_id:
                return nd
            hit = walk(nd.get("children") or [])
            if hit is not None:
                return hit
        return None

    for sec in sections:
        hit = walk(sec.get("nodes") or [])
        if hit is not None:
            return hit
    return None


def test_upsert_fact_node_without_label_stores_statement_once():
    # A narrative fact with no distinct label must NOT duplicate its statement
    # into the prompt (header) as well as the answer — the node card printed it
    # twice (founder build 2493). The statement lives in the answer only.
    db = FakeDb(_profile("u1"))
    statement = "I love long hikes in the hills."
    nid = store.upsert_fact_node(
        db, "u1", "emergent.skill.note.1", statement, section="interests"
    )
    n = store.effective(db, "u1")[nid]
    assert n.answer == statement
    assert n.prompt == ""  # not restated into the header

    # The tree builds cleanly with the empty prompt: label blank, text once.
    import person_graph_tree as tree

    sections = tree.node_tree(store.effective(db, "u1"))["sections"]
    node = _find_node(sections, nid)
    assert node is not None
    assert node["label"] == ""
    assert node["text"] == statement


def test_upsert_fact_node_keeps_a_genuinely_distinct_label():
    # A real, different label (not a restatement) is preserved — only an exact
    # normalized match collapses.
    db = FakeDb(_profile("u1"))
    nid = store.upsert_fact_node(
        db, "u1", "emergent.assessment.red", "Tends to over-commit.",
        section="misc", label="Ayma's assessment — Red flags",
    )
    assert store.effective(db, "u1")[nid].prompt == "Ayma's assessment — Red flags"


def test_story_bullet_writer_stores_statement_once():
    # The Your Story editor write-back is the "story writer": its bullets are
    # narrative statements with no separate label, so the prompt is never a
    # restatement of the answer.
    db = FakeDb(_profile("u1"))
    statement = "Grew up by the ocean."
    ids = store.replace_section_bullets(
        db, "u1", "family",
        [{"text": statement, "visibility": "public"}],
    )
    assert len(ids) == 1
    n = store.effective(db, "u1")[ids[0]]
    assert n.answer == statement
    assert n.prompt == ""


# --- NOTE 279 ---------------------------------------------------------------


def _editor_identity_node(text: str, vis: str = "public") -> dict:
    """An ``emergent.editor.identity.*`` overlay node in the shape a header /
    structured-fact import writes it: a public ``narrative`` bullet in
    ``identity`` whose answer is the "Label: value" duplicate of a standard
    fact (mirrors the NOTE 263/275 render fixture)."""
    return {
        "prompt": text, "answer": text, "answer_type": "narrative",
        "section": "identity", "visibility": vis, "state": "answered",
        "provenance": "stated", "level": 2,
    }


def test_note279_defect2_trailing_bracket_marker_round_trips():
    # NOTE 279 defect 2: a bullet whose text ends with a bracket marker (Scout's
    # "[Scout278]") must survive the editor save → edit-view read unchanged — the
    # API neither strips the trailing bracket nor the mid-text "!"/"?" (the drop
    # Scout saw is a device text-read artifact, not a server strip). This pins the
    # round trip so a future text-normalisation never eats the marker.
    import person_graph_source as source

    db = FakeDb(_profile("u1"))
    nid = store.replace_section_bullets(
        db, "u1", "identity",
        [{"text": "I grew up in Lisbon.", "visibility": "public"}],
    )[0]
    marker = "A public fact! Really? [Scout278]"
    store.replace_section_bullets(
        db, "u1", "identity", [{"id": nid, "text": marker, "visibility": "public"}],
    )
    # the raw graph node keeps the whole string
    assert store.effective(db, "u1")[nid].answer == marker
    # and the public-edit view (what the editor re-reads) serves it verbatim
    out = source.story_bullets(db, "u1", public_edit=True)
    texts = [b["text"] for s in out["sections"] for b in s["bullets"]]
    assert marker in texts


def test_note279_defect4_public_edit_save_keeps_hidden_header_duplicates():
    # NOTE 279 defect 4: the public-edit GET (NOTE 275) drops/relocates header-fact
    # editor DUPLICATES ("Age: 29", "Interested in: Women") from the payload, so the
    # client cannot send them back. A public-edit SAVE of the section must NOT read
    # their absence as a user removal and delete them (they are still shown in Your
    # Story) — the server-side node drop Scout saw (196→193) with net-zero edits.
    overlay = {
        "legal_first_name": {"answer": "Daniel Reyes"},
        "date_of_birth": {"answer": "1997-02-10"},
        "gender_identity": {"answer": "Man"},
        "primary_location": {"answer": "Austin, TX, United States"},
        "target_match_genders": {"answer": ["Women"]},
        "emergent.editor.identity.0": _editor_identity_node("Age: 29"),
        "emergent.editor.identity.4": _editor_identity_node("Interested in: Women"),
        "emergent.editor.identity.9": _editor_identity_node(
            "A quiet night in beats a loud bar", "private"
        ),
    }

    def _seed():
        db = FakeDb(_profile("u1"))
        store.replace_overlay(db, "u1", dict(overlay))
        return db

    # The payload the public-edit editor re-sends for identity: only the visible
    # (private narrative) bullet — the two header duplicates were never in the GET.
    payload = [
        {"id": "emergent.editor.identity.9",
         "text": "A quiet night in beats a loud bar", "visibility": "private"},
    ]

    # public-edit save: the hidden duplicates are PROTECTED, not deleted.
    db = _seed()
    store.replace_section_bullets(db, "u1", "identity", payload, public_edit=True)
    kept = {e.get("answer") for n, e in store.load_overlay(db, "u1").items()
            if n.startswith("emergent.editor")}
    assert "Age: 29" in kept
    assert "Interested in: Women" in kept
    assert "A quiet night in beats a loud bar" in kept

    # a FULL Your-Story save (public_edit=False) still deletes an unmatched visible
    # bullet — the delete semantics the owner editor relies on are unchanged.
    db2 = _seed()
    store.replace_section_bullets(db2, "u1", "identity", payload, public_edit=False)
    kept2 = {e.get("answer") for n, e in store.load_overlay(db2, "u1").items()
             if n.startswith("emergent.editor")}
    assert "Age: 29" not in kept2
    assert "Interested in: Women" not in kept2
