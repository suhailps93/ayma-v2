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


# --- private spans (pure) ----------------------------------------------


def test_strip_private_spans_removes_marked_passages():
    body = "I lead backend. {{private}}Laid off in 2024.{{/private}} Back now."
    assert story.strip_private_spans(body) == "I lead backend.  Back now."


def test_apply_span_action_wraps_unwraps_and_deletes():
    body = "one two three"
    priv = story.apply_span_action(body, "two", "private")
    assert priv == "one {{private}}two{{/private}} three"
    pub = story.apply_span_action(priv, "two", "public")
    assert "{{private}}" not in pub and pub == "one two three"
    gone = story.apply_span_action(body, "two ", "delete")
    assert gone == "one three"


def test_apply_span_action_ignores_a_selection_it_cannot_find():
    assert story.apply_span_action("hello world", "xyz", "private") == "hello world"


# --- get ---------------------------------------------------------------


def test_get_story_returns_one_document_sorted_with_skills_last():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="AI on career", user_edits="I lead the analytics team.")
    _page(db, "u1", "identity", page_type="identity", visibility="private",
          ai_body="Name, age, city.")
    _page(db, "u1", "web-findings", page_type="web_findings",
          visibility="private", ai_body="Facts found\n- A talk (2024): x")
    _page(db, "u1", "hidden", page_type="secret", visibility="ai_only",
          ai_body="never shown")

    out = story.get_story(db, "u1")
    ids = [s["page_id"] for s in out["sections"]]
    assert ids == ["identity", "career", "web-findings"]  # ai_only dropped
    assert out["sections"][0]["title"] == "Identity"
    assert out["sections"][1]["body"] == "I lead the analytics team."
    assert out["sections"][-1]["is_skill"] is True


def test_get_story_flags_private_spans_and_visibility():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="", user_edits="Public part. {{private}}secret{{/private}}")
    s = story.get_story(db, "u1")["sections"][0]
    assert s["visibility"] == "public"
    assert s["has_private_spans"] is True


# --- save + versions -------------------------------------------------


def test_save_section_writes_user_edits_and_cuts_a_snapshot():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="AI on career")

    res = story.save_section(db, "u1", "career", "I run a team now.")
    assert _get(db, "u1", "career")["user_edits"] == "I run a team now."
    assert "user_updated_at" in _get(db, "u1", "career")

    versions = story.list_versions(db, "u1")
    assert len(versions) == 1
    assert versions[0]["id"] == res["head_version_id"]
    assert versions[0]["author"] == "user"
    assert versions[0]["changed_sections"] == ["career"]


def test_save_section_can_also_flip_visibility():
    db = FakeDb()
    _page(db, "u1", "values", page_type="values", visibility="private",
          ai_body="AI")
    story.save_section(db, "u1", "values", "Honesty, curiosity.", "public")
    assert _get(db, "u1", "values")["visibility"] == "public"


def test_set_visibility_flips_and_notes_the_snapshot():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="a")
    story.set_visibility(db, "u1", "career", "public")
    assert _get(db, "u1", "career")["visibility"] == "public"
    assert story.list_versions(db, "u1")[0]["note"] == "made Career public"


def test_versions_list_computes_changed_sections_vs_previous():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="a")
    _page(db, "u1", "values", page_type="values", visibility="private",
          ai_body="b")
    story.save_section(db, "u1", "career", "career v1")
    story.save_section(db, "u1", "values", "values v1")
    story.save_section(db, "u1", "career", "career v2")

    versions = story.list_versions(db, "u1")  # newest first
    assert [v["changed_sections"] for v in versions] == [
        ["career"],
        ["values"],
        ["career", "values"],
    ]


# --- span action (write) -------------------------------------------


def test_span_action_marks_a_sentence_private_and_snapshots():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="I lead backend. I was laid off in 2024. Back now.")

    out = story.span_action(db, "u1", "career", "I was laid off in 2024.",
                            "private")
    row = _get(db, "u1", "career")
    assert "{{private}}I was laid off in 2024.{{/private}}" in row["user_edits"]
    assert out["body"] == row["user_edits"]
    assert story.list_versions(db, "u1")[0]["author"] == "user"


# --- edit (no write) ---------------------------------------------


def test_edit_returns_revised_body_and_writes_nothing(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="I am a junior analyst.")
    before = dict(_get(db, "u1", "career"))

    async def _fake(contents, system_prompt, response_schema=None, **kw):
        assert kw.get("feature") == "wiki"
        assert "junior analyst" in contents
        return {"action": "rewrite",
                "revised_body": "I lead the analytics team."}

    monkeypatch.setattr(gemini, "generate_json", _fake)
    out = _run(story.edit_section(
        db, "u1", "career", "junior analyst", "I got promoted"))
    assert out == {"action": "rewrite",
                   "revised_body": "I lead the analytics team."}
    assert _get(db, "u1", "career") == before
    assert story.list_versions(db, "u1") == []


