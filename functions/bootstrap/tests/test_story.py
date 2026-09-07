import asyncio

import gemini
import public_profile as pp
import story
import wiki_ingest
from transcript import Turn


# --- fake Firestore -------------------------------------------------------


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = None if data is None else dict(data)

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store = store
        self.key = key

    @property
    def id(self):
        return self.key[-1]

    def get(self):
        return _Snap(self.key[-1], self.store.docs.get(self.key))

    def set(self, payload, merge=False):
        cur = dict(self.store.docs.get(self.key) or {}) if merge else {}
        cur.update(payload)
        self.store.docs[self.key] = cur

    def delete(self):
        self.store.docs.pop(self.key, None)

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store = store
        self.key = key
        self._filters = []

    def document(self, doc_id=None):
        if doc_id is None:
            self.store.counter += 1
            doc_id = f"auto{self.store.counter:04d}"
        return _DocRef(self.store, self.key + (doc_id,))

    def where(self, field, _op, value):
        self._filters.append((field, value))
        return self

    def stream(self):
        d = len(self.key)
        for k, v in list(self.store.docs.items()):
            if len(k) == d + 1 and k[:d] == self.key and v is not None:
                if all(v.get(f) == val for f, val in self._filters):
                    yield _Snap(k[-1], v)


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.counter = 0

    def collection(self, name):
        return _CollRef(self, (name,))


def _page(db, uid, page_id, **data):
    db.docs[("users", uid, "wiki_pages", page_id)] = data


def _get(db, uid, page_id):
    return db.docs[("users", uid, "wiki_pages", page_id)]


def _run(coro):
    return asyncio.run(coro)


# --- get ---------------------------------------------------------------


def test_get_story_private_and_public_sides():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="AI on career", user_edits="I lead the analytics team.")
    _page(db, "u1", "values", page_type="values", visibility="public",
          ai_body="AI on values", public_body="I care about honesty.")
    _page(db, "u1", "secret", page_type="face_analysis", visibility="ai_only",
          ai_body="never shown")

    priv = story.get_story(db, "u1", "private")
    ids = [s["page_id"] for s in priv["sections"]]
    assert ids == ["career", "values"]  # ai_only dropped
    career = priv["sections"][0]
    assert career["title"] == "Career"
    assert career["body"] == "I lead the analytics team."  # user_edits wins

    pub = story.get_story(db, "u1", "public")
    by_id = {s["page_id"]: s for s in pub["sections"]}
    assert by_id["values"]["body"] == "I care about honesty."
    assert by_id["values"]["needs_seed"] is False
    assert by_id["career"]["body"] == ""
    assert by_id["career"]["needs_seed"] is True  # public, empty public_body


# --- save + versions --------------------------------------------------


def test_save_section_writes_and_cuts_a_snapshot():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="AI on career")

    res = story.save_section(db, "u1", "career", "private", "I run a team now.")
    assert _get(db, "u1", "career")["user_edits"] == "I run a team now."
    assert "user_updated_at" in _get(db, "u1", "career")

    versions = story.list_versions(db, "u1", "private")
    assert len(versions) == 1
    assert versions[0]["id"] == res["head_version_id"]
    assert versions[0]["author"] == "user"
    assert versions[0]["changed_sections"] == ["career"]


def test_save_public_section_sets_public_body_and_seeded():
    db = FakeDb()
    _page(db, "u1", "values", page_type="values", visibility="public",
          ai_body="AI on values")
    story.save_section(db, "u1", "values", "public", "Honesty, curiosity.")
    row = _get(db, "u1", "values")
    assert row["public_body"] == "Honesty, curiosity."
    assert row["public_body_seeded"] is True
    assert story.list_versions(db, "u1", "public")[0]["changed_sections"] == [
        "values"
    ]


def test_versions_list_computes_changed_sections_vs_previous():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="a")
    _page(db, "u1", "values", page_type="values", visibility="private",
          ai_body="b")
    story.save_section(db, "u1", "career", "private", "career v1")
    story.save_section(db, "u1", "values", "private", "values v1")
    story.save_section(db, "u1", "career", "private", "career v2")

    versions = story.list_versions(db, "u1", "private")  # newest first
    assert [v["changed_sections"] for v in versions] == [
        ["career"],            # v3: only career changed
        ["values"],            # v2: only values changed
        ["career", "values"],  # v1: first snapshot -> all sections
    ]


# --- edit (no write) -------------------------------------------------


def test_edit_returns_revised_body_and_writes_nothing(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="I am a junior analyst.")
    before = dict(_get(db, "u1", "career"))

    async def _fake(contents, system_prompt, response_schema=None, **kw):
        assert kw.get("feature") == "wiki"
        assert "junior analyst" in contents
        return {"action": "rewrite", "revised_body": "I lead the analytics team."}

    monkeypatch.setattr(gemini, "generate_json", _fake)
    out = _run(story.edit_section(
        db, "u1", "career", "private", "junior analyst", "I got promoted"))
    assert out == {"action": "rewrite",
                   "revised_body": "I lead the analytics team."}
    assert _get(db, "u1", "career") == before  # nothing written
    assert story.list_versions(db, "u1", "private") == []


def test_edit_classifies_move_and_remove(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "family", page_type="family", visibility="private",
          ai_body="About my family.")

    async def _move(*a, **k):
        return {"action": "move", "target_side": "public"}

    monkeypatch.setattr(gemini, "generate_json", _move)
    assert _run(story.edit_section(
        db, "u1", "family", "private", "x", "make this public")) == {
        "action": "move", "target_side": "public"}

    async def _remove(*a, **k):
        return {"action": "remove"}

    monkeypatch.setattr(gemini, "generate_json", _remove)
    assert _run(story.edit_section(
        db, "u1", "family", "private", "x", "drop this")) == {"action": "remove"}


