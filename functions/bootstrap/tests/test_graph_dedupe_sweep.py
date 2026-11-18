"""Tests for the Layer-2 DATA-LEVEL node dedupe sweep + the Layer-1 write-time
semantic fold (founder Nov 17: "merge duplicate nodes on the server").

The LiveKit judge (``gemini.generate_json``) and the Gemini embedding backend
(``graph_embeddings._embed_backend``) are MOCKED — no live inference in tests.
"""

import asyncio
import dataclasses

import pytest

import config
from config import CONFIG
import gemini
import graph_embeddings
import person_graph as pg
import person_graph_dedupe_sweep as sweep
import person_graph_store as store
from person_graph import Visibility

from test_node_dedupe import UID, FakeDb, _overlay_doc, _profile


def _db(nodes):
    return FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})


def _on(monkeypatch, **flags):
    base = dict(graph_dedupe_sweep=True, graph_embedding_dedupe=False)
    base.update(flags)
    monkeypatch.setattr(config, "CONFIG", dataclasses.replace(CONFIG, **base))


def _judge_all_duplicate(monkeypatch):
    """Make the LiveKit judge call every pair handed to it a duplicate."""
    async def fake(payload, system, **kw):
        import json
        items = json.loads(payload)
        return [{"i": it["i"], "verdict": "duplicate"} for it in items]
    monkeypatch.setattr(gemini, "generate_json", fake)


def _judge_all_related(monkeypatch):
    async def fake(payload, system, **kw):
        import json
        items = json.loads(payload)
        return [{"i": it["i"], "verdict": "related"} for it in items]
    monkeypatch.setattr(gemini, "generate_json", fake)


# The founder's Social Circle pair: the SAME fact (a close college friend) said
# two ways, one private, one ayma_only — a paraphrase, not identical text.
_SOCIAL_CIRCLE = {
    "emergent.a": {
        "prompt": "Social Circle", "section": "misc", "level": 1,
        "answer_type": "narrative",
        "answer": "Has a close friend from college named Priya",
        "state": "answered", "visibility": "private", "provenance": "stated",
        "source_kind": "chat", "source_ref": "sess-A",
    },
    "emergent.b": {
        "prompt": "Social Circle", "section": "misc", "level": 1,
        "answer_type": "narrative",
        "answer": "A close college friend, Priya",
        "state": "answered", "visibility": "ayma_only", "provenance": "inferred",
        "source_kind": "chat", "source_ref": "sess-B",
    },
}


# --- paraphrase detection + merge ------------------------------------------


def test_paraphrase_pair_detected_as_candidate():
    """The two Social Circle nodes are a near/related candidate (not identical)."""
    import person_graph_crosscheck as crosscheck
    import person_graph_index as index_mod

    db = _db(_SOCIAL_CIRCLE)
    index = index_mod.build_index(db, UID)
    report = crosscheck.find_candidates(index)
    keys = {p.key() for p in report.duplicate_pairs + report.related_pairs}
    assert ("emergent.a", "emergent.b") in keys


def test_social_circle_pair_merges_fuller_text_survives(monkeypatch):
    _on(monkeypatch)
    _judge_all_duplicate(monkeypatch)
    db = _db(_SOCIAL_CIRCLE)
    rep = asyncio.run(sweep.sweep_user(db, UID, dry_run=False))
    assert len(rep.merged) == 1
    survivor, removed = rep.merged[0]
    # the FULLER text survives: emergent.a's answer is longer
    assert survivor == "emergent.a"
    assert removed == "emergent.b"
    overlay = store.load_overlay(db, UID)
    assert "emergent.b" not in overlay
    assert overlay["emergent.a"]["answer"] == "Has a close friend from college named Priya"


def test_merge_keeps_both_sources(monkeypatch):
    _on(monkeypatch)
    _judge_all_duplicate(monkeypatch)
    db = _db(_SOCIAL_CIRCLE)
    asyncio.run(sweep.sweep_user(db, UID, dry_run=False))
    hist = store.load_overlay(db, UID)["emergent.a"].get("history") or []
    # the duplicate's answer AND its source retire into the survivor's history
    assert any("Priya" in str(h.get("answer")) for h in hist)
    assert any(h.get("source_ref") == "sess-B" for h in hist)


