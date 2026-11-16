"""Reports-as-nodes (founder Nov 16): the appearance report + web-search report
render ONLY from graph nodes with ``person_graph_reads`` ON — the old
``appearance_reports`` / ``deep_dives`` collections are deleted on staging, and
any flag-on code path that still touches them must fail loudly. Flag OFF is
unchanged (prod still runs the collections until its own cutover).

This module covers the APPEARANCE half (storage round-trip, loud-fail guard,
render exclusion). The web-search half lives in ``test_reports_as_nodes_web.py``.
"""

import dataclasses

import config
from config import CONFIG

import appearance
import appearance_storage
import person_graph as pg
import person_graph_store as store


# --- Firestore fake (tuple-path; graph overlay) ----------------------------


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
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
        return _Snap(self._key[-1], self._st.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._st.docs.get(self._key) or {}) if merge else {}
        cur.update(payload)
        self._st.docs[self._key] = cur

    def delete(self):
        self._st.docs.pop(self._key, None)


class _CollRef:
    def __init__(self, st, key):
        self._st, self._key = st, key

    def document(self, name):
        return _DocRef(self._st, self._key + (name,))

    def limit(self, n):
        return self

    def stream(self):
        depth = len(self._key)
        for key, data in list(self._st.docs.items()):
            if len(key) == depth + 1 and key[:depth] == self._key and data is not None:
                yield _Snap(key[-1], data)


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


def _reads_on(monkeypatch, on=True):
    monkeypatch.setattr(config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=on))


_ATTRS = {
    "record": {
        "hair_color": {
            "value": "brown", "source": "photo", "confidence": "high",
            "photo_ids": ["photos/u1/a.jpg"],
        }
    },
    "summary": "Brown hair, warm complexion.",
    "report_id": "current",
    "photo_count": 1,
    "source_photos": ["photos/u1/a.jpg"],
}
_FACE = {
    "usable": True, "overall_score": 7.5, "verdict": "Strong and striking",
    "features": {}, "quick_facts": [], "strengths": ["defined jawline"],
    "improvements": [], "recommendations": ["try a side part"],
    "source_photos": ["photos/u1/a.jpg"],
}
_BODY = {"status": "needs_body_photo"}


def _persist(db, uid="u1", source="endpoint"):
    return appearance_storage._persist_report(
        db, uid, attributes=_ATTRS, face=_FACE, body=_BODY,
        photo_count=1, source=source,
    )


# --- 1. flag ON: the report is written as a graph node, not a collection ----


def test_persist_writes_graph_node_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    doc = _persist(db)
    assert doc["id"] == "current"  # stored

    # NOTHING landed in the deleted appearance_reports collection.
    assert not any(k[:3] == ("users", "u1", "appearance_reports") for k in db.docs)

    # The report lives as the Ayma-only emergent node.
    overlay = store.load_overlay(db, "u1")
    node = overlay["emergent.appearance.report"]
    assert node["answer_type"] == "report_doc"
    assert node["visibility"] == "ayma_only"
    assert node["provenance"] == "inferred"
    payload = node["answer"]
    assert payload["face"]["overall_score"] == 7.5
    assert payload["attributes"]["summary"].startswith("Brown hair")
    assert payload["score"] == {"value": 7.5, "basis": "face"}
    assert payload["category_status"]["body"] == "skipped"  # placeholder axis
    assert isinstance(payload["created_at"], str) and payload["created_at"]


def test_get_report_rebuilds_from_node_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    _persist(db)
    shaped = appearance.get_report(db, "u1", "current")
    assert shaped is not None
    assert shaped["face"]["verdict"] == "Strong and striking"
    assert shaped["body"] == {"status": "needs_body_photo"}
    assert shaped["attributes"]["record"]["hair_color"]["value"] == "brown"
    assert shaped["score"]["value"] == 7.5
    # created_at (an ISO string on the node) survives _shape's string->None map.
    assert isinstance(shaped["created_at"], str) and shaped["created_at"]


def test_read_report_doc_reads_node_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    _persist(db)
    raw = appearance_storage._read_report_doc(db, "u1")
    assert raw["face"]["overall_score"] == 7.5


def test_get_report_none_when_no_node(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    assert appearance.get_report(db, "u1", "current") is None


# --- 2. flag ON: loud-fail if anything touches the deleted collection -------


def test_report_ref_raises_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    try:
        appearance_storage._report_ref(db, "u1")
    except RuntimeError as e:
        assert "appearance_reports" in str(e)
    else:  # pragma: no cover
        raise AssertionError("expected a loud RuntimeError, got none")


# --- 3. flag ON: the report node never renders as a profile/grounding bullet -


def test_report_node_does_not_render(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    _persist(db)
    import person_graph_render as render

    graph = store.effective(db, "u1")
    rnode = graph["emergent.appearance.report"]
    assert render._is_renderable(rnode) is False
    # even the owner's own Ayma-inclusive persona must not leak the payload text
    prose = render.persona_prose(graph, include_ayma_only=True)
    assert "Strong and striking" not in prose
    assert "brown" not in prose.lower()
    story = render.story_sections(graph)
    for sec in story["sections"]:
        for b in sec["bullets"]:
            assert "overall_score" not in b["text"]


# --- 4. flag OFF: unchanged — the collection doc is written, no node --------


def test_persist_writes_collection_flag_off(monkeypatch):
    _reads_on(monkeypatch, False)
    db = FakeDb()
    doc = _persist(db)
    assert doc["id"] == "current"
    stored = [k for k in db.docs if k[:3] == ("users", "u1", "appearance_reports")]
    assert stored == [("users", "u1", "appearance_reports", "current")]
    # no graph node written on the flag-off path
    assert "emergent.appearance.report" not in store.load_overlay(db, "u1")


def test_get_report_reads_collection_flag_off(monkeypatch):
    _reads_on(monkeypatch, False)
    db = FakeDb()
    _persist(db)
    shaped = appearance.get_report(db, "u1", "current")
    assert shaped is not None
    assert shaped["face"]["overall_score"] == 7.5


# --- 5. the report SCREEN (Living-Report blocks) rebuilds from the node -----


def test_appearance_blocks_from_node_flag_on(monkeypatch):
    """The exact surface Scout retests: ``GET /report/appearance/{uid}`` ->
    ``report_adapters.appearance_blocks`` -> identical block report, sourced
    from the graph node with the collection gone."""
    _reads_on(monkeypatch, True)
    import public_profile
    import report_adapters

    monkeypatch.setattr(public_profile, "_photo_url", lambda p: f"https://img/{p}")
    db = FakeDb()
    _persist(db)

    report, created, _ = report_adapters.appearance_blocks(db, "u1", "current")
    assert report is not None
    headings = [s["heading"] for s in report["sections"]]
    assert headings == ["Attributes", "Face", "Body"]
    all_ids = {b["block_id"] for s in report["sections"] for b in s["blocks"]}
    assert "attr:hair_color" in all_ids           # attribute finding
    assert any(i.startswith("face:") for i in all_ids)  # face axis blocks
    assert created is not None
