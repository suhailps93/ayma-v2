"""Finish the read/write switch — graph-native grounding + writer redirection.

With ``PERSON_GRAPH_READS`` on, staging code neither reads nor writes
``wiki_pages``: the chat/voice grounding block, Your Story, the public profile
and recall render from the graph, and every content writer (skill reports,
steering, taste, the Your Story editor) writes graph nodes. Flag off → today's
wiki paths, unchanged (covered by the existing suites). These tests pin the
flag-on behaviour and prove the wiki is left untouched.
"""

import dataclasses

import config
from config import CONFIG


# --- Firestore fake (tuple-path; graph + wiki + questionnaire) -------------


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


def _wiki_pages(db):
    return {k[-1]: v for k, v in db.docs.items()
            if len(k) == 4 and k[0] == "users" and k[2] == "wiki_pages"}


# --- 1. grounding read (read_wiki_context) ---------------------------------


def _seed_graph(db, uid="u1"):
    """A small migrated graph: a seed answer, an emergent interests fact, an
    ayma_only steering note, an ayma_only assessment note."""
    import person_graph_store as store

    store.set_answer(db, uid, "gender_identity", "Woman")
    store.upsert_fact_node(
        db, uid, "emergent.editor.interests.0", "Loves alpine climbing",
        section="interests", visibility="public",
    )
    store.upsert_fact_node(
        db, uid, "emergent.steering.rules", "Avoid talking about her ex",
        section="misc", visibility="ayma_only", level=1,
    )
    store.upsert_fact_node(
        db, uid, "emergent.assess.live", "Comes across guarded until she trusts you",
        section="personality", visibility="ayma_only", provenance="inferred",
    )


def test_grounding_reads_graph_and_leaves_wiki_untouched(monkeypatch):
    import wiki_query

    db = FakeDb()
    _seed_graph(db)
    # a wiki page that must NOT be read when the flag is on
    db.docs[("users", "u1", "wiki_pages", "interests")] = {
        "page_type": "interests", "ai_body": "STALE WIKI — must not appear",
        "visibility": "public",
    }
    _set_reads(monkeypatch, True)
    out = wiki_query.read_wiki_context(db, "u1", max_chars=9000)
    assert "Loves alpine climbing" in out
    assert "Avoid talking about her ex" in out   # ayma_only folded in
    assert "guarded until she trusts" in out
    assert "STALE WIKI" not in out               # wiki never read


def test_grounding_honours_exclude_page_types(monkeypatch):
    import ai_assessment
    import wiki_query

    db = FakeDb()
    _seed_graph(db)
    _set_reads(monkeypatch, True)
    out = wiki_query.read_wiki_context(
        db, "u1", max_chars=9000,
        exclude_page_types=ai_assessment.EXCLUDED_FROM_CHAT_CONTEXT,
    )
    assert "Loves alpine climbing" in out
    assert "guarded until she trusts" not in out  # assessment excluded


def test_grounding_flag_off_reads_wiki(monkeypatch):
    import wiki_query

    db = FakeDb()
    db.docs[("users", "u1", "wiki_pages", "interests")] = {
        "page_type": "interests", "ai_body": "Collects vinyl", "visibility": "public",
    }
    _set_reads(monkeypatch, False)
    out = wiki_query.read_wiki_context(db, "u1", max_chars=9000)
    assert "Collects vinyl" in out


def test_recall_reads_graph(monkeypatch):
    import wiki_query

    db = FakeDb()
    _seed_graph(db)
    _set_reads(monkeypatch, True)
    out = wiki_query.recall_snippets(db, "u1", "climbing", max_chars=3000)
    assert "Loves alpine climbing" in out


# --- 2. writer redirects ---------------------------------------------------


def test_skill_memory_web_findings_writes_graph_not_wiki(monkeypatch):
    import person_graph_store as store
    import skill_memory

    db = FakeDb()
    _set_reads(monkeypatch, True)
    skill_memory.save_web_findings(db, "u1", {"summary": "Runs a robotics blog"})
    assert not _wiki_pages(db)  # no wiki write
    node = store.node_overlay_entry(db, "u1", "emergent.skill.web_findings")
    assert "robotics blog" in str(node.get("answer"))
    assert node.get("visibility") == "private"


def test_steering_add_rule_writes_graph_and_grounds(monkeypatch):
    import steering_ops
    import wiki_query

    db = FakeDb()
    _set_reads(monkeypatch, True)
    assert steering_ops.add_rule(db, "u1", "keep questions short") == "keep questions short"
    # dedup: same rule again is a no-op that still returns it
    steering_ops.add_rule(db, "u1", "keep questions short")
    assert not _wiki_pages(db)
    out = wiki_query.read_wiki_context(db, "u1", max_chars=9000)
    assert "keep questions short" in out
    assert out.count("keep questions short") == 1


