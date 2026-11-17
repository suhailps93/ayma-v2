"""Tests for the standard-vs-emergent duplicate-fact MERGE tool (founder build
2488, Layer 3). The tool finds every emergent node that only restates a standard
fact and folds it into the standard node (standard survives, duplicate deleted),
with a ``--dry-run`` that only reports. Project-pinned to ayma-staging."""

import pytest

import person_graph_store as store
from tools import merge_duplicate_fact_nodes as tool

from test_node_dedupe import UID, FakeDb, _overlay_doc, _profile


def _db(nodes):
    return FakeDb({**_profile(UID), **_overlay_doc(UID, nodes)})


_STANDARD_AND_DUP = {
    # the standard identity fact (seed node id) — South Asian, private
    "ethnic_cultural_origin": {"answer": "South Asian", "state": "answered",
                               "visibility": "private"},
    # an emergent node that only restates it (the founder's editor import dup),
    # here PUBLIC so the merge must keep the standard node's PRIVATE visibility
    "emergent.editor.identity.11": {
        "prompt": "Ethnic and cultural origin: South Asian", "section": "identity",
        "level": 2, "answer_type": "narrative",
        "answer": "Ethnic and cultural origin: South Asian",
        "state": "answered", "visibility": "public", "provenance": "imported",
    },
    # a genuinely distinct emergent fact — must NOT be merged
    "emergent.story.identity.2": {
        "prompt": "Grew up in Chennai", "section": "identity", "level": 2,
        "answer_type": "narrative", "answer": "Grew up in Chennai",
        "state": "answered", "visibility": "public", "provenance": "stated",
    },
}


def test_dry_run_reports_pairs_and_writes_nothing():
    db = _db(_STANDARD_AND_DUP)
    report = tool.merge_duplicate_fact_nodes(db, UID, dry_run=True)
    assert report.dry_run is True
    assert [(p.standard_id, p.dup_id) for p in report.pairs] == [
        ("ethnic_cultural_origin", "emergent.editor.identity.11")
    ]
    # the restatement is PUBLIC while the standard row is PRIVATE → recorded conflict
    assert report.pairs[0].vis_conflict is True
    assert len(report.vis_conflicts) == 1
    assert report.merged == []
    # nothing changed on disk
    overlay = store.load_overlay(db, UID)
    assert "emergent.editor.identity.11" in overlay


def test_apply_merges_dup_into_standard_keeps_standard_visibility():
    db = _db(_STANDARD_AND_DUP)
    report = tool.merge_duplicate_fact_nodes(db, UID, dry_run=False)
    assert report.merged == ["emergent.editor.identity.11"]
    overlay = store.load_overlay(db, UID)
    # the duplicate is gone; the standard node survives with its answer
    assert "emergent.editor.identity.11" not in overlay
    assert overlay["ethnic_cultural_origin"]["answer"] == "South Asian"
    # the standard node's visibility is KEPT (never flipped to the dup's public)
    assert overlay["ethnic_cultural_origin"].get("visibility", "private") == "private"
    # the duplicate's text is retired to the survivor's history, never dropped
    hist = overlay["ethnic_cultural_origin"].get("history") or []
    assert any("South Asian" in str(h.get("answer")) for h in hist)
    # the genuinely distinct fact is untouched
    assert overlay["emergent.story.identity.2"]["answer"] == "Grew up in Chennai"


def test_apply_preserves_children_of_merged_duplicate():
    nodes = dict(_STANDARD_AND_DUP)
    nodes["emergent.image.abc"] = {
        "prompt": "photo", "section": "identity", "level": 3,
        "answer_type": "image", "answer": "https://x/p.jpg",
        "image_read": "A person", "parent": "emergent.editor.identity.11",
        "state": "answered", "visibility": "private",
    }
    db = _db(nodes)
    tool.merge_duplicate_fact_nodes(db, UID, dry_run=False)
    overlay = store.load_overlay(db, UID)
    assert "emergent.editor.identity.11" not in overlay
    # the child image was rehomed onto the surviving standard node, not orphaned
    assert overlay["emergent.image.abc"]["parent"] == "ethnic_cultural_origin"


def test_distinct_facts_produce_no_pairs():
    db = _db({
        "ethnic_cultural_origin": {"answer": "South Asian", "state": "answered"},
        "emergent.story.identity.2": {
            "prompt": "Grew up in Chennai", "section": "identity", "level": 2,
            "answer_type": "narrative", "answer": "Grew up in Chennai",
            "state": "answered", "visibility": "public",
        },
    })
    report = tool.merge_duplicate_fact_nodes(db, UID, dry_run=True)
    assert report.pairs == []


def test_require_staging_project_guard():
    tool.require_staging_project("ayma-staging")  # ok
    for bad in ("ayma-prod", "ayma", "ayma-staging2", "", "prod"):
        with pytest.raises(SystemExit):
            tool.require_staging_project(bad)
