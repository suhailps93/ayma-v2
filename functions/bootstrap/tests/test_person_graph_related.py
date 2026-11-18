"""Tests for the RELATED-LINK proposer + model (founder Nov 18).

The LiveKit judge (``gemini.generate_json``) is MOCKED — no live inference. The
candidate finder is controlled per test so the proposer's routing (link vs raise
vs skip), the level-3 rule, and mutuality are tested in isolation.
"""

import dataclasses

import pytest

import config
from config import CONFIG
import gemini
import person_graph as pg
import person_graph_crosscheck as crosscheck
import person_graph_related as related
import person_graph_store as store
from person_graph import Visibility

from test_node_dedupe import UID, FakeDb, _node, _overlay_doc, _profile


def _db(nodes):
    return FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})


def _on(monkeypatch, **flags):
    base = dict(node_related_propose=True, graph_embedding_dedupe=False)
    base.update(flags)
    monkeypatch.setattr(config, "CONFIG", dataclasses.replace(CONFIG, **base))


# Four related, level-3 facts about the same topic (the dog), plus one level-2
# node so the level rule has something to drop.
def _nodes():
    return {
        "n3a": {
            "prompt": "", "section": "misc", "level": 3, "answer_type": "narrative",
            "answer": "Rocky is a golden retriever puppy", "state": "answered",
            "visibility": "private", "provenance": "stated",
        },
        "n3b": {
            "prompt": "", "section": "family", "level": 3, "answer_type": "narrative",
            "answer": "Rocky the golden retriever loves swimming", "state": "answered",
            "visibility": "private", "provenance": "stated",
        },
        "n3c": {
            "prompt": "", "section": "misc", "level": 3, "answer_type": "narrative",
            "answer": "Rocky chewed the golden sofa", "state": "answered",
            "visibility": "private", "provenance": "stated",
        },
        "n3d": {
            "prompt": "", "section": "misc", "level": 3, "answer_type": "narrative",
            "answer": "Rocky is a golden retriever dog", "state": "answered",
            "visibility": "private", "provenance": "stated",
        },
        "n1": {
            "prompt": "", "section": "misc", "level": 1, "answer_type": "narrative",
            "answer": "Rocky the golden retriever is friendly", "state": "answered",
            "visibility": "private", "provenance": "stated",
        },
    }


def _report(*pairs):
    r = crosscheck.CrossCheckReport(node_count=99)
    r.related_pairs = [
        crosscheck.CandidatePair(a, b, crosscheck.RELATED, 0.5, reason)
        for (a, b, reason) in pairs
    ]
    return r


def _judge(monkeypatch, verdicts: dict[tuple[str, str], str]):
    """Mock the LiveKit judge to return a verdict per (a,b) item order."""
    import json

    async def fake(payload, system, **kw):
        items = json.loads(payload)
        out = []
        for it in items:
            # the proposer passes a/b text; map back by index via the stored order
            out.append({"i": it["i"], "verdict": _ORDER[it["i"]]})
        return out

    monkeypatch.setattr(gemini, "generate_json", fake)
    # _ORDER is filled by the test after it knows the candidate ordering.
    return fake


# ---------------------------------------------------------------------------
# model: level rule + mutuality
# ---------------------------------------------------------------------------


def test_level_rule_eligibility():
    # Founder Nov 18 (revised): LEVEL 2 AND UP, both ends.
    assert pg.eligible_for_related_link(2, 2)
    assert pg.eligible_for_related_link(3, 2)
    assert pg.eligible_for_related_link(5, 2)
    # levels 0 and 1 never carry a link, on EITHER end.
    assert not pg.eligible_for_related_link(1, 2)
    assert not pg.eligible_for_related_link(2, 1)
    assert not pg.eligible_for_related_link(1, 1)
    assert not pg.eligible_for_related_link(0, 5)


def test_mutual_related_derives_both_directions():
    # Only A stores the link (B is a seed-like node with no stored link); the
    # derived adjacency still reads B -> A.
    a = _node("a", "misc", 3, answer="x")
    a = a.model_copy(update={"links": [pg.Link(target="b", type="related", label="same dog")]})
    b = _node("b", "family", 3, answer="y")
    graph = {"a": a, "b": b}
    m = pg.mutual_related(graph)
    assert m["a"]["b"] == "same dog"
    assert m["b"]["a"] == "same dog"  # derived reverse direction, same reason


