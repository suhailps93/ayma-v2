"""Reports-as-nodes — the WEB-SEARCH (deep dive) half (founder Nov 16).

With ``person_graph_reads`` ON the ``deep_dives`` collection is deleted and each
subject's persistent web-search report lives as ONE Ayma-only graph node,
``emergent.webfind.report.<cache_key>``, carrying the whole stored dive doc as
its ``answer``. The report screen (``report_adapters.deep_dive_blocks`` via
``deep_dive.read_dive``) rebuilds from it; disputes/corrections mutate it; flag
OFF is unchanged; any flag-on touch of the deleted collection fails loudly.
"""

import dataclasses

import config
from config import CONFIG

import deep_dive
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


def _digest(name="Jane Doe"):
    return {
        "name": name,
        "is_self": True,
        "summary": "A software engineer in Portland.",
        "confidence": "medium",
        "facts": [
            {"claim": "Works at Acme", "category": "work",
             "source_url": "https://acme.com/team", "confidence": "high", "id": "f1"},
        ],
        "links": [{"url": "https://acme.com/team", "title": "Acme team", "is_them": "likely"}],
        "social_handles": [],
        "web_images": [],
        "caveats": "",
    }


# --- 1. flag ON: a dive is written as a graph node, not the collection ------


def test_store_dive_writes_node_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    deep_dive.store_dive(db, "u1", _digest(), target_uid="", name="Jane Doe")

    # nothing in the deleted deep_dives collection
    assert not any(k[:3] == ("users", "u1", "deep_dives") for k in db.docs)
    overlay = store.load_overlay(db, "u1")
    nid = "emergent.webfind.report.name_jane-doe"
    assert nid in overlay
    node = overlay[nid]
    assert node["answer_type"] == "report_doc"
    assert node["visibility"] == "ayma_only"
    doc = node["answer"]
    assert doc["digest"]["facts"][0]["claim"] == "Works at Acme"
    assert isinstance(doc["created_at"], str) and doc["created_at"]


def test_read_and_cached_dive_from_node_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    deep_dive.store_dive(db, "u1", _digest(), name="Jane Doe")

    got = deep_dive.read_dive(db, "u1", "name_jane-doe")
    assert got is not None and got["digest"]["summary"].startswith("A software")

    # the ISO created_at must parse so cache-age math treats a fresh dive as reusable
    hit = deep_dive.cached_dive(db, "u1", name="Jane Doe")
    assert hit is not None and hit["from_cache"] is True
    assert hit["cached_age_days"] < 1


def test_member_subject_dive_lands_in_subject_graph_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    # a dive on member u2 is stored under u2's own graph, keyed uid_u2
    deep_dive.store_dive(db, "u2", _digest("Bob"), target_uid="u2", name="Bob")
    assert "emergent.webfind.report.uid_u2" in store.load_overlay(db, "u2")
    assert not store.load_overlay(db, "u1")  # nothing in the searcher's graph


# --- 2. flag ON: a dispute round-trips on the node --------------------------


def test_dispute_fact_round_trip_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    deep_dive.store_dive(db, "u1", _digest(), name="Jane Doe")
    res = deep_dive.dispute_fact(db, "u1", "name_jane-doe", "f1")
    assert res is not None
    # the fact is gone from the node's digest and recorded in disputed_facts
    doc = store.report_node_payload(db, "u1", "emergent.webfind.report.name_jane-doe")
    assert doc["digest"]["facts"] == []
    assert doc["disputed_facts"][0]["claim"] == "Works at Acme"


# --- 3. flag ON: loud-fail on the deleted collection ------------------------


def test_cache_ref_raises_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    try:
        deep_dive._cache_ref(db, "u1", "name_jane-doe")
    except RuntimeError as e:
        assert "deep_dives" in str(e)
    else:  # pragma: no cover
        raise AssertionError("expected a loud RuntimeError")


# --- 4. flag ON: the report node never renders as a profile/grounding bullet -


def test_dive_node_does_not_render(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    deep_dive.store_dive(db, "u1", _digest(), name="Jane Doe")
    import person_graph_render as render

    graph = store.effective(db, "u1")
    prose = render.persona_prose(graph, include_ayma_only=True)
    assert "Works at Acme" not in prose
    story = render.story_sections(graph)
    for sec in story["sections"]:
        assert all("Works at Acme" not in b["text"] for b in sec["bullets"])


# --- 5. the report SCREEN rebuilds from the node (the Scout surface) --------


def test_deep_dive_blocks_from_node_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    import report_adapters

    db = FakeDb()
    deep_dive.store_dive(db, "u1", _digest(), name="Jane Doe")
    report, created, updated = report_adapters.deep_dive_blocks(
        db, "u1", "name_jane-doe", viewer_uid="u1"
    )
    assert report is not None
    headings = [s["heading"] for s in report["sections"]]
    assert "Summary" in headings
    all_ids = {b["block_id"] for s in report["sections"] for b in s["blocks"]}
    assert "fact:f1" in all_ids


# --- 6. flag OFF: unchanged — the collection doc is written, no node --------


def test_store_dive_writes_collection_flag_off(monkeypatch):
    _reads_on(monkeypatch, False)
    db = FakeDb()
    deep_dive.store_dive(db, "u1", _digest(), name="Jane Doe")
    assert ("users", "u1", "deep_dives", "name_jane-doe") in db.docs
    assert "emergent.webfind.report.name_jane-doe" not in store.load_overlay(db, "u1")
    got = deep_dive.read_dive(db, "u1", "name_jane-doe")
    assert got is not None and got["digest"]["facts"][0]["claim"] == "Works at Acme"
