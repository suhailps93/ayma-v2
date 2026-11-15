"""Tests for the person-graph migration (Phase 4): stores → overlay."""

import person_graph as pg
import person_graph_migrate as mig
import person_graph_render as render
import person_graph_store as store
from person_graph import NodeState, Provenance, Visibility


# --- a Firestore fake with subcollection stream() --------------------------


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
        for key, data in self._st.docs.items():
            if len(key) == depth + 1 and key[:depth] == self._key and data is not None:
                yield _Snap(key[-1], data)


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


def _q(uid, nid, **extra):
    return {("users", uid, "questionnaire", nid): {"node_id": nid, **extra}}


# --- questionnaire + profile ----------------------------------------------


def test_migrate_questionnaire_maps_to_seed_nodes():
    docs = {}
    docs.update(_q("u1", "alcohol_consumption", value="Never", source="stated"))
    docs.update(_q("u1", "attachment_style", value="Secure", source="inferred", confidence="high"))
    docs.update(_q("u1", "retired_unknown_id", value="x", source="stated"))
    db = FakeDb(docs)
    ov = mig.migrate_questionnaire(db, "u1")
    assert ov["alcohol_consumption"]["answer"] == "Never"
    assert ov["alcohol_consumption"]["provenance"] == Provenance.STATED.value
    assert ov["attachment_style"]["provenance"] == Provenance.INFERRED.value
    assert ov["attachment_style"]["confidence"] == 0.9
    assert "retired_unknown_id" not in ov  # non-seed id skipped here


def test_migrate_profile_fills_level1_nodes_imported():
    db = FakeDb({
        ("users", "u1", "profile", "main"): {
            "name": "Sam Rivera", "birthdate": "1994-02-02",
            "gender": "Woman", "interested_in": ["Men"], "location": "San Jose",
        }
    })
    ov = mig.migrate_profile(db, "u1")
    assert ov["legal_first_name"]["answer"] == "Sam Rivera"
    assert ov["primary_location"]["provenance"] == Provenance.IMPORTED.value
    assert set(ov) == {
        "legal_first_name", "date_of_birth", "gender_identity",
        "target_match_genders", "primary_location",
    }


def test_profile_wins_over_questionnaire_for_derivable_node():
    docs = {
        ("users", "u1", "profile", "main"): {"birthdate": "1990-01-01"},
    }
    docs.update(_q("u1", "date_of_birth", value="2000-12-12", source="stated"))
    db = FakeDb(docs)
    ov = mig.build_overlay(db, "u1")
    assert ov["date_of_birth"]["answer"] == "1990-01-01"  # profile wins
    assert ov["date_of_birth"]["provenance"] == Provenance.IMPORTED.value


# --- wiki / assessment prose ----------------------------------------------


def _patch_story(monkeypatch, story_sections, ai_sections):
    import story
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": story_sections})
    monkeypatch.setattr(story, "get_ai_notes", lambda db, uid: {"sections": ai_sections})
    monkeypatch.setattr(story, "REPORT_LINKED_PAGE_IDS", set(), raising=False)


def test_migrate_wiki_bullets_become_emergent_nodes(monkeypatch):
    _patch_story(
        monkeypatch,
        story_sections=[
            {
                "page_type": "interests", "page_id": "interests",
                "visibility": "public", "body": "I love hiking. I play guitar.",
            }
        ],
        ai_sections=[],
    )
    db = FakeDb()
    ov = mig.migrate_wiki(db, "u1")
    assert len(ov) == 2
    for e in ov.values():
        assert e["section"] == "interests"
        assert e["visibility"] == Visibility.PUBLIC.value
        assert e["provenance"] == Provenance.IMPORTED.value
    # idempotent: re-running yields the same ids
    assert set(mig.migrate_wiki(db, "u1")) == set(ov)


def test_migrate_wiki_dedupes_bullets_from_duplicate_pages(monkeypatch):
    # Scout 2449: 6 bullets rendered twice because duplicate wiki pages (same
    # canonical section, different page_id) each produced the bullet. The graph
    # homes a fact once — identical text in one section collapses to one node.
    _patch_story(
        monkeypatch,
        story_sections=[
            {"page_type": "family", "page_id": "family",
             "visibility": "public", "body": "Grew up in San Jose."},
            {"page_type": "family", "page_id": "family-roots",
             "visibility": "public", "body": "Grew up in San Jose. Two sisters."},
        ],
        ai_sections=[],
    )
    db = FakeDb()
    ov = mig.migrate_wiki(db, "u1")
    texts = sorted(e["answer"] for e in ov.values())
    assert texts == ["Grew up in San Jose.", "Two sisters."]  # no duplicate
    # idempotent still holds with the new id basis
    assert set(mig.migrate_wiki(db, "u1")) == set(ov)


def test_duplicate_bullet_keeps_most_private_tag(monkeypatch):
    # if the same text appears public on one page and private on another, the
    # first occurrence stands and a private copy never silently becomes public.
    _patch_story(
        monkeypatch,
        story_sections=[
            {"page_type": "family", "page_id": "family",
             "visibility": "private", "body": "A tender memory."},
            {"page_type": "family", "page_id": "family-dup",
             "visibility": "public", "body": "A tender memory."},
        ],
        ai_sections=[],
    )
    ov = mig.migrate_wiki(FakeDb(), "u1")
    assert len(ov) == 1
    assert next(iter(ov.values()))["visibility"] == Visibility.PRIVATE.value


def test_migrate_assessment_is_ayma_only_inferred(monkeypatch):
    _patch_story(
        monkeypatch,
        story_sections=[],
        ai_sections=[
            {
                "page_type": "personality", "page_id": "ayma-assessment",
                "visibility": "ai_only", "body": "Tends to avoid conflict.",
            }
        ],
    )
    db = FakeDb()
    ov = mig.migrate_assessment(db, "u1")
    assert len(ov) == 1
    e = next(iter(ov.values()))
    assert e["visibility"] == Visibility.AYMA_ONLY.value
    assert e["provenance"] == Provenance.INFERRED.value


# --- end-to-end: build, write, render --------------------------------------


def test_migrate_user_writes_a_renderable_graph(monkeypatch):
    _patch_story(
        monkeypatch,
        story_sections=[
            {"page_type": "interests", "page_id": "interests",
             "visibility": "public", "body": "I love hiking."},
        ],
        ai_sections=[],
    )
    docs = {
        ("users", "u1", "profile", "main"): {
            "name": "Sam", "birthdate": "1994", "relationship_intent": "Long-term",
        },
    }
    docs.update(_q("u1", "alcohol_consumption", value="Never", source="stated"))
    db = FakeDb(docs)

    mig.migrate_user(db, "u1", write=True)

    g = store.effective(db, "u1")  # intent read from profile
    assert g["date_of_birth"].answer == "1994"
    assert g["alcohol_consumption"].answer == "Never"
    # the migrated story bullet renders in Your Story
    secs = render.story_sections(g)["sections"]
    interests = next(s for s in secs if s["page_type"] == "interests")
    assert any("hiking" in b["text"] for b in interests["bullets"])

    # idempotent: a second run does not duplicate
    before = len(store.load_overlay(db, "u1"))
    mig.migrate_user(db, "u1", write=True)
    assert len(store.load_overlay(db, "u1")) == before