def test_edit_classifies_move_and_remove(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "family", page_type="family", visibility="private",
          ai_body="About my family.")

    async def _move(*a, **k):
        return {"action": "move", "target_visibility": "public"}

    monkeypatch.setattr(gemini, "generate_json", _move)
    assert _run(story.edit_section(
        db, "u1", "family", "x", "make this public")) == {
        "action": "move", "target_visibility": "public"}

    async def _remove(*a, **k):
        return {"action": "remove"}

    monkeypatch.setattr(gemini, "generate_json", _remove)
    assert _run(story.edit_section(
        db, "u1", "family", "x", "drop this")) == {"action": "remove"}


def test_edit_usage_capped(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="x")

    async def _boom(*a, **k):
        raise story.token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(gemini, "generate_json", _boom)
    assert _run(story.edit_section(
        db, "u1", "career", "x", "y")) == {"usage_capped": True}


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
    assert row["ai_body"] == "AI-compiled family notes."  # untouched

    assert [s["page_id"] for s in story.get_story(db, "u1")["sections"]] == []


def test_revert_restores_bodies_but_not_ai_body_or_ai_only_pages():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="AI career")
    _page(db, "u1", "sensitive", page_type="sensitive", visibility="ai_only",
          ai_body="AI only, private forever")

    story.save_section(db, "u1", "career", "career original")
    v1 = story.list_versions(db, "u1")[0]["id"]
    story.save_section(db, "u1", "career", "career changed")

    story.revert(db, "u1", v1)
    assert _get(db, "u1", "career")["user_edits"] == "career original"
    assert _get(db, "u1", "career")["ai_body"] == "AI career"  # untouched
    assert "user_edits" not in _get(db, "u1", "sensitive")
    assert story.list_versions(db, "u1")[0]["note"] == f"reverted to {v1}"


def test_revert_to_a_pre_removal_version_restores_the_section():
    db = FakeDb()
    _page(db, "u1", "family", page_type="family", visibility="private",
          ai_body="AI family")

    story.save_section(db, "u1", "family", "family story text")
    pre_removal = story.list_versions(db, "u1")[0]["id"]

    story.remove_section(db, "u1", "family")
    assert [s["page_id"] for s in story.get_story(db, "u1")["sections"]] == []

    story.revert(db, "u1", pre_removal)
    row = _get(db, "u1", "family")
    assert row["user_hidden"] is False
    assert row["visibility"] == "private"
    assert row["user_edits"] == "family story text"
    assert [s["page_id"] for s in story.get_story(db, "u1")["sections"]] == [
        "family"
    ]


# --- skill sections -> markdown --------------------------------


def test_skill_section_face_analysis_renders_clean_markdown():
    db = FakeDb()
    _page(db, "u1", "face-analysis", page_type="face_analysis",
          visibility="private", ai_body="raw [hair_styling] junk")
    db.docs[("users", "u1", "face_reports", "r1")] = {
        "report": {
            "usable": True,
            "overall_score": 6.9,
            "verdict": "Above average",
            "strengths": ["Strong jaw"],
            "improvements": ["Under-eye shadowing"],
            "recommendations": [
                {"category": "hair_styling", "text": "Use a curl cream."}
            ],
        },
        "image_path": "",
        "created_at": 1000,
    }
    body = story.get_story(db, "u1")["sections"][0]["body"]
    assert "**6.9 / 10** — Above average" in body
    assert "### Strengths" in body
    assert "- **Hair styling:** Use a curl cream." in body
    assert "[hair_styling]" not in body  # no raw tags


# --- wiki_ingest debounce hook -------------------------------


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

    versions = story.list_versions(db, "u1")
    assert len(versions) == 1
    assert versions[0]["author"] == "ayma"
    assert versions[0]["note"] == "learned from a conversation"


# --- public profile strips private spans --------------------


def test_public_profile_strips_private_spans(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(pp, "_photo_url", lambda sp: None)
    monkeypatch.setattr(pp, "_score_for", lambda db, a, b: None)
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}
    _page(db, "her", "values", page_type="values", visibility="public",
          ai_body="I value honesty. {{private}}And I'm broke.{{/private}}")

    view = pp.build(db, "me", "her")
    assert [s["body"] for s in view["pages"]] == ["I value honesty."]
