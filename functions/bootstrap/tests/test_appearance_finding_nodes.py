"""Appearance findings as PER-ELEMENT graph nodes (founder Nov 18).

A face/body analysis lands as ONE source-tagged node per discrete finding (each
strength, improvement, recommendation) — never the single
``emergent.skill.{face,body}_analysis`` lump — so tapping an appearance finding
opens THAT finding only. Report-level metadata (score/verdict/photos/history)
stays on the structured ``emergent.appearance.report`` node, which the templated
appearance page still renders from. Flag OFF (prod) is unchanged.
``migrate_appearance_findings`` re-splits existing lumps losslessly from that
metadata node.
"""

import dataclasses

import config
from config import CONFIG

import person_graph_render as render
import person_graph_store as store
import skill_memory


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
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=on)
    )


_FACE = {
    "usable": True,
    "overall_score": 7.5,
    "verdict": "Strong and striking",
    "strengths": ["defined jawline", "clear skin"],
    "improvements": ["more sleep"],
    "recommendations": [{"category": "hair", "text": "try a side part"}],
    "source_photos": ["photos/u1/face.jpg"],
}


def _face_ids(db, uid="u1"):
    overlay = store.load_overlay(db, uid)
    return {nid for nid in overlay if nid.startswith("emergent.skill.face_analysis.")}


# --- 1. flag ON: one source-tagged node per finding, no lump ---------------


def test_save_face_writes_one_node_per_finding(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", _FACE)

    overlay = store.load_overlay(db, "u1")
    assert "emergent.skill.face_analysis" not in overlay  # no lump

    ids = _face_ids(db)
    assert len([i for i in ids if ".strength." in i]) == 2
    assert len([i for i in ids if ".improvement." in i]) == 1
    assert len([i for i in ids if ".reco." in i]) == 1

    texts = {overlay[i]["answer"] for i in ids}
    assert {"defined jawline", "clear skin", "more sleep", "try a side part"} == texts
    for i in ids:
        assert overlay[i]["source_kind"] == "appearance"
        assert overlay[i]["source_ref"] == "photos/u1/face.jpg"
        assert overlay[i]["visibility"] == "private"


def test_finding_nodes_map_to_face_analysis_page_type(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", _FACE)
    graph = store.effective(db, "u1")
    for nid in _face_ids(db):
        assert render.node_page_type(graph[nid]) == "face_analysis"


# --- 2. re-run clears stale findings ---------------------------------------


def test_rerun_clears_stale_findings(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", _FACE)
    assert len(_face_ids(db)) == 4

    # A later read with fewer findings: the extras are cleared, not left behind.
    skill_memory.save_face_analysis(db, "u1", {
        "usable": True, "verdict": "Good", "strengths": ["warm smile"],
        "source_photos": ["photos/u1/face2.jpg"],
    })
    overlay = store.load_overlay(db, "u1")
    ids = _face_ids(db)
    assert len(ids) == 1
    assert overlay[next(iter(ids))]["answer"] == "warm smile"


# --- 3. flag OFF (prod): wiki lump unchanged, no finding nodes --------------


def test_flag_off_writes_wiki_lump(monkeypatch):
    _reads_on(monkeypatch, False)
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", _FACE)
    assert not _face_ids(db)
    assert ("users", "u1", "wiki_pages", "face-analysis") in db.docs


# --- 4. migration: lump -> per-element, losslessly, from metadata node ------


def test_migrate_splits_lumps_losslessly(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    # Seed the prior world: the structured appearance metadata node + the lumps.
    store.upsert_report_node(
        db, "u1", "emergent.appearance.report",
        {"face": _FACE, "body": {"status": "needs_body_photo"},
         "score": {"value": 7.5, "basis": "face"}},
        label="appearance report",
    )
    store.upsert_fact_node(
        db, "u1", "emergent.skill.face_analysis", "old face lump",
        section="misc", visibility="private", provenance="inferred",
    )

    n = skill_memory.migrate_appearance_findings(db, "u1")
    assert n == 4  # 2 strengths + 1 improvement + 1 recommendation

    overlay = store.load_overlay(db, "u1")
    assert "emergent.skill.face_analysis" not in overlay  # lump gone
    # The metadata node (score/verdict) is untouched.
    assert overlay["emergent.appearance.report"]["answer"]["score"]["value"] == 7.5
    # Nothing lost: every finding survives as its own node.
    texts = {
        e["answer"] for e in overlay.values()
        if isinstance(e, dict) and isinstance(e.get("answer"), str)
    }
    assert {"defined jawline", "clear skin", "more sleep", "try a side part"} <= texts
