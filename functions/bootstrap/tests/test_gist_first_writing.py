"""Gist-first writing (less-text-heavy program, Part 3).

Every node-creation path going forward emits a short one-line ``gist`` headline
plus at most a brief detail — never a long third-person essay. These tests drive
each creation path with MOCK inference only (a representative payload stands in
for the json writer's output — no live LLM calls) and assert the stored node
carries a non-empty, bounded ``gist`` and keeps its longer text in ``answer``.

They also pin the founder P0 invariant: adding a gist never changes a node's
visibility — the node's private / public / ayma_only state round-trips unchanged.
"""

import asyncio
import dataclasses

import config
import person_graph as pg
import person_graph_store as store
import skill_memory
from config import CONFIG
from skills import person_graph_tools, remember as remember_skill


# --- minimal Firestore fake (overlay doc + nested subcollections) -----------


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
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def _reads_on(monkeypatch):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=True)
    )


def _is_short(gist: str, limit: int = 110) -> bool:
    return bool(gist) and "\n" not in gist and len(gist) <= limit


# --- 1. conversation-extracted node ----------------------------------------


def test_store_mint_funcs_store_gist_and_keep_visibility():
    """The store mint paths persist gist alongside the answer and never alter
    the node's visibility (founder P0)."""
    db = FakeDb()
    # add_loose_node: a volunteered fact (always private) carries its gist.
    nid = store.add_loose_node(
        db, "u1", "Learned ASL to talk with her deaf grandmother as a kid",
        gist="Learned ASL for her deaf grandmother",
    )
    node = pg.effective_graph(store.load_overlay(db, "u1"))[nid]
    assert node.gist == "Learned ASL for her deaf grandmother"
    assert _is_short(node.gist)
    assert "grandmother" in (node.answer or "")  # the longer detail stays in answer

    # upsert_fact_node: gist is stored and an explicit visibility round-trips.
    store.upsert_fact_node(
        db, "u1", "emergent.test.pub", "A longer prose body about this fact.",
        gist="Short headline", visibility=pg.Visibility.PUBLIC,
    )
    pub = pg.effective_graph(store.load_overlay(db, "u1"))["emergent.test.pub"]
    assert pub.gist == "Short headline"
    assert pub.visibility == pg.Visibility.PUBLIC  # visibility round-trips unchanged


def test_remember_tool_writes_a_gist_first_node(monkeypatch):
    """Ayma's `remember` tool stores the short headline as the node gist, the
    brief detail as the answer — the conversation-extraction path."""
    _reads_on(monkeypatch)
    db = FakeDb()
    fn = remember_skill.SKILL.bind(db, "u1", session_id="s1", turn_index=3, turns=[])
    reply = asyncio.run(
        fn(
            gist="Dreams of opening a ceramics studio",
            highlight="Been throwing pots for 6 years; wants her own studio someday.",
        )
    )
    assert "noted" in reply.lower()
    nodes = list(pg.effective_graph(store.load_overlay(db, "u1")).values())
    hit = [n for n in nodes if n.gist == "Dreams of opening a ceramics studio"]
    assert len(hit) == 1
    n = hit[0]
    assert _is_short(n.gist)
    assert "studio" in (n.answer or "")


def test_pg_add_node_tool_stores_gist():
    """The pg_add_node graph tool forwards its gist headline to the node."""
    db = FakeDb()
    add = person_graph_tools._bind_add_node(db, "u1")
    out = add(
        parent_id="primary_location",
        label="commute",
        gist="Bikes 8 miles to work, rain or shine",
        answer="Rides a fixed-gear year round.",
    )
    nid = out.split()[-1]
    n = pg.effective_graph(store.load_overlay(db, "u1"))[nid]
    assert n.gist == "Bikes 8 miles to work, rain or shine"
    assert _is_short(n.gist)
    assert "fixed-gear" in (n.answer or "")


# --- 2. report node (appearance / face report) ------------------------------


