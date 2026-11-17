"""Tests for the node-dedupe index, cross-check, and resolution (founder Nov 17)."""

import dataclasses

import pytest

import config
import person_graph as pg
import person_graph_crosscheck as crosscheck
import person_graph_index as index_mod
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


UID = "u1"


def _node(nid, section, level, *, answer=None, parent=None, answer_type="narrative",
          image_read=None, visibility=Visibility.PRIVATE, emergent=True, prompt=None):
    return pg.GraphNode(
        id=nid, section=section, level=level, weight=0.0,
        prompt=prompt or nid, answer=answer, answer_type=answer_type,
        parent=parent, image_read=image_read, visibility=visibility,
        emergent=emergent,
        state=NodeState.ANSWERED if answer or image_read else NodeState.NOT_ASKED,
    )


# --- index -----------------------------------------------------------------


def test_index_covers_every_kind_and_uses_image_read():
    graph = {
        "emergent.editor.career.0": _node(
            "emergent.editor.career.0", "career", 2, answer="I work at Google as a PM"
        ),
        "emergent.skill.web_findings": _node(
            "emergent.skill.web_findings", "career", 2,
            answer="Works at Google as a product manager", answer_type="narrative"
        ),
        "emergent.image.abc": _node(
            "emergent.image.abc", "misc", 3, answer="https://x/pic.jpg",
            answer_type="image", image_read="A man hiking on a mountain trail",
            parent="emergent.editor.career.0",
        ),
    }
    idx = index_mod.index_from_graph(graph)
    by_id = {e.node_id: e for e in idx}
    # image node indexes its READ text, not the storage URL
    img = by_id["emergent.image.abc"]
    assert img.kind == index_mod.KIND_IMAGE
    assert "hiking" in img.text and "http" not in img.text
    assert "emergent.editor.career.0" in img.ancestors  # parent chain captured
    assert by_id["emergent.skill.web_findings"].kind == index_mod.KIND_GROUNDING


def test_normalize_and_exact_match():
    graph = {
        "a": _node("a", "misc", 2, answer="I love Thai food!"),
        "b": _node("b", "misc", 2, answer="i  love thai food"),
    }
    idx = index_mod.index_from_graph(graph)
    assert index_mod.find_exact_match(idx, "I LOVE thai food") in ("a", "b")
    assert index_mod.find_exact_match(idx, "something else") is None


# --- cross-check -----------------------------------------------------------


def test_exact_duplicate_across_sections_flagged():
    graph = {
        "a": _node("a", "career", 2, answer="I work at Google as a PM"),
        "b": _node("b", "misc", 2, answer="I work at Google as a PM"),
    }
    report = crosscheck.find_candidates(index_mod.index_from_graph(graph))
    assert report.duplicate_pairs
    p = report.duplicate_pairs[0]
    assert p.relation == crosscheck.EXACT
    assert {p.a, p.b} == {"a", "b"}


def test_ancestor_descendant_pair_not_flagged():
    graph = {
        "parent": _node("parent", "career", 2, answer="I work at Google as a PM"),
        "child": _node("child", "career", 3, answer="I work at Google as a PM",
                       parent="parent"),
    }
    report = crosscheck.find_candidates(index_mod.index_from_graph(graph))
    assert not report.duplicate_pairs  # parent/child is structure, not a dup


def test_near_duplicate_and_related():
    graph = {
        "a": _node("a", "career", 2, answer="Senior product manager at Google"),
        "b": _node("b", "misc", 2, answer="Senior product manager at Google Inc"),
        "c": _node("c", "career", 2, answer="Left Google to become a product designer"),
    }
    report = crosscheck.find_candidates(index_mod.index_from_graph(graph))
    dup_keys = {p.key() for p in report.duplicate_pairs}
    assert ("a", "b") in dup_keys  # near-duplicate
    # a/c share the entities 'google' + 'product' -> related, NOT a duplicate
    rel_keys = {p.key() for p in report.related_pairs}
    assert ("a", "c") in rel_keys
    assert ("a", "c") not in dup_keys


def test_duplicate_groups_connected_components():
    graph = {
        "a": _node("a", "career", 2, answer="I work at Google as a PM"),
        "b": _node("b", "misc", 2, answer="I work at Google as a PM"),
        "c": _node("c", "hobbies", 2, answer="I work at Google as a PM"),
    }
    report = crosscheck.find_candidates(index_mod.index_from_graph(graph))
    groups = report.duplicate_groups()
    assert len(groups) == 1 and set(groups[0]) == {"a", "b", "c"}


# --- resolution: merge -----------------------------------------------------


def _profile(uid, intent="long_term"):
    return {("users", uid, "profile", "main"): {"relationship_intent": intent}}


def _overlay_doc(uid, nodes):
    return {("users", uid, "graph", "main"): {"nodes": nodes}}


