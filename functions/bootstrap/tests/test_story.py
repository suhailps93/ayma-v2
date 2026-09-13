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


# --- get ---------------------------------------------------------------


def test_get_story_returns_sections_sorted_with_skills_last():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="AI on career", user_edits="I lead the analytics team.")
    _page(db, "u1", "identity", page_type="identity", visibility="public",
          ai_body="Name, age, city.")
    _page(db, "u1", "web-findings", page_type="web_findings",
          visibility="private", ai_body="Facts found\n- A talk (2024): x")
    _page(db, "u1", "hidden", page_type="secret", visibility="ai_only",
          ai_body="never shown")

    out = story.get_story(db, "u1")
    assert "head_version_id" not in out
    ids = [s["page_id"] for s in out["sections"]]
    assert ids == ["identity", "career", "web-findings"]  # ai_only dropped
    assert out["sections"][-1]["is_skill"] is True


def test_get_ai_notes_returns_every_page_with_its_real_visibility():
    # "AI notes" is a superset of "Everything": every page the user has,
    # any visibility, each carrying its own real visibility (not forced).
    db = FakeDb()
    _page(db, "u1", "steering", page_type="steering", visibility="ai_only",
          ai_body="- keep it brief")
    _page(db, "u1", "sensitive", page_type="sensitive", visibility="ai_only",
          ai_body="never shown to the user elsewhere, but AI notes is the "
                  "one place it's allowed to surface")
    _page(db, "u1", "career", page_type="career", visibility="private",
          ai_body="AI on career", user_edits="I lead the analytics team.")
    _page(db, "u1", "identity", page_type="identity", visibility="public",
          ai_body="Name, age, city.")

    out = story.get_ai_notes(db, "u1")
    by_id = {s["page_id"]: s for s in out["sections"]}
    assert set(by_id) == {"steering", "sensitive", "career", "identity"}
    assert by_id["steering"]["visibility"] == "ai_only"
    assert by_id["sensitive"]["visibility"] == "ai_only"
    assert by_id["career"]["visibility"] == "private"
    assert by_id["identity"]["visibility"] == "public"
    # Same rich shape get_story() produces.
    assert by_id["career"]["body"] == "I lead the analytics team."
    assert by_id["career"]["user_edited"] is True
    assert by_id["steering"]["title"] == "Steering"  # humanize(page_type), same as get_story


def test_get_ai_notes_excludes_only_user_hidden_pages():
    db = FakeDb()
    _page(db, "u1", "steering", page_type="steering", visibility="ai_only",
          ai_body="- keep it brief")
    _page(db, "u1", "old-note", page_type="misc", visibility="private",
          ai_body="stale", user_hidden=True)

    out = story.get_ai_notes(db, "u1")
    ids = {s["page_id"] for s in out["sections"]}
    assert ids == {"steering"}
    assert "old-note" not in ids


# --- report_id (§ Your Story report links) -----------------------------


def test_ordinary_pages_carry_no_report_id_key():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="AI on career")
    out = story.get_story(db, "u1")
    assert "report_id" not in out["sections"][0]


def test_appearance_linked_pages_get_report_id_when_a_report_exists():
    db = FakeDb()
    _page(db, "u1", "face-analysis", page_type="face_analysis",
          visibility="private", ai_body="Overall 6/10 — average.")
    _page(db, "u1", "body-analysis", page_type="body_analysis",
          visibility="private", ai_body="Overall 7/10 — good.")
    _page(db, "u1", "physical-profile", page_type="physical_profile",
          visibility="private", ai_body="- Height: ~180cm (from photos)")
    db.docs[("users", "u1", "appearance", "current")] = {"report_id": "rep123"}

    out = story.get_story(db, "u1")
    by_id = {s["page_id"]: s for s in out["sections"]}
    assert by_id["face-analysis"]["report_id"] == "rep123"
    assert by_id["body-analysis"]["report_id"] == "rep123"
    assert by_id["physical-profile"]["report_id"] == "rep123"


def test_appearance_linked_pages_have_null_report_id_before_any_report_runs():
    # A wiki page can carry real content (e.g. from background auto-analysis)
    # well before the user ever runs the explicit Appearance skill.
    db = FakeDb()
    _page(db, "u1", "face-analysis", page_type="face_analysis",
          visibility="private", ai_body="Overall 6/10 — average.")

    out = story.get_story(db, "u1")
    section = out["sections"][0]
    assert section["page_id"] == "face-analysis"
    assert section["report_id"] is None


def test_web_findings_report_id_from_the_self_deep_dive():
    db = FakeDb()
    _page(db, "u1", "web-findings", page_type="web_findings",
          visibility="private", ai_body="Facts found\n- A talk (2024): x")
    db.docs[("users", "u1", "deep_dives", "uid_u1")] = {
        "digest": {"name": "Alex"},
        "target_uid": "u1",
    }

    out = story.get_story(db, "u1")
    section = out["sections"][0]
    assert section["page_id"] == "web-findings"
    assert section["report_id"] == "uid_u1"