def test_face_report_lands_as_per_element_finding_nodes(monkeypatch):
    """Founder Nov 18: a face report no longer lands as ONE gist-first lump node —
    each strength/improvement/recommendation is its own source-tagged node
    (source_kind="appearance"), so tapping an appearance finding opens that
    finding only. (Full coverage: test_appearance_finding_nodes.py.)"""
    _reads_on(monkeypatch)
    db = FakeDb()
    report = {
        "usable": True,
        "overall_score": 7.5,
        "verdict": "Above average",
        "verdict_note": "Strong jawline, even features, tired under-eyes.",
        "features": [{"name": "symmetry", "score": 8, "note": "balanced"}],
        "strengths": ["clear skin"],
        "improvements": ["sleep"],
        "recommendations": [{"category": "under_eye", "text": "eye cream"}],
        "source_photos": ["photos/u1/face.jpg"],
    }
    skill_memory.save_face_analysis(db, "u1", report)
    overlay = store.load_overlay(db, "u1")
    assert "emergent.skill.face_analysis" not in overlay  # no lump
    finding_ids = [i for i in overlay if i.startswith("emergent.skill.face_analysis.")]
    texts = {overlay[i]["answer"] for i in finding_ids}
    assert {"clear skin", "sleep", "eye cream"} <= texts
    node = overlay[finding_ids[0]]
    assert node["source_kind"] == "appearance"
    assert node["source_ref"] == "photos/u1/face.jpg"
    assert node["visibility"] == pg.Visibility.PRIVATE.value


# --- 3. web-research node (deep-dive findings) ------------------------------


def test_web_findings_lands_as_per_element_nodes(monkeypatch):
    """Founder Nov 18: a web search no longer lands as ONE gist-first lump node —
    each fact/summary sentence is its own source-tagged node, so tapping a web
    finding opens that finding only. (Full coverage: test_web_findings_nodes.py.)"""
    _reads_on(monkeypatch)
    db = FakeDb()
    digest = {
        "name": "Dana Reis",
        "gist": "Product designer in Lisbon, ex-Figma, writes on typography",
        "summary": "Dana is a product designer based in Lisbon.",
        "confidence": "high",
        "facts": [
            {"claim": "Designer at Figma", "category": "work", "confidence": "high",
             "source_url": "https://example.com/figma"}
        ],
        "links": [{"url": "https://example.com/dana", "is_them": "likely"}],
    }
    skill_memory.save_web_findings(db, "u1", digest)
    overlay = store.load_overlay(db, "u1")
    assert "emergent.skill.web_findings" not in overlay  # no lump
    fact_ids = [i for i in overlay if i.startswith("emergent.webfind.fact.")]
    assert fact_ids
    assert overlay[fact_ids[0]]["answer"] == "Designer at Figma"
    assert overlay[fact_ids[0]]["source_kind"] == "web_search"
    assert overlay[fact_ids[0]]["source_ref"] == "https://example.com/figma"


def test_web_findings_summary_sentence_is_a_node(monkeypatch):
    """A sparse digest (summary only) still splits its summary into per-sentence
    nodes rather than a single lump."""
    _reads_on(monkeypatch)
    db = FakeDb()
    digest = {"name": "Sam Okafor", "summary": "Little found.", "confidence": "low"}
    skill_memory.save_web_findings(db, "u1", digest)
    overlay = store.load_overlay(db, "u1")
    assert "emergent.skill.web_findings" not in overlay
    summary_ids = [i for i in overlay if i.startswith("emergent.webfind.summary.")]
    assert summary_ids
    assert overlay[summary_ids[0]]["answer"] == "Little found."


# --- writer-contract guards (the json writers emit a gist field) ------------


def test_deep_dive_digest_schema_requires_a_gist():
    import deep_dive

    props = deep_dive._DIGEST_SCHEMA["properties"]
    assert "gist" in props and props["gist"]["type"] == "string"


# --- write-time VISUAL pick -------------------------------------------------


