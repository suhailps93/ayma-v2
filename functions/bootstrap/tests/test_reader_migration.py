"""Reader migration — unblock the structured-writer swap.

Antigravity's BLOCKED filing (astro.md, Nov 16 ~06:05 PT): with the graph flags
ON, ``profile/main`` and ``qstore`` (``users/{uid}/questionnaire``) still had
live readers, so swapping ``set_profile_field`` / ``record_answer`` /
``set_relationship_intent`` to graph-only would have broken completeness /
next_questions, matching, taste backfill, recall and the session-mode gate.

These tests pin each migrated reader: **flag ON returns the graph data, flag OFF
returns the old-store data** — so the swap can land after this chunk without
re-asking recorded answers cold or stalling a graph-only profile edit.
"""

import dataclasses

import config
from config import CONFIG


# --- Firestore fake (tuple-path; graph + questionnaire + profile) ----------


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


def _set_reads(monkeypatch, reads: bool):
    monkeypatch.setattr(
        config, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=reads)
    )


def _qdoc(db, uid, nid, value, source="stated", updated_at=None):
    doc = {"node_id": nid, "value": value, "source": source}
    if updated_at is not None:
        doc["updated_at"] = updated_at
    db.docs[("users", uid, "questionnaire", nid)] = doc


# --- 1. completeness._questionnaire_store ----------------------------------


def test_completeness_qstore_reads_graph_on_wiki_off(monkeypatch):
    import completeness
    import person_graph_store as store

    db = FakeDb()
    store.set_answer(db, "u1", "gender_identity", "Woman")
    # a STALE questionnaire doc that must NOT be read when the flag is on
    _qdoc(db, "u1", "gender_identity", "STALE-DOC")

    _set_reads(monkeypatch, True)
    on = completeness._questionnaire_store(db, "u1")
    assert on["gender_identity"]["value"] == "Woman"  # graph, not the doc

    _set_reads(monkeypatch, False)
    off = completeness._questionnaire_store(db, "u1")
    assert off["gender_identity"]["value"] == "STALE-DOC"  # the doc


# --- 2. questionnaire_ingest._questionnaire_store --------------------------


def test_ingest_qstore_reads_graph_on_doc_off(monkeypatch):
    import person_graph_store as store
    import questionnaire_ingest

    db = FakeDb()
    store.set_answer(db, "u1", "relationship_intent", "Marriage")
    _qdoc(db, "u1", "relationship_intent", "STALE-DOC")

    _set_reads(monkeypatch, True)
    on = questionnaire_ingest._questionnaire_store(db, "u1")
    assert on["relationship_intent"]["value"] == "Marriage"

    _set_reads(monkeypatch, False)
    off = questionnaire_ingest._questionnaire_store(db, "u1")
    assert off["relationship_intent"]["value"] == "STALE-DOC"


# --- 3. taste_backfill._taste_values ---------------------------------------


def test_taste_values_read_graph_on_doc_off(monkeypatch):
    import person_graph_store as store
    import taste_backfill

    db = FakeDb()
    store.set_answer(db, "u1", "taste_music", "Radiohead, jazz")
    store.set_answer(db, "u1", "taste_film", "Studio Ghibli")
    _qdoc(db, "u1", "taste_music", "STALE music")
    _qdoc(db, "u1", "taste_food", "Thai")

    _set_reads(monkeypatch, True)
    on = taste_backfill._taste_values(db, "u1")
    assert on["music"] == "Radiohead, jazz"   # graph
    assert on["film"] == "Studio Ghibli"      # graph
    assert on["food"] == ""                   # not answered in the graph

    _set_reads(monkeypatch, False)
    off = taste_backfill._taste_values(db, "u1")
    assert off["music"] == "STALE music"      # the doc
    assert off["food"] == "Thai"              # the doc


# --- 4. fact_source._questionnaire_matches ---------------------------------