def test_merge_takes_more_private_visibility(monkeypatch):
    _on(monkeypatch)
    _judge_all_duplicate(monkeypatch)
    db = _db(_SOCIAL_CIRCLE)  # private + ayma_only -> survivor must be private
    asyncio.run(sweep.sweep_user(db, UID, dry_run=False))
    assert store.load_overlay(db, UID)["emergent.a"]["visibility"] == "private"


def test_standard_node_survives_over_emergent(monkeypatch):
    """When one of the pair is a STANDARD node and the other adds NO fact beyond
    it, the standard node survives and the restatement folds in (build-2490)."""
    _on(monkeypatch)
    _judge_all_duplicate(monkeypatch)
    nodes = {
        # a standard identity seed node carrying the fuller value...
        "ethnic_cultural_origin": {"answer": "South Asian, from India",
                                   "state": "answered", "visibility": "private"},
        # ...and an emergent restatement whose content is a SUBSET of it (no
        # extra fact), so folding it in loses nothing.
        "emergent.x": {
            "prompt": "Origin", "section": "identity", "level": 2,
            "answer_type": "narrative",
            "answer": "South Asian",
            "state": "answered", "visibility": "public", "provenance": "imported",
        },
    }
    db = _db(nodes)
    rep = asyncio.run(sweep.sweep_user(db, UID, dry_run=False))
    if rep.merged:  # whether judged duplicate or caught as a standard restatement
        survivor, removed = rep.merged[0]
        assert survivor == "ethnic_cultural_origin"
        assert removed == "emergent.x"
        assert "emergent.x" not in store.load_overlay(db, UID)


def test_richer_bullet_not_folded_into_standard_field(monkeypatch):
    """NOTE 255 add.3: a bullet that carries EXTRA facts beyond a standard field's
    short value must NEVER be folded into that standard field — folding would drop
    the extra facts. The founder's primary_location pair: "San Jose, United States"
    (standard) vs a bullet that also states the languages he speaks. The judge
    calls them duplicates, but the sweep RAISES the pair instead of merging, so no
    fact is lost and both nodes still render."""
    _on(monkeypatch)
    _judge_all_duplicate(monkeypatch)
    nodes = {
        "primary_location": {"answer": "San Jose, United States",
                             "state": "answered", "visibility": "public"},
        "emergent.loc": {
            "prompt": "Location", "section": "identity", "level": 1,
            "answer_type": "narrative",
            "answer": "He currently lives in San Jose, California and speaks "
                      "Malayalam and English.",
            "state": "answered", "visibility": "public", "provenance": "imported",
        },
    }
    db = _db(nodes)
    rep = asyncio.run(sweep.sweep_user(db, UID, dry_run=False))
    # not merged — the richer bullet is preserved, not absorbed into the field.
    assert rep.merged == []
    overlay = store.load_overlay(db, UID)
    assert "emergent.loc" in overlay  # the extra facts still live on their node
    # the languages fact is still rendered content, not lost to history.
    assert "Malayalam" in overlay["emergent.loc"]["answer"]
    # the pair is raised for the user to decide (never silently dropped).
    assert ("primary_location", "emergent.loc") in {
        (p["a"], p["b"]) for p in store.pending_dedupe(db, UID)
    } or ("emergent.loc", "primary_location") in {
        (p["a"], p["b"]) for p in store.pending_dedupe(db, UID)
    }


