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
    import story_reads
    # Migration reads the SOURCE wiki via the raw readers (bypassing the graph
    # gate), so the fixtures patch those.
    monkeypatch.setattr(story_reads, "get_story_wiki", lambda db, uid: {"sections": story_sections})
    monkeypatch.setattr(story_reads, "get_ai_notes_wiki", lambda db, uid: {"sections": ai_sections})
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


def test_migrate_wiki_dedupes_bullets_across_different_sections(monkeypatch):
    _patch_story(
        monkeypatch,
        story_sections=[
            {"page_type": "family", "page_id": "family-roots",
             "visibility": "public", "body": "Grew up in San Jose."},
            {"page_type": "location", "page_id": "roots-in-san-jose",
             "visibility": "public", "body": "Grew up in San Jose."},
        ],
        ai_sections=[],
    )
    ov = mig.migrate_wiki(FakeDb(), "u1")
    assert len(ov) == 1
    node = next(iter(ov.values()))
    assert node["section"] == "family"
    assert node["answer"] == "Grew up in San Jose."


def test_migrate_wiki_family_preserves_single_copies_and_collapses_duplicates(monkeypatch):
    # Regression test for NOTE 227: Family 1 private + 5 public bullets migrates
    # all 6 nodes; a duplicate section with 3 overlapping bullets collapses into
    # the existing nodes without dropping the single-copy bullets.
    _patch_story(
        monkeypatch,
        story_sections=[
            {
                "page_type": "family",
                "page_id": "family-roots",
                "visibility": "public",
                "body": (
                    "He talks frequently with his parents today. "
                    "Their warmth, resilience, and steady encouragement have shaped his worldview. "
                    "{{private}}Raised in a close-knit Mexican-American household.{{/private}} "
                    "Raised in a warm and tight-knit Mexican-American family in San Jose. "
                    "Being the first in the family to earn a master's degree was a collective celebration. "
                    "His upbringing instilled in him a deep respect for family traditions."
                ),
            },
            {
                "page_type": "family",
                "page_id": "roots-in-san-jose",
                "visibility": "public",
                "body": (
                    "Raised in a warm and tight-knit Mexican-American family in San Jose. "
                    "Being the first in the family to earn a master's degree was a collective celebration. "
                    "His upbringing instilled in him a deep respect for family traditions."
                ),
            },
            {
                "page_type": "goals",
                "page_id": "goals",
                "visibility": "public",
                "body": "Daniel is actively working to cultivate steady physical fitness.",
            },
        ],
        ai_sections=[],
    )
    ov = mig.migrate_wiki(FakeDb(), "u1")
    fam_nodes = [n for n in ov.values() if n["section"] == "family"]
    assert len(fam_nodes) == 6
    pub_fam = [n for n in fam_nodes if n["visibility"] == Visibility.PUBLIC.value]
    priv_fam = [n for n in fam_nodes if n["visibility"] == Visibility.PRIVATE.value]
    assert len(pub_fam) == 5
    assert len(priv_fam) == 1

    goals_nodes = [n for n in ov.values() if n["section"] == "goals"]
    assert len(goals_nodes) == 1
    assert goals_nodes[0]["answer"] == "Daniel is actively working to cultivate steady physical fitness."
    assert goals_nodes[0]["visibility"] == Visibility.PUBLIC.value


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


def test_migrate_wiki_skips_non_canonical_pages(monkeypatch):
    # Scout 2449 blocker 4: a health/sensitive page (non-canonical page_type)
    # is excluded by the live story (profile_bullets skips it); migration must
    # match — it must not surface under Little Extras.
    _patch_story(
        monkeypatch,
        story_sections=[
            {"page_type": "health", "page_id": "health",
             "visibility": "private", "body": "On a GLP-1 for weight loss."},
            {"page_type": "interests", "page_id": "interests",
             "visibility": "public", "body": "I love hiking."},
        ],
        ai_sections=[],
    )
    ov = mig.migrate_wiki(FakeDb(), "u1")
    texts = [e["answer"] for e in ov.values()]
    assert any("hiking" in t for t in texts)
    assert not any("GLP-1" in t for t in texts)  # health page not surfaced
    assert all(e["section"] in __import__("question_tree").section_meta() for e in ov.values())


def test_migrate_questionnaire_skips_meta_sentinels():
    # Scout 2449 blocker 3 at the source: a "skipped"/"addressed" questionnaire
    # value is not an answer and must not become a node.
    docs = {}
    docs.update(_q("u1", "family_of_origin_narrative", value="skipped", source="stated"))
    docs.update(_q("u1", "sibling_relationship_narrative", value="Close.", source="stated"))
    ov = mig.migrate_questionnaire(FakeDb(docs), "u1")
    assert "sibling_relationship_narrative" in ov
    assert "family_of_origin_narrative" not in ov


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


def test_remigrate_replace_drops_stale_nodes(monkeypatch):
    # Scout: an overlay written by the PRE-dedupe migration still holds stale
    # duplicate ids. A re-migration with replace=True must drop them, leaving
    # exactly the fresh (deduped) node set.
    _patch_story(
        monkeypatch,
        story_sections=[
            {"page_type": "interests", "page_id": "interests",
             "visibility": "public", "body": "I love hiking."},
        ],
        ai_sections=[],
    )
    db = FakeDb({("users", "u1", "profile", "main"): {"relationship_intent": "Long-term"}})
    # a stale node id from the old id scheme, plus a legit migrated answer
    db.docs[("users", "u1", "graph", "main")] = {
        "nodes": {
            "emergent.story.interests.0.stale": {
                "prompt": "I love hiking.", "section": "interests", "level": 2,
                "answer": "I love hiking.", "answer_type": "narrative",
                "visibility": "public", "provenance": "imported",
            },
        }
    }
    mig.migrate_user(db, "u1", write=True, replace=True)
    overlay = store.load_overlay(db, "u1")
    assert "emergent.story.interests.0.stale" not in overlay  # stale id dropped
    # exactly one hiking node remains (the fresh deduped one)
    hiking = [k for k, v in overlay.items() if v.get("answer") == "I love hiking."]
    assert len(hiking) == 1
