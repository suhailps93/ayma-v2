"""Supplemental (volunteered / off-tree) questionnaire store — founder req 4."""

import supplemental
from tests.fake_firestore import FakeDb

_UID = "u1"


def _supp_key(slug):
    return ("users", _UID, "questionnaire_supplemental", slug)


def test_records_a_volunteered_topic_in_tree_node_shape():
    db = FakeDb()
    slug = supplemental.record_supplemental(
        db, _UID, "family", "Their dog Max",
        "Has a golden retriever named Max, three years old", "answered",
        session_id="s1",
    )
    assert slug
    doc = db.docs[_supp_key(slug)]
    assert doc["section"] == "family"
    assert doc["topic"] == "Their dog Max"
    assert doc["status"] == "answered"
    assert doc["source"] == "volunteered"
    assert "Max" in doc["value"]


def test_unknown_section_falls_back_to_misc():
    db = FakeDb()
    slug = supplemental.record_supplemental(
        db, _UID, "not-a-section", "Collects vinyl", "Owns 400 records"
    )
    assert db.docs[_supp_key(slug)]["section"] == "misc"


def test_bad_status_normalises_to_answered():
    db = FakeDb()
    slug = supplemental.record_supplemental(
        db, _UID, "misc", "Topic", "value here", "whatever"
    )
    assert db.docs[_supp_key(slug)]["status"] == "answered"
    slug2 = supplemental.record_supplemental(
        db, _UID, "misc", "Half topic", "only touched it", "partial"
    )
    assert db.docs[_supp_key(slug2)]["status"] == "partial"


def test_same_topic_updates_in_place_no_duplicates():
    db = FakeDb()
    s1 = supplemental.record_supplemental(db, _UID, "misc", "Their dog", "a dog")
    s2 = supplemental.record_supplemental(
        db, _UID, "misc", "Their  Dog!", "a golden retriever", status="answered"
    )
    # Same slug for the same topic (case/punctuation-insensitive) → one doc.
    assert s1 == s2
    supp = supplemental.read_supplemental(db, _UID)
    assert len(supp) == 1
    assert supp[0]["value"] == "a golden retriever"


def test_thin_inputs_are_skipped():
    db = FakeDb()
    assert supplemental.record_supplemental(db, _UID, "misc", "", "value") is None
    assert supplemental.record_supplemental(db, _UID, "misc", "topic", "") is None
    assert supplemental.read_supplemental(db, _UID) == []


def test_read_returns_every_entry():
    db = FakeDb()
    supplemental.record_supplemental(db, _UID, "career", "Side business", "runs an Etsy shop")
    supplemental.record_supplemental(db, _UID, "interests", "Rock climbing", "climbs V5 bouldering")
    supp = {s["topic"] for s in supplemental.read_supplemental(db, _UID)}
    assert supp == {"Side business", "Rock climbing"}