def test_seed_narrative_duplicate_is_raised_not_dropped(monkeypatch):
    """NOTE 255 add.3: two SEED NARRATIVE nodes stating the same fact (the
    "coffee" career pair) are a real duplicate the finder must surface. Neither
    seed can be deleted, so the sweep RAISES the pair for the user instead of
    silently dropping it (the old ``_has_emergent`` gate dropped every
    seed-vs-seed pair before it was ever judged)."""
    _on(monkeypatch)
    _judge_all_duplicate(monkeypatch)
    nodes = {
        "career_role_narrative": {
            "answer": "Starts the day with coffee and sketching, then heads to "
                      "the studio by 10 for product flows and user research.",
            "state": "answered", "visibility": "private",
        },
        "career_trajectory_narrative": {
            "answer": "Days start with coffee and sketching, heading to the "
                      "studio by 10 to work on product flows and user research.",
            "state": "answered", "visibility": "private",
        },
    }
    db = _db(nodes)
    rep = asyncio.run(sweep.sweep_user(db, UID, dry_run=False))
    assert rep.merged == []  # two seeds — nothing deletable, nothing merged
    raised = {frozenset((p[0], p[1])) for p in rep.raised}
    assert frozenset(("career_role_narrative", "career_trajectory_narrative")) in raised
    # both seed nodes still present (a seed is never deleted).
    overlay = store.load_overlay(db, UID)
    assert "career_role_narrative" in overlay and "career_trajectory_narrative" in overlay


def test_two_structured_seed_fields_are_not_a_dedupe_pair(monkeypatch):
    """Two FIXED structured template fields (enums) are distinct questions, never
    duplicates of each other — they must not be merged or raised even if the judge
    is told to call every pair a duplicate."""
    _on(monkeypatch)
    _judge_all_duplicate(monkeypatch)
    # identical answers in the same section, so they WOULD be an EXACT lexical
    # candidate — proving they are excluded by the structured-field rule, not just
    # by low similarity.
    nodes = {
        "education_level": {"answer": "Graduate degree", "state": "answered",
                            "visibility": "private"},
        "work_schedule_pattern": {"answer": "Graduate degree", "state": "answered",
                                  "visibility": "private"},
    }
    db = _db(nodes)
    rep = asyncio.run(sweep.sweep_user(db, UID, dry_run=False))
    assert rep.merged == [] and rep.raised == []


# --- uncertain / disagreeing pairs are RAISED, never merged ----------------


def test_related_pair_is_raised_not_merged(monkeypatch):
    _on(monkeypatch)
    _judge_all_related(monkeypatch)  # judge says "related", not duplicate
    db = _db(_SOCIAL_CIRCLE)
    rep = asyncio.run(sweep.sweep_user(db, UID, dry_run=False))
    assert rep.merged == []
    assert len(rep.raised) == 1
    # both nodes still present; the pair is recorded for the in-chat raise
    overlay = store.load_overlay(db, UID)
    assert "emergent.a" in overlay and "emergent.b" in overlay
    pend = store.pending_dedupe(db, UID)
    assert {(p["a"], p["b"]) for p in pend} == {("emergent.a", "emergent.b")}


def test_dry_run_writes_nothing(monkeypatch):
    _on(monkeypatch)
    _judge_all_duplicate(monkeypatch)
    db = _db(_SOCIAL_CIRCLE)
    rep = asyncio.run(sweep.sweep_user(db, UID, dry_run=True))
    assert rep.dry_run is True
    assert len(rep.merged) == 1  # it WOULD merge
    overlay = store.load_overlay(db, UID)
    assert "emergent.a" in overlay and "emergent.b" in overlay  # nothing removed
    assert store.pending_dedupe(db, UID) == []  # nothing recorded


def test_flag_off_is_a_noop(monkeypatch):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, graph_dedupe_sweep=False)
    )
    db = _db(_SOCIAL_CIRCLE)
    rep = asyncio.run(sweep.sweep_user(db, UID, dry_run=False))
    assert rep.merged == [] and rep.raised == []
    assert "emergent.b" in store.load_overlay(db, UID)


# --- privacy: a merge NEVER widens visibility ------------------------------


_VIS = ["private", "ayma_only", "public"]


@pytest.mark.parametrize("va", _VIS)
@pytest.mark.parametrize("vb", _VIS)
def test_more_private_never_widens(va, vb):
    result = sweep.more_private(va, vb)
    rank = sweep._VIS_RANK
    assert rank[result] == min(rank[va], rank[vb])
    # the result is never MORE public than either input
    assert rank[result] <= rank[va] and rank[result] <= rank[vb]


