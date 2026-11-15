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