def test_taste_sync_writes_public_taste_node(monkeypatch):
    import person_graph_render as render
    import person_graph_store as store
    from skills import questionnaire

    db = FakeDb()
    # taste questionnaire answers the sync composes from
    for nid, val in (("taste_music", "Radiohead, Bon Iver"),
                     ("taste_film", "Arrival"), ("taste_food", "ramen")):
        db.docs[("users", "u1", "questionnaire", nid)] = {"node_id": nid, "value": val}
    _set_reads(monkeypatch, True)
    questionnaire._sync_taste_page(db, "u1")
    assert not _wiki_pages(db)
    graph = store.effective(db, "u1")
    pub = render.public_sections(graph)
    taste = [s for s in pub if s["page_type"] == "taste"]
    assert taste and any("Music:" in b for b in taste[0]["bullets"])


def test_assessment_writes_off_wiki_doc(monkeypatch):
    import ai_assessment

    db = FakeDb()
    _set_reads(monkeypatch, True)
    ref = ai_assessment._page_ref(db, "u1")
    ref.set({"ai_body": "private judgment"}, merge=True)
    assert ("users", "u1", "assessment", "main") in db.docs
    assert not _wiki_pages(db)


# --- 3. Your Story editor write-back ---------------------------------------


def test_editor_save_bullets_round_trips_and_delete_takes(monkeypatch):
    import profile_bullets

    db = FakeDb()
    _set_reads(monkeypatch, True)
    # add two bullets to interests
    profile_bullets.save_bullets(db, "u1", "interests", [
        {"text": "Climbs every weekend", "visibility": "public"},
        {"text": "Learning the cello", "visibility": "private"},
    ])
    out = profile_bullets.get_bullets(db, "u1")
    interests = [s for s in out["sections"] if s["page_type"] == "interests"][0]
    texts = [b["text"] for b in interests["bullets"]]
    assert "Climbs every weekend" in texts and "Learning the cello" in texts

    # remove one bullet — a save with only the other must drop it
    profile_bullets.save_bullets(db, "u1", "interests", [
        {"text": "Learning the cello", "visibility": "private"},
    ])
    out2 = profile_bullets.get_bullets(db, "u1")
    interests2 = [s for s in out2["sections"] if s["page_type"] == "interests"][0]
    texts2 = [b["text"] for b in interests2["bullets"]]
    assert "Climbs every weekend" not in texts2
    assert "Learning the cello" in texts2
    assert not _wiki_pages(db)


def test_editor_preserves_seed_answers_and_reserved_nodes(monkeypatch):
    import person_graph_store as store
    import profile_bullets

    db = FakeDb()
    _set_reads(monkeypatch, True)
    store.set_answer(db, "u1", "gender_identity", "Woman")  # seed answer in identity
    # a reserved skill node lives in interests and must survive an interests edit
    store.upsert_fact_node(
        db, "u1", "emergent.skill.web_findings", "found online: runs a blog",
        section="interests", visibility="private",
    )
    profile_bullets.save_bullets(db, "u1", "interests", [
        {"text": "Bakes sourdough", "visibility": "public"},
    ])
    # seed answer still present
    assert store.node_overlay_entry(db, "u1", "gender_identity").get("answer") == "Woman"
    # reserved skill node untouched
    assert store.node_overlay_entry(db, "u1", "emergent.skill.web_findings")


def test_story_get_story_renders_graph(monkeypatch):
    import story

    db = FakeDb()
    _set_reads(monkeypatch, True)
    _seed_graph(db)
    out = story.get_story(db, "u1")
    bodies = " ".join(s["body"] for s in out["sections"])
    assert "Loves alpine climbing" in bodies
    # ayma_only steering/assessment never in Your Story
    assert "guarded until she trusts" not in bodies
    assert "Avoid talking about her ex" not in bodies


def test_in_chat_save_and_remove_section_write_graph(monkeypatch):
    """Ayma's in-chat story edit (report_hub → story.save_section /
    set_visibility / remove_section) writes the graph, not the wiki."""
    import person_graph_render as render
    import person_graph_store as store
    import story

    db = FakeDb()
    _set_reads(monkeypatch, True)
    story.save_section(db, "u1", "interests", "Plays jazz piano", visibility="public")
    graph = store.effective(db, "u1")
    pub = render.public_sections(graph)
    assert any("Plays jazz piano" in b for s in pub for b in s["bullets"])
    assert not _wiki_pages(db)

    # make it private, then remove it
    story.set_visibility(db, "u1", "interests", "private")
    assert not any(
        "Plays jazz piano" in b
        for s in render.public_sections(store.effective(db, "u1"))
        for b in s["bullets"]
    )
    story.remove_section(db, "u1", "interests")
    g2 = store.effective(db, "u1")
    assert not any(
        "Plays jazz piano" in (n.answer or "") for n in g2.values()
    )
    assert not _wiki_pages(db)


def test_story_report_nodes_excluded_from_story(monkeypatch):
    import person_graph_store as store
    import story

    db = FakeDb()
    _set_reads(monkeypatch, True)
    store.upsert_fact_node(
        db, "u1", "emergent.skill.web_findings", "found online: a robotics blog",
        section="interests", visibility="private",
    )
    out = story.get_story(db, "u1")
    bodies = " ".join(s["body"] for s in out["sections"])
    assert "robotics blog" not in bodies  # report content stays in its report screen