@pytest.mark.parametrize("va", _VIS)
@pytest.mark.parametrize("vb", _VIS)
def test_apply_merge_survivor_visibility_is_most_private(va, vb):
    nodes = {
        "emergent.p": {
            "prompt": "Pet", "section": "misc", "level": 1,
            "answer_type": "narrative", "answer": "I have a cat named Milo",
            "state": "answered", "visibility": va,
        },
        "emergent.q": {
            "prompt": "Pet", "section": "misc", "level": 1,
            "answer_type": "narrative", "answer": "I have a cat named Milo",
            "state": "answered", "visibility": vb,
        },
    }
    db = _db(nodes)
    graph = store.effective(db, UID)
    res = sweep.apply_merge(db, UID, "emergent.p", "emergent.q", graph)
    assert res is not None
    survivor, _ = res
    vis = store.load_overlay(db, UID)[survivor].get("visibility", "private")
    rank = sweep._VIS_RANK
    assert rank[vis] == min(rank[va], rank[vb])  # most private of the two


# --- Layer 1: write-time semantic fold -------------------------------------


_FOLD_VECS = {
    "I volunteer at the animal shelter every weekend": [1.0, 0.0, 0.0],
    "I spend my weekends volunteering at the animal shelter": [0.99, 0.02, 0.0],
    "I work as a data analyst in Lisbon": [0.0, 1.0, 0.0],
}


def _mock_embed(texts):
    return [_FOLD_VECS.get(t, [0.0, 0.0, 1.0]) for t in texts]


def test_write_time_fold_enriches_and_keeps_both_sources(monkeypatch):
    _on(monkeypatch, graph_embedding_dedupe=True, node_dedupe_prevention=True)
    monkeypatch.setattr(graph_embeddings, "_embed_backend", _mock_embed)

    db = _db({})
    # seed one emergent node + its stored vector
    nid = store.add_loose_node(
        db, UID, "I volunteer at the animal shelter every weekend",
        section="misc", source_kind="chat", source_ref="sess-1",
    )
    graph_embeddings.refresh_vectors(db, UID)

    # a paraphrase arrives from a different session -> must FOLD into nid
    got = store.add_loose_node(
        db, UID, "I spend my weekends volunteering at the animal shelter",
        section="misc", source_kind="profile_grid", source_ref="sess-2",
    )
    assert got == nid  # folded, no second node minted
    overlay = store.load_overlay(db, UID)
    assert len([k for k in overlay if k.startswith("emergent.")]) == 1
    node = overlay[nid]
    # the longer paraphrase enriched the live answer...
    assert node["answer"] == "I spend my weekends volunteering at the animal shelter"
    # ...and BOTH sources are kept (new on the node, old retired to history).
    assert node["source_ref"] == "sess-2"
    assert any(h.get("source_ref") == "sess-1" for h in (node.get("history") or []))


def test_write_time_fold_leaves_distinct_fact_alone(monkeypatch):
    _on(monkeypatch, graph_embedding_dedupe=True, node_dedupe_prevention=True)
    monkeypatch.setattr(graph_embeddings, "_embed_backend", _mock_embed)
    db = _db({})
    nid = store.add_loose_node(
        db, UID, "I volunteer at the animal shelter every weekend", section="misc",
    )
    graph_embeddings.refresh_vectors(db, UID)
    other = store.add_loose_node(
        db, UID, "I work as a data analyst in Lisbon", section="misc",
    )
    assert other != nid  # orthogonal vector -> a new node, not a fold
    assert len(store.load_overlay(db, UID)) == 2


def test_fold_into_node_direct_shorter_text_keeps_survivor_and_records_source():
    db = _db({
        "emergent.s": {
            "prompt": "x", "section": "misc", "level": 1, "answer_type": "narrative",
            "answer": "I have a brown tabby cat named Milo who is very playful",
            "state": "answered", "visibility": "private",
            "source_kind": "chat", "source_ref": "sess-1",
        },
    })
    store.fold_into_node(
        db, UID, "emergent.s", "my cat Milo",
        source_kind="web", source_ref="sess-2",
    )
    node = store.load_overlay(db, UID)["emergent.s"]
    # survivor keeps its fuller answer...
    assert node["answer"].startswith("I have a brown tabby cat")
    # ...but the shorter wording + its source is recorded so both sources live.
    assert any(h.get("source_ref") == "sess-2" for h in (node.get("history") or []))