def test_web_findings_report_id_is_null_before_any_dive_runs():
    db = FakeDb()
    _page(db, "u1", "web-findings", page_type="web_findings",
          visibility="private", ai_body="Facts found\n- A talk (2024): x")

    out = story.get_story(db, "u1")
    assert out["sections"][0]["report_id"] is None


# --- save + per-section history --------------------------------------


def test_save_section_commits_a_version_to_that_sections_history():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="AI on career")

    res = story.save_section(db, "u1", "career", "I run a team now.")
    assert _get(db, "u1", "career")["user_edits"] == "I run a team now."

    hist = story.list_section_versions(db, "u1", "career")
    assert len(hist) == 1
    assert hist[0]["id"] == res["head_version_id"]
    assert hist[0]["author"] == "user"
    v = story.get_section_version(db, "u1", "career", hist[0]["id"])
    assert v["body"] == "I run a team now."
    assert v["visibility"] == "public"

    # a different section has its own, empty history
    _page(db, "u1", "values", page_type="values", visibility="public",
          ai_body="x")
    assert story.list_section_versions(db, "u1", "values") == []


def test_set_visibility_flips_and_notes_the_version():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="a")
    story.set_visibility(db, "u1", "career", "private")
    assert _get(db, "u1", "career")["visibility"] == "private"
    assert story.list_section_versions(db, "u1", "career")[0]["note"] == (
        "made Career private")


# --- remove + revert (per section) --------------------------------


def test_remove_keeps_ai_body_and_leaves_a_recoverable_version():
    db = FakeDb()
    _page(db, "u1", "family", page_type="family", visibility="public",
          ai_body="AI-compiled family notes.", user_edits="Close with my sister.")

    story.remove_section(db, "u1", "family")
    row = _get(db, "u1", "family")
    assert row["visibility"] == "ai_only"
    assert row["user_hidden"] is True
    assert row["user_edits"] == ""
    assert row["ai_body"] == "AI-compiled family notes."  # untouched
    assert [s["page_id"] for s in story.get_story(db, "u1")["sections"]] == []

    hist = story.list_section_versions(db, "u1", "family")
    assert hist and "deleted" in hist[0]["note"]
    assert story.get_section_version(
        db, "u1", "family", hist[0]["id"])["body"] == "Close with my sister."


def test_revert_section_restores_body_and_visibility_not_ai_body():
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="AI career")

    story.save_section(db, "u1", "career", "career original", "private")
    v1 = story.list_section_versions(db, "u1", "career")[0]["id"]
    story.save_section(db, "u1", "career", "career changed", "public")

    story.revert_section(db, "u1", "career", v1)
    row = _get(db, "u1", "career")
    assert row["user_edits"] == "career original"
    assert row["visibility"] == "private"
    assert row["ai_body"] == "AI career"  # untouched
    assert story.list_section_versions(db, "u1", "career")[0]["note"] == (
        f"reverted to {v1}")


def test_revert_to_a_pre_removal_version_brings_the_section_back():
    db = FakeDb()
    _page(db, "u1", "family", page_type="family", visibility="public",
          ai_body="AI family")

    story.save_section(db, "u1", "family", "family story text")
    pre_removal = story.list_section_versions(db, "u1", "family")[0]["id"]
    story.remove_section(db, "u1", "family")
    assert [s["page_id"] for s in story.get_story(db, "u1")["sections"]] == []

    story.revert_section(db, "u1", "family", pre_removal)
    row = _get(db, "u1", "family")
    assert row["user_hidden"] is False
    assert row["visibility"] == "public"
    assert row["user_edits"] == "family story text"
    assert [s["page_id"] for s in story.get_story(db, "u1")["sections"]] == [
        "family"
    ]


# --- passage chat -------------------------------------------------


def test_edit_section_chats_and_can_propose_a_revised_body(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="I am a junior analyst in Lisbon.")
    before = dict(_get(db, "u1", "career"))

    async def _fake(contents, system_prompt, response_schema=None, **kw):
        assert kw.get("feature") == "wiki"
        assert "junior analyst" in contents
        assert "Them: I got promoted" in contents
        return {
            "reply": "Nice — want it to say you lead the team now?",
            "revised_body": "I lead the analytics team in Lisbon.",
            "action": "chat",
        }

    monkeypatch.setattr(gemini, "generate_json", _fake)
    out = _run(story.edit_section(
        db, "u1", "career", "junior analyst",
        [{"role": "user", "text": "I got promoted"}]))
    assert out["reply"].startswith("Nice")
    assert out["revised_body"] == "I lead the analytics team in Lisbon."
    assert out["action"] == "chat"
    assert _get(db, "u1", "career") == before  # nothing written