def test_questionnaire_matches_read_graph_on_doc_off(monkeypatch):
    import person_graph_store as store
    from skills import fact_source

    db = FakeDb()
    store.set_answer(db, "u1", "primary_location", "Seattle")
    _qdoc(db, "u1", "primary_location", "STALE CITY")

    qtok = fact_source._tokens("where do they live")

    _set_reads(monkeypatch, True)
    on = fact_source._questionnaire_matches(db, "u1", qtok)
    vals = {m["current_value"] for m in on}
    assert "Seattle" in vals and "STALE CITY" not in vals
    assert all(m["exact"] is False for m in on)  # graph carries no verbatim quote

    _set_reads(monkeypatch, False)
    off = fact_source._questionnaire_matches(db, "u1", qtok)
    assert "STALE CITY" in {m["current_value"] for m in off}


# --- 5. main._match_inputs_mtime -------------------------------------------


def test_match_inputs_mtime_uses_graph_overlay_on(monkeypatch):
    import main
    import person_graph_store as store

    db = FakeDb()
    # A graph edit (recent) with only a very old questionnaire doc present:
    # flag ON must pick up the graph overlay stamp, flag OFF only the old doc.
    _qdoc(db, "u1", "primary_location", "Reno",
          updated_at=_dt("2020-01-01T00:00:00+00:00"))
    store.set_answer(db, "u1", "primary_location", "Seattle")  # stamps overlay now

    _set_reads(monkeypatch, True)
    on = main._match_inputs_mtime(db, "u1")
    assert on is not None and on.year >= 2026  # the fresh graph overlay stamp

    _set_reads(monkeypatch, False)
    off = main._match_inputs_mtime(db, "u1")
    assert off is not None and off.year == 2020  # only the old questionnaire doc


# --- 6. person_graph_source.load_user profile hydration --------------------


def test_load_user_hydrates_profile_from_graph(monkeypatch):
    import person_graph_source as src
    import person_graph_store as store

    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {
        "name": "STALE NAME", "location": "Old Town", "gender": "Woman",
    }
    store.set_answer(db, "u1", "legal_first_name", "Amelia")
    store.set_answer(db, "u1", "primary_location", "Seattle")

    profile, _qstore = src.load_user(db, "u1")
    assert profile["name"] == "Amelia"        # graph wins
    assert profile["location"] == "Seattle"   # graph wins
    assert profile["gender"] == "Woman"       # untouched profile field kept


def test_load_user_graph_blank_keeps_profile(monkeypatch):
    import person_graph_source as src

    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {"name": "Keep Me"}
    # no graph answers → nothing overlaid, profile field preserved
    profile, _qstore = src.load_user(db, "u1")
    assert profile["name"] == "Keep Me"


# --- 7. session_mode.derive_for gate ---------------------------------------


def test_session_mode_active_from_graph_filled_fields(monkeypatch):
    import person_graph_store as store
    import session_mode

    db = FakeDb()
    # profile/main holds only photos (the upload flow's direct write); every
    # required text field was filled through the graph tools.
    db.docs[("users", "u1", "profile", "main")] = {"photos": ["p1.jpg"]}
    db.docs[("users", "u1")] = {"onboarding_started": True}
    for nid, val in [
        ("legal_first_name", "Amelia"),
        ("date_of_birth", "1995-06-01"),
        ("gender_identity", "Woman"),
        ("target_match_genders", "Men"),
        ("primary_location", "Seattle"),
    ]:
        store.set_answer(db, "u1", nid, val)

    _set_reads(monkeypatch, True)
    assert session_mode.derive_for(db, "u1", is_anonymous=False) == session_mode.MODE_ACTIVE

    _set_reads(monkeypatch, False)
    # flag off: profile/main lacks the text fields → still interviewing
    assert session_mode.derive_for(db, "u1", is_anonymous=False) == session_mode.MODE_INTERVIEW


# --- 8. shared helpers (unit) ----------------------------------------------


def test_profile_overlay_and_taste_values(monkeypatch):
    import person_graph_source as src
    import person_graph_store as store

    db = FakeDb()
    store.set_answer(db, "u1", "legal_first_name", "Amelia")
    store.set_answer(db, "u1", "taste_food", "Thai, ramen")
    graph = store.effective(db, "u1")

    assert src.profile_overlay(graph) == {"name": "Amelia"}
    tv = src.taste_values(graph)
    assert tv["food"] == "Thai, ramen" and tv["music"] == "" and tv["film"] == ""


def _dt(iso):
    from datetime import datetime

    return datetime.fromisoformat(iso)
