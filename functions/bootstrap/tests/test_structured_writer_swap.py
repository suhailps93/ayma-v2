"""Tests for structured-writer swap (record_answer, set_profile_field, set_relationship_intent).

Verifies that with PERSON_GRAPH_READS on (graph flags ON):
1. The three model tools write to the person-graph overlay and leave profile/main,
   qstore (users/{uid}/questionnaire), and wiki_pages/taste untouched.
2. Visibility follows the established allow-list defaults (structured facts private
   unless on the public allow-list: DOB, gender, location, interested_in, relationship_intent).
3. Taste writes compose the graph Taste section (emergent.taste.qloo, public).
4. Validation and safety rules (18+ adult birthdate, field normalization, gender inference ban)
   are strictly preserved.
5. All live readers read the swapped writes via the graph.
6. With PERSON_GRAPH_READS off, the existing old-store write paths remain untouched.
"""

import dataclasses
import datetime

import config
from config import CONFIG
import person_graph_render as render
import person_graph_source as src
import person_graph_store as store
import session_mode
import skills
from skills import questionnaire
from skills import set_profile_field as spf
from tests.test_reader_migration import FakeDb, _set_reads


def _tool_fns(db, uid="u1"):
    return skills.make_session_tool_fns(db, uid)


def _graph_overlay(db, uid="u1"):
    return store.load_overlay(db, uid)


def _qstore_docs(db, uid="u1"):
    return {k[-1]: v for k, v in db.docs.items()
            if len(k) == 4 and k[0] == "users" and k[1] == uid and k[2] == "questionnaire"}


def _wiki_docs(db, uid="u1"):
    return {k[-1]: v for k, v in db.docs.items()
            if len(k) == 4 and k[0] == "users" and k[1] == uid and k[2] == "wiki_pages"}


def _profile_main(db, uid="u1"):
    return db.docs.get(("users", uid, "profile", "main"))


# --- 1. record_answer ---------------------------------------------------------


def test_record_answer_writes_graph_leaves_old_stores_untouched(monkeypatch):
    db = FakeDb()
    _set_reads(monkeypatch, True)
    fn = _tool_fns(db, "u1")["record_answer"]

    res = fn("smoking_vaping", "No", "stated")
    assert "recorded" in res

    # Graph has answer
    overlay = _graph_overlay(db, "u1")
    assert "smoking_vaping" in overlay
    assert overlay["smoking_vaping"]["answer"] == "false"
    assert overlay["smoking_vaping"]["state"] == "answered"
    assert overlay["smoking_vaping"]["provenance"] == "stated"

    # Effective visibility is private (not on public allow-list)
    graph = store.effective(db, "u1")
    assert graph["smoking_vaping"].visibility.value == "private"

    # Old stores are untouched
    assert _profile_main(db, "u1") is None
    assert not _qstore_docs(db, "u1")
    assert not _wiki_docs(db, "u1")


def test_record_answer_gender_inference_refusal(monkeypatch):
    db = FakeDb()
    _set_reads(monkeypatch, True)
    fn = _tool_fns(db, "u1")["record_answer"]

    res = fn("gender_identity", "Woman", "inferred")
    assert "ask them directly instead of inferring it" in res
    assert not _graph_overlay(db, "u1")


def test_record_answer_taste_writes_graph_taste_section_and_leaves_wiki_untouched(monkeypatch):
    db = FakeDb()
    _set_reads(monkeypatch, True)
    fn = _tool_fns(db, "u1")["record_answer"]

    res_music = fn("taste_music", "Radiohead, Khruangbin", "stated")
    res_film = fn("taste_film", "Arrival, Spirited Away", "stated")
    assert "recorded" in res_music
    assert "recorded" in res_film

    # Answers on graph nodes
    overlay = _graph_overlay(db, "u1")
    assert overlay["taste_music"]["answer"] == "Radiohead, Khruangbin"
    assert overlay["taste_film"]["answer"] == "Arrival, Spirited Away"

    # Taste section composed in emergent.taste.qloo
    assert "emergent.taste.qloo" in overlay
    qloo = overlay["emergent.taste.qloo"]
    assert qloo["section"] == "taste"
    assert qloo["visibility"] == "public"
    assert "Music: Radiohead, Khruangbin" in qloo["answer"]
    assert "Film: Arrival, Spirited Away" in qloo["answer"]

    # Public sections rendered from graph include the taste section
    graph = store.effective(db, "u1")
    pub = render.public_sections(graph)
    taste_secs = [s for s in pub if s["page_type"] == "taste"]
    assert len(taste_secs) == 1
    bullets = taste_secs[0]["bullets"]
    assert any("Music: Radiohead, Khruangbin" in b for b in bullets)
    assert any("Film: Arrival, Spirited Away" in b for b in bullets)

    # Old stores untouched
    assert _profile_main(db, "u1") is None
    assert not _qstore_docs(db, "u1")
    assert not _wiki_docs(db, "u1")


