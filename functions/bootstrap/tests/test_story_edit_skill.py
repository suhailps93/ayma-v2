import story
from skills import make_session_tool_fns, session_tool_declarations


def test_story_tools_only_exposed_with_story_flag():
    base = {d["name"] for d in session_tool_declarations()}
    withstory = {d["name"] for d in session_tool_declarations(story=True)}
    added = withstory - base
    assert added == {
        "set_passage_privacy",
        "edit_passage",
        "remove_from_profile",
        "set_section_privacy",
    }


class _PageRef:
    def __init__(self, data):
        self._data = data


class _Snap:
    def __init__(self, data):
        self._data = data
        self.exists = data is not None
        self.reference = _PageRef(data)

    def to_dict(self):
        return dict(self._data or {})


class _Doc:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def collection(self, _n):
        return self

    def document(self, key):
        return _Doc(self.store, key)

    def get(self):
        return _Snap(self.store.get(self.key))

    def set(self, patch, merge=False):  # noqa: ARG002
        self.store[self.key] = {**(self.store.get(self.key) or {}), **patch}


class _Db:
    def __init__(self, store):
        self.store = store

    def collection(self, _n):
        return _Doc(self.store, None)


def _bound(name, db, *, page_id, passage):
    ctx = {"page_id": page_id, "passage": passage}
    return make_session_tool_fns(db, "u1", story_ctx=ctx)[name]


def test_set_passage_privacy_wraps_only_the_passage(monkeypatch):
    saved = {}
    monkeypatch.setattr(
        story, "_require_page",
        lambda db, uid, pid: (None, {"ai_body": "A. Secret line. B."}),
    )
    monkeypatch.setattr(
        story, "_display_body", lambda db, uid, pid, data: "A. Secret line. B."
    )
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, **k: saved.update(pid=pid, body=body),
    )

    fn = _bound("set_passage_privacy", _Db({}), page_id="p1",
               passage="Secret line.")
    assert fn(private=True) == "made that private"
    assert saved["body"] == "A. {{private}}Secret line.{{/private}} B."


def test_edit_passage_replaces_just_the_span(monkeypatch):
    saved = {}
    monkeypatch.setattr(
        story, "_require_page", lambda *a: (None, {"ai_body": "keep this now."})
    )
    monkeypatch.setattr(
        story, "_display_body", lambda *a: "keep this now."
    )
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, **k: saved.update(body=body),
    )
    fn = _bound("edit_passage", _Db({}), page_id="p1", passage="this now")
    assert fn(new_text="that later") == "updated that passage"
    assert saved["body"] == "keep that later."


def test_edit_passage_declaration_guides_rewrite_in_my_tone():
    # NOTE 251 item 3: the "Rewrite in my tone" chip sends a reword request; the
    # tool must tell the model what "my tone" means (the user's own first-person
    # voice) and to always return the finished text, so it never fails to edit.
    from skills import story_edit

    desc = story_edit._EDIT_DECL["description"].lower()
    assert "rewrite in my tone" in desc
    assert "first-person" in desc and "voice" in desc


def test_edit_passage_applies_a_tone_rewrite_like_any_other(monkeypatch):
    # The tone rewrite is just an edit_passage call with the rewritten text.
    saved = {}
    monkeypatch.setattr(
        story, "_require_page", lambda *a: (None, {"ai_body": "I am an analyst."})
    )
    monkeypatch.setattr(story, "_display_body", lambda *a: "I am an analyst.")
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, **k: saved.update(body=body),
    )
    fn = _bound("edit_passage", _Db({}), page_id="p1", passage="I am an analyst.")
    assert fn(new_text="Honestly? I crunch numbers all day and love it.") \
        == "updated that passage"
    assert saved["body"] == "Honestly? I crunch numbers all day and love it."


def test_remove_from_profile_wraps_ai_only_instead_of_deleting(monkeypatch):
    saved = {}
    monkeypatch.setattr(
        story, "_require_page",
        lambda db, uid, pid: (None, {"ai_body": "A. Secret line. B."}),
    )
    monkeypatch.setattr(
        story, "_display_body", lambda db, uid, pid, data: "A. Secret line. B."
    )
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, **k: saved.update(pid=pid, body=body),
    )

    fn = _bound("remove_from_profile", _Db({}), page_id="p1",
               passage="Secret line.")
    result = fn()
    assert "profile" in result
    # Kept, not removed — wrapped as ai_only so it survives into Ayma's Notes.
    assert saved["body"] == "A. {{ai_only}}Secret line.{{/ai_only}} B."
    # The passage is gone from the normal Story view...
    assert "Secret line." not in story.strip_ai_only_spans(saved["body"])
    # ...and from the public view too.
    assert "Secret line." not in story.strip_private_spans(saved["body"])


def test_passage_tools_need_a_highlight():
    fn = _bound("set_passage_privacy", _Db({}), page_id="p1", passage="")
    assert "highlight" in fn(private=True)


def test_set_section_privacy_flips_the_whole_section(monkeypatch):
    calls = {}
    monkeypatch.setattr(
        story, "set_visibility",
        lambda db, uid, pid, vis: calls.update(pid=pid, vis=vis),
    )
    fn = _bound("set_section_privacy", _Db({}), page_id="p1", passage="x")
    assert "private" in fn(private=True)
    assert calls == {"pid": "p1", "vis": "private"}


# --- career-timeline entry tools (scoped by timeline_entry_id, not a passage) --
