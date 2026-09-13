import story
from skills import make_session_tool_fns, session_tool_declarations


def test_story_tools_only_exposed_with_story_flag():
    base = {d["name"] for d in session_tool_declarations()}
    withstory = {d["name"] for d in session_tool_declarations(story=True)}
    added = withstory - base
    assert added == {
        "set_passage_privacy",
        "edit_passage",
        "delete_passage",
        "set_section_privacy",
        "edit_career_timeline_entry",
        "delete_career_timeline_entry",
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


def _bound_timeline(name, db, *, timeline_entry_id):
    ctx = {"page_id": "career", "passage": "", "timeline_entry_id": timeline_entry_id}
    return make_session_tool_fns(db, "u1", story_ctx=ctx)[name]


def test_edit_career_timeline_entry_calls_through_with_only_given_fields(monkeypatch):
    import career_timeline

    calls = {}
    monkeypatch.setattr(
        career_timeline, "edit_entry",
        lambda db, uid, eid, changes: calls.update(eid=eid, changes=changes)
        or "updated that timeline entry",
    )
    fn = _bound_timeline("edit_career_timeline_entry", _Db({}), timeline_entry_id="e1")
    assert fn(end="2024") == "updated that timeline entry"
    assert calls == {"eid": "e1", "changes": {"end": "2024"}}


def test_edit_career_timeline_entry_needs_focus():
    fn = _bound_timeline("edit_career_timeline_entry", _Db({}), timeline_entry_id="")
    assert "no timeline entry" in fn(end="2024")


def test_edit_career_timeline_entry_with_no_changes_says_so():
    fn = _bound_timeline("edit_career_timeline_entry", _Db({}), timeline_entry_id="e1")
    assert "nothing to change" in fn()


def test_delete_career_timeline_entry_calls_through(monkeypatch):
    import career_timeline

    calls = {}
    monkeypatch.setattr(
        career_timeline, "delete_entry",
        lambda db, uid, eid: calls.update(eid=eid) or "removed that timeline entry",
    )
    fn = _bound_timeline("delete_career_timeline_entry", _Db({}), timeline_entry_id="e1")
    assert fn() == "removed that timeline entry"
    assert calls == {"eid": "e1"}


def test_delete_career_timeline_entry_needs_focus():
    fn = _bound_timeline("delete_career_timeline_entry", _Db({}), timeline_entry_id="")
    assert "no timeline entry" in fn()