# --- 2. set_relationship_intent -----------------------------------------------


def test_set_relationship_intent_writes_graph_leaves_old_stores_untouched(monkeypatch):
    db = FakeDb()
    _set_reads(monkeypatch, True)
    fn = _tool_fns(db, "u1")["set_relationship_intent"]

    res = fn("Marriage")
    assert "recorded" in res
    assert "marriage" in res.lower()

    # Graph has answer
    overlay = _graph_overlay(db, "u1")
    assert "relationship_intent" in overlay
    assert overlay["relationship_intent"]["answer"] == "Marriage"
    assert overlay["relationship_intent"]["state"] == "answered"

    # Visibility is public (in _PUBLIC_ALLOWLIST)
    graph = store.effective(db, "u1")
    assert graph["relationship_intent"].visibility.value == "public"

    # Old stores untouched
    assert _profile_main(db, "u1") is None
    assert not _qstore_docs(db, "u1")
    assert not _wiki_docs(db, "u1")


# --- 3. set_profile_field -----------------------------------------------------


def test_set_profile_field_writes_graph_leaves_profile_main_untouched(monkeypatch):
    db = FakeDb()
    _set_reads(monkeypatch, True)
    fn = _tool_fns(db, "u1")["set_profile_field"]

    assert fn("name", "  Amelia ") == "set name"
    assert fn("birthdate", "1996-05-12") == "set birthdate"
    assert fn("gender", "woman") == "set gender"
    assert fn("interested_in", "men and women") == "set interested_in"
    assert fn("location", "San Francisco") == "set location"
    assert fn("last_name", "Earhart") == "set last_name"
    assert fn("phone", "+1 (555) 012-3456") == "set phone"

    overlay = _graph_overlay(db, "u1")
    assert overlay["legal_first_name"]["answer"] == "Amelia"
    assert overlay["date_of_birth"]["answer"] == "1996-05-12"
    assert overlay["gender_identity"]["answer"] == "Woman"
    assert overlay["target_match_genders"]["answer"] == ["Men", "Women"]
    assert overlay["primary_location"]["answer"] == "San Francisco"
    assert overlay["emergent.profile.last_name"]["answer"] == "Earhart"
    assert overlay["emergent.profile.phone"]["answer"] == "+15550123456"

    # Visibilities match common-sense / allow-list defaults
    graph = store.effective(db, "u1")
    assert graph["legal_first_name"].visibility.value == "private"
    assert graph["date_of_birth"].visibility.value == "public"
    assert graph["gender_identity"].visibility.value == "public"
    assert graph["target_match_genders"].visibility.value == "public"
    assert graph["primary_location"].visibility.value == "public"
    assert graph["emergent.profile.last_name"].visibility.value == "private"
    assert graph["emergent.profile.phone"].visibility.value == "private"

    # profile/main was NEVER written
    assert _profile_main(db, "u1") is None
    assert not _qstore_docs(db, "u1")
    assert not _wiki_docs(db, "u1")


def test_set_profile_field_enforces_18_plus_safety_on_graph(monkeypatch):
    db = FakeDb()
    _set_reads(monkeypatch, True)
    fn = _tool_fns(db, "u1")["set_profile_field"]

    # under 18 birthdate
    recent = (datetime.date.today() - datetime.timedelta(days=365 * 10)).isoformat()
    res = fn("birthdate", recent)
    assert "under 18" in res
    assert "date_of_birth" not in _graph_overlay(db, "u1")
    assert _profile_main(db, "u1") is None


