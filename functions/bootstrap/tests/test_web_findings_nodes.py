"""Web-search findings as PER-ELEMENT graph nodes (founder Nov 18).

A web search lands as ONE source-tagged node per finding (summary sentence,
fact, link, social) — never the single ``emergent.skill.web_findings`` lump — so
tapping a web finding opens THAT finding only. Each node carries its source
(``source_kind="web_search"`` + the web link). Flag OFF (prod) is unchanged: the
``web-findings`` wiki page lump is still written. ``migrate_web_findings``
re-splits an existing lump losslessly from the live stored digest.
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


_DIGEST = {
    "name": "Jordan Lee",
    "confidence": "high",
    "summary": "Jordan is a chef in Austin. They run a supper club.",
    "facts": [
        {"claim": "Head chef at Blue Oak", "category": "work",
         "source_url": "https://blueoak.example/team", "confidence": "confirmed"},
        {"claim": "Lives in Austin, TX", "category": "location",
         "source_url": "https://austin.example/jordan", "confidence": "reported"},
    ],
    "links": [
        {"url": "https://jordanlee.example", "title": "Personal site", "is_them": "yes"},
    ],
    "social_handles": [
        {"url": "https://instagram.com/jordancooks", "handle": "jordancooks",
         "platform": "instagram"},
    ],
}


def _webfind_ids(db, uid="u1"):
    overlay = store.load_overlay(db, uid)
    return {nid for nid in overlay if nid.startswith("emergent.webfind.")
            and not nid.startswith("emergent.webfind.report.")}


# --- 1. flag ON: one source-tagged node per finding, no lump ---------------


def test_save_writes_one_node_per_finding_flag_on(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    skill_memory.save_web_findings(db, "u1", _DIGEST)

    overlay = store.load_overlay(db, "u1")
    # The old single lump node is NOT written.
    assert "emergent.skill.web_findings" not in overlay

    ids = _webfind_ids(db)
    # 2 summary sentences + 2 facts + 1 link + 1 social = 6 distinct nodes.
    assert len([i for i in ids if i.startswith("emergent.webfind.summary.")]) == 2
    assert len([i for i in ids if i.startswith("emergent.webfind.fact.")]) == 2
    assert len([i for i in ids if i.startswith("emergent.webfind.link.")]) == 1
    assert len([i for i in ids if i.startswith("emergent.webfind.social.")]) == 1

    # Every finding node is source-tagged web_search, with its web link.
    fact_nodes = [overlay[i] for i in ids if i.startswith("emergent.webfind.fact.")]
    assert all(n["source_kind"] == "web_search" for n in fact_nodes)
    srcs = {n.get("source_ref") for n in fact_nodes}
    assert "https://blueoak.example/team" in srcs
    assert "https://austin.example/jordan" in srcs
    # The claim text is carried verbatim (nothing fabricated).
    claims = {n["answer"] for n in fact_nodes}
    assert "Head chef at Blue Oak" in claims


def test_finding_nodes_map_to_web_findings_page_type(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    skill_memory.save_web_findings(db, "u1", _DIGEST)
    graph = store.effective(db, "u1")
    for nid in _webfind_ids(db):
        assert render.node_page_type(graph[nid]) == "web_findings"


# --- 2. re-run overwrites (stale cleared), dedupe -------------------------


def test_rerun_clears_stale_findings(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    skill_memory.save_web_findings(db, "u1", _DIGEST)
    first = _webfind_ids(db)

    # A later dive with a DIFFERENT, smaller result: stale nodes are cleared.
    skill_memory.save_web_findings(
        db, "u1",
        {"summary": "Updated.", "facts": [
            {"claim": "Now in Denver", "category": "location",
             "source_url": "https://denver.example"}]},
    )
    second = _webfind_ids(db)
    assert any(i.startswith("emergent.webfind.fact.") for i in second)
    # None of the old facts survive the overwrite.
    old_facts = {i for i in first if i.startswith("emergent.webfind.fact.")}
    assert not (old_facts & second)


def test_identical_facts_deduped(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    skill_memory.save_web_findings(
        db, "u1",
        {"facts": [
            {"claim": "Same claim", "category": "x", "source_url": "https://a"},
            {"claim": "Same claim", "category": "x", "source_url": "https://a"},
        ]},
    )
    assert len([i for i in _webfind_ids(db) if i.startswith("emergent.webfind.fact.")]) == 1


# --- 3. flag OFF (prod): wiki lump unchanged, no nodes --------------------


def test_flag_off_writes_wiki_lump(monkeypatch):
    _reads_on(monkeypatch, False)
    db = FakeDb()
    skill_memory.save_web_findings(db, "u1", _DIGEST)
    assert not _webfind_ids(db)
    assert ("users", "u1", "wiki_pages", "web-findings") in db.docs


# --- 4. migration: lump -> per-element, losslessly ------------------------


def test_migrate_splits_lump_losslessly(monkeypatch):
    _reads_on(monkeypatch, True)
    db = FakeDb()
    # Seed the prior world: the structured dive node + the old lump node.
    store.upsert_report_node(
        db, "u1", "emergent.webfind.report.abc123",
        {"digest": _DIGEST, "name": "Jordan Lee"}, label="web search",
    )
    store.upsert_fact_node(
        db, "u1", "emergent.skill.web_findings", "old lump text",
        section="misc", visibility="private", provenance="inferred",
        source_kind="skill_memory", source_ref="web_findings",
    )

    n = skill_memory.migrate_web_findings(db, "u1")
    assert n == 6  # 2 summary + 2 facts + 1 link + 1 social

    overlay = store.load_overlay(db, "u1")
    assert "emergent.skill.web_findings" not in overlay  # lump gone
    # Nothing lost: every fact claim and the link survive as their own node.
    answers = {
        e.get("answer") for e in overlay.values()
        if isinstance(e, dict) and isinstance(e.get("answer"), str)
    }
    assert "Head chef at Blue Oak" in answers
    assert "Lives in Austin, TX" in answers
    assert any("https://jordanlee.example" in str(a) for a in answers)
