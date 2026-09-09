import story
from skills import make_session_tool_fns, session_tool_declarations


_SECTIONS = [
    {"page_id": "p_career", "title": "Work & study", "body": "Engineer at X.",
     "visibility": "public"},
    {"page_id": "p_values", "title": "Values", "body": "Family first.",
     "visibility": "private"},
]


def _fns(db):
    return make_session_tool_fns(db, "u1", profile_edit=True)


def test_profile_edit_tools_only_exposed_with_the_flag():
    base = {d["name"] for d in session_tool_declarations()}
    withflag = {d["name"] for d in session_tool_declarations(profile_edit=True)}
    assert withflag - base == {
        "list_profile_sections",
        "edit_profile_section",
        "set_profile_section_visibility",
    }
    # story flag alone must NOT pull them in.
    assert not (
        {d["name"] for d in session_tool_declarations(story=True)} - base
    ) & {"edit_profile_section"}


def test_list_profile_sections(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": _SECTIONS})
    out = _fns(None)["list_profile_sections"]()
    assert "Work & study [public]" in out
    assert "Values [private]" in out


def test_edit_profile_section_by_loose_title_saves_a_version(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": _SECTIONS})
    calls = []
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, visibility=None: calls.append((pid, body)),
    )
    # "work" loosely matches "Work & study".
    msg = _fns(None)["edit_profile_section"](title="work", new_text="New bio.")
    assert calls == [("p_career", "New bio.")]
    assert "Work & study" in msg


def test_edit_profile_section_unknown_title(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": _SECTIONS})
    monkeypatch.setattr(
        story, "save_section",
        lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not save")),
    )
    msg = _fns(None)["edit_profile_section"](title="Pets", new_text="A dog.")
    assert "couldn't find" in msg


def test_set_profile_section_visibility(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": _SECTIONS})
    seen = []
    monkeypatch.setattr(
        story, "set_visibility",
        lambda db, uid, pid, vis: seen.append((pid, vis)),
    )
    msg = _fns(None)["set_profile_section_visibility"](title="Values", public=True)
    assert seen == [("p_values", "public")]
    assert "public now" in msg

    seen.clear()
    _fns(None)["set_profile_section_visibility"](
        title="Work & study", public=False
    )
    assert seen == [("p_career", "private")]