def test_edit_section_classifies_move_and_remove(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "family", page_type="family", visibility="public",
          ai_body="About my family.")

    async def _move(*a, **k):
        return {"reply": "Making it private.", "action": "move",
                "target_visibility": "private"}

    monkeypatch.setattr(gemini, "generate_json", _move)
    out = _run(story.edit_section(db, "u1", "family", "x", []))
    assert out["action"] == "move" and out["target_visibility"] == "private"

    async def _remove(*a, **k):
        return {"reply": "Gone.", "action": "remove"}

    monkeypatch.setattr(gemini, "generate_json", _remove)
    assert _run(story.edit_section(
        db, "u1", "family", "x", []))["action"] == "remove"


def test_edit_section_span_privatises_only_the_highlighted_passage(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="I lead a team. My salary is 200k. I ship robots.")

    async def _span(*a, **k):
        return {"reply": "Hiding that.", "action": "span",
                "span_action": "private"}

    monkeypatch.setattr(gemini, "generate_json", _span)
    out = _run(story.edit_section(
        db, "u1", "career", "My salary is 200k.",
        [{"role": "user", "text": "make that line private"}]))
    assert out["action"] == "span"
    assert out["span_action"] == "private"
    # exactly the passage is wrapped; the rest is untouched
    assert out["revised_body"] == (
        "I lead a team. {{private}}My salary is 200k.{{/private}} "
        "I ship robots."
    )
    assert _get(db, "u1", "career")["visibility"] == "public"  # section unchanged


def test_edit_section_downgrades_a_passage_level_move_to_span(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="I lead a team. My salary is 200k. I ship robots.")

    # The model mislabels a passage privacy change as a whole-section "move".
    async def _bad_move(*a, **k):
        return {"reply": "ok", "action": "move", "target_visibility": "private"}

    monkeypatch.setattr(gemini, "generate_json", _bad_move)
    out = _run(story.edit_section(
        db, "u1", "career", "My salary is 200k.", []))
    assert out["action"] == "span"
    assert "{{private}}My salary is 200k.{{/private}}" in out["revised_body"]
    assert _get(db, "u1", "career")["visibility"] == "public"


def test_edit_section_usage_capped(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="x")

    async def _boom(*a, **k):
        raise story.token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(gemini, "generate_json", _boom)
    assert _run(story.edit_section(
        db, "u1", "career", "x", []))["usage_capped"] is True


# --- skill sections -> markdown --------------------------------


def test_skill_section_face_analysis_shows_its_own_ai_body_verbatim():
    # face-analysis/body-analysis show the page's own maintained ai_body
    # (skill_memory's accumulated write — median score, feature breakdown,
    # strengths/recommendations) — never re-derived from the separate,
    # single-latest ``face_reports``/``body_reports`` doc, even when one
    # exists with different content, and never with a photo markdown tag
    # (Story's SelectableMarkdown doesn't render markdown images).
    db = FakeDb()
    _page(db, "u1", "face-analysis", page_type="face_analysis",
          visibility="private",
          ai_body="**6.5 / 10 median across 3 reads**\n\nStrong jaw.")
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
        "image_path": "some/photo.jpg",
        "created_at": 1000,
    }
    body = story.get_story(db, "u1")["sections"][0]["body"]
    assert body == "**6.5 / 10 median across 3 reads**\n\nStrong jaw."
    assert "![](" not in body
    assert "Above average" not in body  # face_reports content must not leak in


# --- wiki_ingest per-section debounce -------------------------


def test_wiki_ingest_ai_section_versions_are_debounced(monkeypatch):
    db = FakeDb()
    bodies = iter(["First compiled body.", "Second, different body."])

    async def _fake_json(contents, system_prompt, response_schema=None, **kw):
        return {"pages": [{
            "page_id": "career", "page_type": "career",
            "visibility": "public", "ai_body": next(bodies),
        }]}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    _run(wiki_ingest.ingest(db, "u1", "s1", [Turn("user", "I lead a team")]))
    _run(wiki_ingest.ingest(db, "u1", "s2", [Turn("user", "actually I direct")]))

    hist = story.list_section_versions(db, "u1", "career")
    assert len(hist) == 1  # second AI change debounced
    assert hist[0]["author"] == "ayma"
    assert hist[0]["note"] == "learned from a conversation"


def test_wiki_ingest_skips_ai_version_when_the_user_has_overridden(monkeypatch):
    db = FakeDb()
    _page(db, "u1", "career", page_type="career", visibility="public",
          ai_body="old", user_edits="my own words", user_updated_at="t")

    async def _fake_json(contents, system_prompt, response_schema=None, **kw):
        return {"pages": [{
            "page_id": "career", "page_type": "career",
            "visibility": "public", "ai_body": "brand new compiled body",
        }]}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    _run(wiki_ingest.ingest(db, "u1", "s1", [Turn("user", "hi")]))
    # ai_body moved but the user's body is what shows -> no version cut
    assert story.list_section_versions(db, "u1", "career") == []


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
