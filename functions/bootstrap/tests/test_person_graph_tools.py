"""Tests for the five person-graph tools (Phase 5 — wired into LLM dispatch).

Covers the gate (off by default, present when ``PERSON_GRAPH_TOOLS`` is on, in
both text and voice surfaces) and each bound callable's behaviour against a
Firestore fake, including the error paths the dispatch layer relays.
"""

import dataclasses

import config
import person_graph as pg
import person_graph_store as store
import skills
from config import CONFIG
from skills import person_graph_tools as pgt


# --- a minimal Firestore fake (graph doc only) ----------------------------


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


def _on():
    return dataclasses.replace(CONFIG, person_graph_tools=True)


# --- the gate --------------------------------------------------------------


def test_tools_absent_by_default(monkeypatch):
    monkeypatch.setattr(config, "CONFIG", dataclasses.replace(CONFIG, person_graph_tools=False))
    names = {d["name"] for d in skills.session_tool_declarations()}
    assert not (pgt.SKILL_NAMES & names)
    fns = skills.make_session_tool_fns(FakeDb(), "u1")
    assert not (pgt.SKILL_NAMES & set(fns))


def test_tools_present_when_flag_on_both_surfaces(monkeypatch):
    monkeypatch.setattr(config, "CONFIG", _on())
    names = {d["name"] for d in skills.session_tool_declarations()}
    assert pgt.SKILL_NAMES <= names
    fns = skills.make_session_tool_fns(FakeDb(), "u1")
    assert pgt.SKILL_NAMES <= set(fns)
    # declarations are well formed
    for d in (s.declaration for s in pgt.SKILLS):
        assert d["name"] and d["description"]
        assert d["parameters"]["type"] == "object"


# --- each tool's behaviour -------------------------------------------------


def _seed_answerable_id():
    # any real seed node id works; pick the first level-2 one deterministically
    return sorted(pg.seed())[0]


def test_set_answer_records_and_rejects_unknown():
    db = FakeDb()
    nid = _seed_answerable_id()
    ok = pgt._bind_set_answer(db, "u1")(nid, "Never")
    assert ok == f"recorded answer for {nid}"
    assert store.load_overlay(db, "u1")[nid]["answer"] == "Never"
    bad = pgt._bind_set_answer(db, "u1")("not_a_real_node", "x")
    assert bad.startswith("error:")


def test_set_weight_validates_range():
    db = FakeDb()
    nid = _seed_answerable_id()
    assert pgt._bind_set_weight(db, "u1")(nid, 4).startswith("set weight")
    assert store.load_overlay(db, "u1")[nid]["weight"] == 4.0
    assert pgt._bind_set_weight(db, "u1")(nid, 9).startswith("error:")
    assert pgt._bind_set_weight(db, "u1")(nid, "hi").startswith("error:")


def test_set_visibility():
    db = FakeDb()
    nid = _seed_answerable_id()
    assert pgt._bind_set_visibility(db, "u1")(nid, "public").startswith("set ")
    assert store.load_overlay(db, "u1")[nid]["visibility"] == "public"
    assert pgt._bind_set_visibility(db, "u1")(nid, "nonsense").startswith("error:")


def test_add_node_emergent_under_parent():
    db = FakeDb()
    parent = _seed_answerable_id()
    out = pgt._bind_add_node(db, "u1")(parent, "favourite trail", answer="Mission Peak")
    assert out.startswith("added node ")
    nid = out.split("added node ", 1)[1].strip()
    node = store.load_overlay(db, "u1")[nid]
    assert node["parent"] == parent
    assert node["answer"] == "Mission Peak"
    # bad parent rejected
    assert pgt._bind_add_node(db, "u1")("ghost", "x").startswith("error:")


def test_query_nodes_serialises_and_filters():
    db = FakeDb()
    nid = _seed_answerable_id()
    section = pg.seed_node(nid).section
    pgt._bind_set_answer(db, "u1")(nid, "Never")
    out = pgt._bind_query_nodes(db, "u1")(section=section)
    assert nid in out
    assert "Never" in out  # the answered node shows its answer
    # a nonsense section yields nothing matching, not an error
    empty = pgt._bind_query_nodes(db, "u1")(section="no_such_section")
    assert empty == "no matching nodes"