def test_merge_folds_answer_rehomes_children_and_deletes():
    nodes = {
        "survivor": {
            "prompt": "job", "section": "career", "level": 2,
            "answer_type": "narrative", "answer": "PM at Google",
            "state": "answered", "visibility": "private", "provenance": "stated",
        },
        "dup": {
            "prompt": "job", "section": "misc", "level": 2,
            "answer_type": "narrative", "answer": "Product manager at Google",
            "state": "answered", "visibility": "private", "provenance": "inferred",
        },
        "grandchild": {
            "prompt": "detail", "section": "misc", "level": 3,
            "answer_type": "narrative", "answer": "since 2020",
            "parent": "dup", "state": "answered", "visibility": "private",
            "provenance": "stated",
        },
    }
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})
    res = store.merge_nodes(db, UID, "survivor", "dup")
    assert res["removed"] == "dup" and res["rehomed_children"] == 1
    overlay = store.load_overlay(db, UID)
    assert "dup" not in overlay
    assert overlay["grandchild"]["parent"] == "survivor"  # rehomed
    # the duplicate's answer is retired to the survivor's history, never dropped
    hist = overlay["survivor"].get("history") or []
    assert any(h.get("answer") == "Product manager at Google" for h in hist)


def test_merge_refuses_seed_node_as_duplicate():
    seed_id = next(iter(pg.seed().keys()))
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, {
        "e": {"prompt": "x", "section": "misc", "level": 2,
              "answer_type": "narrative", "answer": "x", "state": "answered",
              "visibility": "private", "provenance": "stated"},
    })})
    with pytest.raises(ValueError):
        store.merge_nodes(db, UID, "e", seed_id)


# --- resolution: link + keep ----------------------------------------------


def test_link_related_adds_two_way_related_links():
    nodes = {
        "a": {"prompt": "a", "section": "career", "level": 2,
              "answer_type": "narrative", "answer": "PM at Google",
              "state": "answered", "visibility": "private", "provenance": "stated"},
        "b": {"prompt": "b", "section": "hobbies", "level": 2,
              "answer_type": "narrative", "answer": "climb at Google gym",
              "state": "answered", "visibility": "private", "provenance": "stated"},
    }
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})
    assert store.link_related(db, UID, "a", "b", label="both about Google") is True
    overlay = store.load_overlay(db, UID)
    a_links = overlay["a"]["links"]
    b_links = overlay["b"]["links"]
    assert any(l["target"] == "b" and l["type"] == "related" for l in a_links)
    assert any(l["target"] == "a" and l["type"] == "related" for l in b_links)
    # idempotent
    assert store.link_related(db, UID, "a", "b") is False


def test_dedupe_dismiss_roundtrip():
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, {})})
    store.dedupe_dismiss(db, UID, "b", "a")
    assert ("a", "b") in store.dedupe_dismissed(db, UID)  # stored sorted


def test_dismissal_survives_overlay_replace():
    # merge_nodes / delete_nodes rewrite the overlay doc whole (merge=False); a
    # "keep both" decision must not be wiped by a later graph write.
    nodes = {
        "a": {"prompt": "a", "section": "misc", "level": 2, "answer_type": "narrative",
              "answer": "x", "state": "answered", "visibility": "private",
              "provenance": "stated"},
        "b": {"prompt": "b", "section": "misc", "level": 2, "answer_type": "narrative",
              "answer": "y", "state": "answered", "visibility": "private",
              "provenance": "stated"},
    }
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})
    store.dedupe_dismiss(db, UID, "a", "b")
    store.delete_nodes(db, UID, ["b"])  # rewrites the overlay doc whole
    assert ("a", "b") in store.dedupe_dismissed(db, UID)


# --- write-time prevention -------------------------------------------------


def test_write_time_prevention_collapses_exact_on_flag(monkeypatch):
    nodes = {
        "existing": {"prompt": "x", "section": "misc", "level": 1,
                     "answer_type": "narrative", "answer": "I love Thai food",
                     "state": "answered", "visibility": "private",
                     "provenance": "stated"},
    }
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})
    monkeypatch.setattr(
        config, "CONFIG",
        dataclasses.replace(config.CONFIG, node_dedupe_prevention=True),
    )
    # an exact restatement reuses the existing node instead of minting a new one
    nid = store.add_loose_node(db, UID, "i love thai food!")
    assert nid == "existing"
    assert len(store.load_overlay(db, UID)) == 1


def test_write_time_prevention_off_by_default_creates_node(monkeypatch):
    nodes = {
        "existing": {"prompt": "x", "section": "misc", "level": 1,
                     "answer_type": "narrative", "answer": "I love Thai food",
                     "state": "answered", "visibility": "private",
                     "provenance": "stated"},
    }
    db = FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})
    monkeypatch.setattr(
        config, "CONFIG",
        dataclasses.replace(config.CONFIG, node_dedupe_prevention=False),
    )
    nid = store.add_loose_node(db, UID, "i love thai food!")
    assert nid != "existing"
    assert len(store.load_overlay(db, UID)) == 2
