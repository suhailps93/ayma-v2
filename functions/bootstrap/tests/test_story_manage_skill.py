"""Tests for the always-on chat story-manage tools (``skills/story_manage.py``):
Ayma editing and soft-removing a section of the user's OWN story from an
ordinary chat, scoped to the authenticated uid."""

import pytest

import story
from skills import make_session_tool_fns, session_tool_declarations


_SECTIONS = [
    {"page_id": "career", "page_type": "career", "title": "Career",
     "body": "I work as a teacher in Austin."},
    {"page_id": "family", "page_type": "family", "title": "Family",
     "body": "Close to my two sisters."},
]


def _story(_db, _uid):
    return {"sections": [dict(s) for s in _SECTIONS]}


def _bound(name, db, uid="u1"):
    return make_session_tool_fns(db, uid)[name]


def test_story_manage_tools_are_always_in_the_text_tool_set():
    base = {d["name"] for d in session_tool_declarations()}
    assert {"edit_story_entry", "remove_story_entry"} <= base


def test_story_manage_tools_are_in_the_voice_tool_set():
    # They live outside _REGISTRY (so not in all_skills()), but are wired into
    # the voice tool set so Ayma can edit/remove a story section on a call too
    # (founder bug 2026-10-28: voice had no edit tool, only navigation).
    import skills

    livekit = pytest.importorskip("livekit.agents")  # noqa: F841 - voice venv only
    tools = skills.make_livekit_tools(object(), "u1")
    names = {t.info.name for t in tools}
    assert {"edit_story_entry", "remove_story_entry"} <= names


def test_edit_story_entry_rewrites_the_matched_section(monkeypatch):
    saved, snaps = {}, []
    monkeypatch.setattr(story, "get_story", _story)
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, **k: saved.update(uid=uid, pid=pid, body=body, k=k),
    )
    monkeypatch.setattr(
        story, "_snapshot_section",
        lambda db, uid, pid, author, note="", **k: snaps.append((uid, pid, note)) or "v1",
    )

    fn = _bound("edit_story_entry", object(), uid="u1")
    out = fn(section="career", new_text="I'm a nurse in Austin now.")

    assert "Career" in out
    assert saved["uid"] == "u1" and saved["pid"] == "career"
    assert saved["body"] == "I'm a nurse in Austin now."
    # hidden spans may be replaced on a full-section rewrite (revertible).
    assert saved["k"].get("allow_hidden_changes") is True
    # the pre-edit state was snapshotted first, so it can be reverted.
    assert snaps and snaps[0][:2] == ("u1", "career")


def test_edit_story_entry_without_new_text_asks_for_wording(monkeypatch):
    monkeypatch.setattr(story, "get_story", _story)
    fn = _bound("edit_story_entry", object())
    assert "wording" in fn(section="career", new_text="   ").lower()


def test_edit_story_entry_resolves_by_topic_keywords(monkeypatch):
    saved = {}
    monkeypatch.setattr(story, "get_story", _story)
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, **k: saved.update(pid=pid),
    )
    monkeypatch.setattr(story, "_snapshot_section", lambda *a, **k: "v1")

    fn = _bound("edit_story_entry", object())
    fn(section="the part about my work", new_text="Changed.")
    assert saved["pid"] == "career"


def test_remove_story_entry_soft_hides_the_matched_section(monkeypatch):
    removed = {}
    monkeypatch.setattr(story, "get_story", _story)
    monkeypatch.setattr(
        story, "remove_section",
        lambda db, uid, pid: removed.update(uid=uid, pid=pid) or {"deleted": True},
    )

    fn = _bound("remove_story_entry", object(), uid="u7")
    out = fn(section="family")

    assert removed == {"uid": "u7", "pid": "family"}
    assert "Family" in out and "bring it back" in out.lower()


def test_ambiguous_section_lists_the_options_instead_of_guessing(monkeypatch):
    monkeypatch.setattr(story, "get_story", _story)

    fn = _bound("remove_story_entry", object())
    # a phrase that keyword-matches neither section → ask which one.
    out = fn(section="something vague")
    assert "Career" in out and "Family" in out


def test_no_sections_yet_is_handled(monkeypatch):
    monkeypatch.setattr(story, "get_story", lambda db, uid: {"sections": []})
    fn = _bound("edit_story_entry", object())
    assert "don't have any" in fn(section="career", new_text="x").lower()