def test_related_link_pairs_from_graph():
    a = _node("a", "misc", 3, answer="x")
    a = a.model_copy(update={"links": [pg.Link(target="b", type="related", label="r")]})
    b = _node("b", "misc", 3, answer="y")
    pairs = crosscheck.related_link_pairs({"a": a, "b": b})
    assert len(pairs) == 1
    assert pairs[0].key() == ("a", "b")
    assert pairs[0].reason == "r"
    assert pairs[0].relation == crosscheck.RELATED


# ---------------------------------------------------------------------------
# proposer: link (confident), raise (uncertain), skip (duplicate), level drop
# ---------------------------------------------------------------------------


_ORDER: dict[int, str] = {}


@pytest.mark.asyncio
async def test_proposer_links_raises_skips_and_drops_by_level(monkeypatch):
    _on(monkeypatch)
    db = _db(_nodes())

    # Candidates: a-b (judge: related -> LINK), a-c (uncertain -> RAISE),
    # a-d (duplicate -> SKIP), a-n1 (touches level-1 -> DROPPED by the rule).
    report = _report(
        ("n3a", "n3b", "both about the dog"),
        ("n3a", "n3c", "maybe the dog"),
        ("n3a", "n3d", "same dog fact"),
        ("n3a", "n1", "friendly dog"),
    )
    monkeypatch.setattr(crosscheck, "candidate_report", lambda db, uid, index: report)

    # Fill the per-candidate verdict order (the proposer enumerates the kept,
    # level-eligible candidates in list order: a-b, a-c, a-d).
    global _ORDER
    _ORDER = {0: "related", 1: "uncertain", 2: "duplicate"}
    _judge(monkeypatch, {})

    rep = await related.sweep_user(db, UID, dry_run=False)

    assert rep.dropped_by_level == 1  # the a-n1 pair (level-1 end)
    assert ("n3a", "n3b", "both about the dog") in rep.linked
    assert len(rep.linked) == 1
    assert ("n3a", "n3c", "maybe the dog") in rep.raised
    assert len(rep.raised) == 1  # duplicate (a-d) is neither linked nor raised

    # The confident link is written MUTUALLY and never changes visibility.
    graph = store.effective(db, UID)
    m = pg.mutual_related(graph)
    assert "n3b" in m.get("n3a", {})
    assert "n3a" in m.get("n3b", {})
    assert graph["n3a"].visibility is Visibility.PRIVATE
    assert graph["n3b"].visibility is Visibility.PRIVATE

    # The uncertain pair is RAISED in chat (the settled pending-dedupe flow),
    # never silently linked.
    pending = store.pending_dedupe(db, UID)
    assert any({p["a"], p["b"]} == {"n3a", "n3c"} for p in pending)
    assert "n3c" not in m.get("n3a", {})  # not linked
    # the duplicate pair is left to the dedupe path — no link to n3d.
    assert "n3d" not in m.get("n3a", {})


@pytest.mark.asyncio
async def test_proposer_dry_run_writes_nothing(monkeypatch):
    _on(monkeypatch)
    db = _db(_nodes())
    report = _report(("n3a", "n3b", "both about the dog"))
    monkeypatch.setattr(crosscheck, "candidate_report", lambda db, uid, index: report)
    global _ORDER
    _ORDER = {0: "related"}
    _judge(monkeypatch, {})

    rep = await related.sweep_user(db, UID, dry_run=True)
    assert rep.linked == [("n3a", "n3b", "both about the dog")]
    # nothing persisted
    graph = store.effective(db, UID)
    assert pg.mutual_related(graph) == {}


@pytest.mark.asyncio
async def test_proposer_flag_off_is_noop(monkeypatch):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, node_related_propose=False)
    )
    db = _db(_nodes())
    rep = await related.sweep_user(db, UID, dry_run=False)
    assert rep.found == 0 and rep.linked == [] and rep.raised == []


@pytest.mark.asyncio
async def test_judge_failure_raises_never_links(monkeypatch):
    _on(monkeypatch)
    db = _db(_nodes())
    report = _report(("n3a", "n3b", "both about the dog"))
    monkeypatch.setattr(crosscheck, "candidate_report", lambda db, uid, index: report)

    async def boom(payload, system, **kw):
        raise RuntimeError("judge down")

    monkeypatch.setattr(gemini, "generate_json", boom)
    rep = await related.sweep_user(db, UID, dry_run=False)
    # a judge failure must RAISE (never silently link).
    assert rep.linked == []
    assert ("n3a", "n3b", "both about the dog") in rep.raised