def test_store_defaults_a_visual_by_section_and_kind_keeping_visibility():
    """Every minted node carries a versioned visual, defaulted by kind/section
    when the writer didn't pick one — and picking it never changes visibility."""
    db = FakeDb()
    # A plain PROSE fact is a gist_row BULLET even in a "list-like" section —
    # prose is never shaped into a chip bubble (founder build 2495). Explicit
    # public visibility still round-trips.
    store.upsert_fact_node(
        db, "u1", "emergent.interest.climbing", "Climbs most weekends.",
        section="interests", visibility=pg.Visibility.PUBLIC,
    )
    n = pg.effective_graph(store.load_overlay(db, "u1"))["emergent.interest.climbing"]
    assert n.visual["type"] == "gist_row" and n.visual["v"] == 1
    assert n.visibility == pg.Visibility.PUBLIC

    # image node -> photo_carousel (by kind), regardless of section.
    store.add_node(
        db, "u1", "primary_location", "a photo",
        answer="https://img/1.jpg", answer_type="image",
    )
    img = [
        v for v in pg.effective_graph(store.load_overlay(db, "u1")).values()
        if v.answer_type == "image"
    ][0]
    assert img.visual["type"] == "photo_carousel"

    # a plain fact in an unlisted section -> gist_row (universal fallback).
    nid = store.add_loose_node(db, "u1", "Left-handed")
    row = pg.effective_graph(store.load_overlay(db, "u1"))[nid]
    assert row.visual["type"] == "gist_row"


def test_pg_add_node_visual_explicit_and_fallback():
    db = FakeDb()
    add = person_graph_tools._bind_add_node(db, "u1")
    career_parent = "career_role_narrative"  # a real node in the career section
    # Ayma names a visual type.
    out = add(
        parent_id=career_parent, label="role", gist="Staff engineer at Acme",
        answer="Since 2021.", visual="timeline_entry",
    )
    nid = out.split()[-1]
    n = pg.effective_graph(store.load_overlay(db, "u1"))[nid]
    assert n.visual["type"] == "timeline_entry"

    # No visual named -> a plain prose write defaults to a gist_row BULLET. A
    # timeline is genuine structure derived only where a real DATE exists (at
    # read time), never fabricated from an undated prose write (founder 2495).
    out2 = add(parent_id=career_parent, label="role2", gist="Intern at Beta")
    n2 = pg.effective_graph(store.load_overlay(db, "u1"))[out2.split()[-1]]
    assert n2.visual["type"] == "gist_row"

    # An unknown visual type falls back to gist_row (reader default).
    out3 = add(parent_id=career_parent, label="role3", gist="x", visual="bogus_type")
    n3 = pg.effective_graph(store.load_overlay(db, "u1"))[out3.split()[-1]]
    assert n3.visual["type"] == "gist_row"


def test_report_and_web_findings_are_per_element_nodes(monkeypatch):
    """Founder Nov 18: appearance and web findings are per-element source-tagged
    nodes, each a plain finding bullet (gist_row), not one card lump."""
    _reads_on(monkeypatch)
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", {
        "usable": True, "overall_score": 7.0, "verdict": "Above average",
        "verdict_note": "Even features.", "strengths": ["even features"],
        "source_photos": ["photos/u1/f.jpg"],
    })
    overlay = store.load_overlay(db, "u1")
    assert "emergent.skill.face_analysis" not in overlay
    face_ids = [i for i in overlay if i.startswith("emergent.skill.face_analysis.")]
    assert face_ids
    graph = pg.effective_graph(store.load_overlay(db, "u1"))
    assert graph[face_ids[0]].visual["type"] == "gist_row"
    assert graph[face_ids[0]].source_kind == "appearance"

    # Web findings are now per-element nodes (founder Nov 18), not one card lump.
    skill_memory.save_web_findings(db, "u1", {
        "name": "Dana", "gist": "Designer in Lisbon", "summary": "Short.",
    })
    overlay = store.load_overlay(db, "u1")
    assert "emergent.skill.web_findings" not in overlay
    web_ids = [i for i in overlay if i.startswith("emergent.webfind.summary.")]
    assert web_ids and overlay[web_ids[0]]["source_kind"] == "web_search"


def test_match_report_schema_requires_a_gist():
    import matching_skill

    schema = matching_skill._response_schema([])
    assert "gist" in schema["properties"]
    assert "gist" in schema["required"]