def test_edit_usage_capped(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="x")

    async def _boom(*a, **k):
        raise story.token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(gemini, "generate_json", _boom)
    assert _run(story.edit_section(
        db, "u1", "career", "private", "x", "y")) == {"usage_capped": True}


# --- seed public ---------------------------------------------------


def test_seed_public_writes_public_body(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "values", page_type="values", visibility="public",
          ai_body="Long private thing incl. a medical detail.")

    async def _fake(contents, system_prompt, response_schema=None, **kw):
        assert kw.get("feature") == "wiki"
        return {"draft": "I value honesty and curiosity."}

    monkeypatch.setattr(gemini, "generate_json", _fake)
    out = _run(story.seed_public(db, "u1", "values"))
    assert out == {"draft": "I value honesty and curiosity."}
    row = _get(db, "u1", "values")
    assert row["public_body"] == "I value honesty and curiosity."
    assert row["public_body_seeded"] is True
    # seed alone does not cut a version
    assert story.list_versions(db, "u1", "public") == []


# --- move --------------------------------------------------------


def test_move_public_to_private_merges_text_and_flips_visibility():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="AI", user_edits="Private career note.",
          public_body="Public career blurb.", public_body_seeded=True)

    res = _run(story.move_section(db, "u1", "career", "private"))
    row = _get(db, "u1", "career")
    assert row["visibility"] == "private"
    assert row["user_edits"] == "Private career note.\n\nPublic career blurb."
    assert row["public_body"] == ""
    assert row["public_body_seeded"] is False
    # a snapshot on each affected side
    assert res["head_version_id"]
    assert story.list_versions(db, "u1", "private")[0]["note"] == (
        "moved Career to private")
    assert story.list_versions(db, "u1", "public")[0]["note"] == (
        "moved Career to private")


# --- remove + revert -------------------------------------------


def test_remove_sets_ai_only_and_hidden_but_keeps_ai_body():
    db = FakeDb()
    _page(db, "u1", "family", page_type="family", visibility="private",
          ai_body="AI-compiled family notes.", user_edits="My edit.")

    story.remove_section(db, "u1", "family")
    row = _get(db, "u1", "family")
    assert row["visibility"] == "ai_only"
    assert row["user_hidden"] is True
    assert row["user_edits"] == ""
    assert row["public_body"] == ""
    assert row["ai_body"] == "AI-compiled family notes."  # untouched

    # gone from the editor
    assert [s["page_id"] for s in story.get_story(
        db, "u1", "private")["sections"]] == []


def test_revert_restores_bodies_but_not_ai_body_or_ai_only_pages():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="AI career")
    _page(db, "u1", "sensitive", page_type="sensitive", visibility="ai_only",
          ai_body="AI only, private forever")

    story.save_section(db, "u1", "career", "private", "career original")
    v1 = story.list_versions(db, "u1", "private")[0]["id"]
    story.save_section(db, "u1", "career", "private", "career changed")

    story.revert(db, "u1", v1, "private")
    assert _get(db, "u1", "career")["user_edits"] == "career original"
    assert _get(db, "u1", "career")["ai_body"] == "AI career"  # untouched
    # ai_only page never gained user_edits / public_body
    assert "user_edits" not in _get(db, "u1", "sensitive")
    assert story.list_versions(db, "u1", "private")[0]["note"] == (
        f"reverted to {v1}")


def test_revert_to_a_pre_removal_version_restores_the_section():
    db = FakeDb()
    _page(db, "u1", "family", page_type="family", visibility="private",
          ai_body="AI family")

    story.save_section(db, "u1", "family", "private", "family story text")
    pre_removal = story.list_versions(db, "u1", "private")[0]["id"]

    story.remove_section(db, "u1", "family")
    assert [s["page_id"] for s in story.get_story(
        db, "u1", "private")["sections"]] == []

    story.revert(db, "u1", pre_removal, "private")
    row = _get(db, "u1", "family")
    assert row["user_hidden"] is False
    assert row["visibility"] == "private"
    assert row["user_edits"] == "family story text"
    assert [s["page_id"] for s in story.get_story(
        db, "u1", "private")["sections"]] == ["family"]


# --- wiki_ingest debounce hook ----------------------------------


def test_wiki_ingest_ai_snapshots_are_debounced(monkeypatch):
    db = FakeDb()
    bodies = iter(["First compiled body.", "Second, different body."])

    async def _fake_json(contents, system_prompt, response_schema=None, **kw):
        return {"pages": [{
            "page_id": "career", "page_type": "career",
            "visibility": "private", "ai_body": next(bodies),
        }]}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    _run(wiki_ingest.ingest(db, "u1", "s1", [Turn("user", "I lead a team")]))
    _run(wiki_ingest.ingest(db, "u1", "s2", [Turn("user", "actually I direct")]))

    versions = story.list_versions(db, "u1", "private")
    assert len(versions) == 1  # second ai change debounced
    assert versions[0]["author"] == "ayma"
    assert versions[0]["note"] == "learned from a conversation"


# --- public profile renders public_body ------------------------


def test_public_profile_renders_public_body_not_the_private_narrative(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(pp, "_photo_url", lambda sp: None)
    monkeypatch.setattr(pp, "_score_for", lambda db, a, b: None)
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}
    _page(db, "her", "values", page_type="values", visibility="public",
          ai_body="Private narrative with sensitive detail.",
          public_body="I value honesty.")

    view = pp.build(db, "me", "her")
    assert [s["body"] for s in view["pages"]] == ["I value honesty."]