def test_set_profile_field_rejects_invalid_inputs(monkeypatch):
    db = FakeDb()
    _set_reads(monkeypatch, True)
    fn = _tool_fns(db, "u1")["set_profile_field"]

    assert fn("shoe_size", "10").startswith("unknown field")
    assert fn("gender", "spaceship").startswith("could not use")
    assert fn("birthdate", "not-a-date").startswith("could not use")
    assert not _graph_overlay(db, "u1")
    assert _profile_main(db, "u1") is None


# --- 4. Live reader integration -----------------------------------------------


def test_readers_read_swapped_writes_via_graph_end_to_end(monkeypatch):
    db = FakeDb()
    _set_reads(monkeypatch, True)
    tools = _tool_fns(db, "u1")

    # Populate profile fields via set_profile_field (graph-only)
    tools["set_profile_field"]("name", "Amelia")
    tools["set_profile_field"]("birthdate", "1995-06-01")
    tools["set_profile_field"]("gender", "Woman")
    tools["set_profile_field"]("interested_in", "Men")
    tools["set_profile_field"]("location", "Seattle")
    tools["set_profile_field"]("last_name", "Earhart")
    tools["set_profile_field"]("phone", "+15551234567")

    # Relationship intent via set_relationship_intent (graph-only)
    tools["set_relationship_intent"]("Marriage")

    # Questionnaire answer via record_answer (graph-only)
    tools["record_answer"]("taste_music", "Radiohead", "stated")

    # 1. person_graph_source.load_user
    profile, qstore = src.load_user(db, "u1")
    assert profile["name"] == "Amelia"
    assert profile["birthdate"] == "1995-06-01"
    assert profile["gender"] == "Woman"
    assert profile["interested_in"] == ["Men"]
    assert profile["location"] == "Seattle"
    assert profile["relationship_intent"] == "Marriage"
    assert profile["last_name"] == "Earhart"
    assert profile["phone"] == "+15551234567"
    assert qstore["taste_music"]["value"] == "Radiohead"

    # 2. session_mode.derive_for reaches ACTIVE with photo
    db.docs[("users", "u1", "profile", "main")] = {"photos": ["p1.jpg"]}
    db.docs[("users", "u1")] = {"onboarding_started": True}
    assert session_mode.derive_for(db, "u1", is_anonymous=False) == session_mode.MODE_ACTIVE

    # 3. taste_backfill reads taste values from graph
    import taste_backfill
    tv = taste_backfill._taste_values(db, "u1")
    assert tv["music"] == "Radiohead"

    # 4. completeness._questionnaire_store reads answers from graph
    import completeness
    cq = completeness._questionnaire_store(db, "u1")
    assert cq["taste_music"]["value"] == "Radiohead"
    assert cq["legal_first_name"]["value"] == "Amelia"


# --- 5. Flag OFF backward compatibility ---------------------------------------


def test_flag_off_still_writes_old_stores(monkeypatch):
    db = FakeDb()
    _set_reads(monkeypatch, False)
    tools = _tool_fns(db, "u1")

    # record_answer writes questionnaire doc + profile mirror
    tools["record_answer"]("alcohol_consumption", "Never", "stated")
    assert ("users", "u1", "questionnaire", "alcohol_consumption") in db.docs
    assert db.docs[("users", "u1", "questionnaire", "alcohol_consumption")]["value"] == "Never"
    assert _profile_main(db, "u1")["qz_alcohol_consumption"] == "Never"

    # set_profile_field writes profile/main
    tools["set_profile_field"]("name", "Bob")
    assert _profile_main(db, "u1")["name"] == "Bob"

    # set_relationship_intent writes profile/main and questionnaire
    tools["set_relationship_intent"]("Long-term")
    assert _profile_main(db, "u1")["relationship_intent"] == "Long-term"
    assert ("users", "u1", "questionnaire", "relationship_intent") in db.docs

    # graph overlay was NOT written
    assert not _graph_overlay(db, "u1")
