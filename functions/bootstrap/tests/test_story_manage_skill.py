"""Tests for the always-on chat story-manage tools (``skills/story_manage.py``):
Ayma editing and soft-removing a section of the user's OWN story from an
ordinary chat, scoped to the authenticated uid.

The edit is **surgical**: ``edit_story_entry`` changes only the one line the
user references and leaves every other line of the section byte-for-byte, and a
line it can't confidently locate is never overwritten — it asks which one
(founder bug 2026-10-28). A user-requested edit also applies in place: it is
never re-surfaced as a pending "Public profile updates" Apply/Dismiss card."""

import pytest

import profile_manual as pm
import story
import wiki_ingest
from fake_firestore import FakeDb
from skills import make_session_tool_fns, session_tool_declarations

# A multi-line career section: the surgical tests prove only ONE of these lines
# ever changes.
_CAREER_BODY = (
    "I work as a teacher in Austin.\n"
    "I did my bachelor of technology in a CMS.\n"
    "I volunteer on weekends."
)

_SECTIONS = [
    {"page_id": "career", "page_type": "career", "title": "Career",
     "body": _CAREER_BODY, "edit_body": _CAREER_BODY},
    {"page_id": "family", "page_type": "family", "title": "Family",
     "body": "Close to my two sisters.",
     "edit_body": "Close to my two sisters."},
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


def test_edit_story_entry_changes_only_the_referenced_line(monkeypatch):
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
    out = fn(
        section="career",
        find_text="I did my bachelor of technology in a CMS",
        new_text="I did my BTech in Mahatma Gandhi University",
    )

    assert "Career" in out and "Mahatma Gandhi University" in out
    assert saved["uid"] == "u1" and saved["pid"] == "career"
    # ONLY the targeted line changed; the other two are byte-for-byte unchanged.
    assert saved["body"] == (
        "I work as a teacher in Austin.\n"
        "I did my BTech in Mahatma Gandhi University.\n"
        "I volunteer on weekends."
    )
    lines = saved["body"].split("\n")
    assert lines[0] == "I work as a teacher in Austin."
    assert lines[2] == "I volunteer on weekends."
    # hidden spans may be replaced on the save (revertible).
    assert saved["k"].get("allow_hidden_changes") is True
    # the pre-edit state was snapshotted first, so it can be reverted.
    assert snaps and snaps[0][:2] == ("u1", "career")


def test_edit_story_entry_without_new_text_asks_for_wording(monkeypatch):
    monkeypatch.setattr(story, "get_story", _story)
    fn = _bound("edit_story_entry", object())
    out = fn(section="career", find_text="I volunteer on weekends", new_text="   ")
    assert "wording" in out.lower()


def test_edit_story_entry_resolves_the_section_by_topic_keywords(monkeypatch):
    saved = {}
    monkeypatch.setattr(story, "get_story", _story)
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, **k: saved.update(pid=pid, body=body),
    )
    monkeypatch.setattr(story, "_snapshot_section", lambda *a, **k: "v1")

    fn = _bound("edit_story_entry", object())
    fn(
        section="the part about my work",
        find_text="I work as a teacher in Austin",
        new_text="I manage a bakery in Austin",
    )
    assert saved["pid"] == "career"
    assert saved["body"].startswith("I manage a bakery in Austin.")
    assert "I volunteer on weekends." in saved["body"]


def test_edit_story_entry_unmatched_line_asks_and_does_not_overwrite(monkeypatch):
    calls = []
    monkeypatch.setattr(story, "get_story", _story)
    monkeypatch.setattr(story, "save_section", lambda *a, **k: calls.append(a))
    monkeypatch.setattr(story, "_snapshot_section", lambda *a, **k: calls.append(a))

    fn = _bound("edit_story_entry", object())
    out = fn(
        section="career",
        find_text="my favourite colour is turquoise",
        new_text="whatever",
    )
    assert not calls  # nothing was written — no broad overwrite
    assert "couldn't find" in out.lower() and "which" in out.lower()


# A single-paragraph, multi-sentence section like the real "Identity" section
# (founder bug 2026-10-28, 3rd report). The whole paragraph is one line, so the
# whole body is itself a match candidate — the regressions below prove the
# model can't make a one-line edit wipe it.
_IDENTITY_BODY = (
    "His full name is Suhail. Born in Dubai, he moved to Kerala at age five. "
    "After college he moved to the United States for graduate studies. "
    "He currently lives in San Jose and speaks Malayalam and English."
)
_IDENTITY_FIXED = _IDENTITY_BODY.replace(
    "Malayalam and English", "Malayalam, English, Hindi, and Tamil"
)


def _identity(_db, _uid):
    return {"sections": [{"page_id": "identity", "page_type": "identity",
                          "title": "Identity", "body": _IDENTITY_BODY,
                          "edit_body": _IDENTITY_BODY}]}


@pytest.mark.parametrize(
    "find_text, new_text",
    [
        # The model read the section back and passed the WHOLE paragraph as
        # find_text + a whole-section rewrite as new_text (the real voice bug).
        (_IDENTITY_BODY, _IDENTITY_FIXED),
        # ...or passed the whole rewrite with NO find_text at all.
        ("", _IDENTITY_FIXED),
        # ...or targeted the right line but still handed a whole-section rewrite.
        ("I speak Malayalam and English", _IDENTITY_FIXED),
    ],
)
def test_edit_story_entry_never_overwrites_the_whole_section(
    monkeypatch, find_text, new_text
):
    saved, snaps = {}, []
    monkeypatch.setattr(story, "get_story", _identity)
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, **k: saved.update(pid=pid, body=body),
    )
    monkeypatch.setattr(story, "_snapshot_section", lambda *a, **k: snaps.append(a) or "v1")

    fn = _bound("edit_story_entry", object())
    out = fn(section="identity", find_text=find_text, new_text=new_text)

    # Only the one line changed — every OTHER sentence is byte-for-byte intact,
    # and the section was NOT replaced by the rewrite wholesale.
    assert saved.get("body") == _IDENTITY_FIXED
    assert "His full name is Suhail." in saved["body"]
    assert "Born in Dubai, he moved to Kerala at age five." in saved["body"]
    assert "for graduate studies." in saved["body"]
    assert "Malayalam, English, Hindi, and Tamil" in saved["body"]
    assert "Identity" in out


def test_edit_story_entry_refuses_a_full_rewrite_instead_of_wiping(monkeypatch):
    calls = []
    monkeypatch.setattr(story, "get_story", _identity)
    monkeypatch.setattr(story, "save_section", lambda *a, **k: calls.append(a))
    monkeypatch.setattr(story, "_snapshot_section", lambda *a, **k: calls.append(a))

    fn = _bound("edit_story_entry", object())
    # Every sentence differs → this is a rewrite, not a one-line edit.
    out = fn(
        section="identity",
        find_text="",
        new_text=(
            "She is a doctor in Boston. She grew up in Canada. "
            "She loves skiing. She has two dogs."
        ),
    )
    assert not calls  # nothing written — the section is not wiped
    assert "one-line" in out.lower() or "which" in out.lower()


def test_edit_story_entry_ambiguous_line_asks_which_one(monkeypatch):
    body = "I love hiking in the mountains.\nI love hiking by the river."
    sec = [{"page_id": "interests", "page_type": "interests", "title": "Interests",
            "body": body, "edit_body": body}]
    calls = []
    monkeypatch.setattr(story, "get_story", lambda d, u: {"sections": [dict(s) for s in sec]})
    monkeypatch.setattr(story, "save_section", lambda *a, **k: calls.append(a))
    monkeypatch.setattr(story, "_snapshot_section", lambda *a, **k: "v1")

    fn = _bound("edit_story_entry", object())
    out = fn(section="interests", find_text="I love hiking", new_text="I love climbing")
    assert not calls
    assert "which" in out.lower()


def test_remove_story_entry_removes_only_the_referenced_line(monkeypatch):
    saved, removed = {}, {}
    monkeypatch.setattr(story, "get_story", _story)
    monkeypatch.setattr(
        story, "save_section",
        lambda db, uid, pid, body, **k: saved.update(pid=pid, body=body),
    )
    monkeypatch.setattr(story, "_snapshot_section", lambda *a, **k: "v1")
    monkeypatch.setattr(
        story, "remove_section",
        lambda db, uid, pid: removed.update(pid=pid),
    )

    fn = _bound("remove_story_entry", object())
    out = fn(section="career", line="I did my bachelor of technology in a CMS")

    assert not removed  # whole-section soft-remove was NOT used
    assert saved["pid"] == "career"
    assert "bachelor" not in saved["body"]
    assert "I work as a teacher in Austin." in saved["body"]
    assert "I volunteer on weekends." in saved["body"]
    assert "took that line out" in out.lower()


def test_remove_story_entry_soft_hides_the_whole_section(monkeypatch):
    removed = {}
    monkeypatch.setattr(story, "get_story", _story)
    monkeypatch.setattr(
        story, "remove_section",
        lambda db, uid, pid: removed.update(uid=uid, pid=pid) or {"deleted": True},
    )

    fn = _bound("remove_story_entry", object(), uid="u7")
    out = fn(section="family")  # no `line` → whole-section removal

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
    out = fn(section="career", find_text="x", new_text="x")
    assert "don't have any" in out.lower()


def test_edit_is_scoped_to_the_caller_uid(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        story, "get_story", lambda d, u: seen.update(get_uid=u) or _story(d, u)
    )
    monkeypatch.setattr(
        story, "save_section",
        lambda d, u, pid, body, **k: seen.update(save_uid=u),
    )
    monkeypatch.setattr(
        story, "_snapshot_section",
        lambda d, u, *a, **k: seen.update(snap_uid=u) or "v1",
    )

    fn = _bound("edit_story_entry", object(), uid="owner9")
    fn(
        section="career",
        find_text="I volunteer on weekends",
        new_text="I volunteer at the animal shelter",
    )
    assert seen["get_uid"] == "owner9"
    assert seen["save_uid"] == "owner9"
    assert seen["snap_uid"] == "owner9"


def test_user_edit_does_not_create_a_pending_public_profile_suggestion():
    """End-to-end on the in-memory Firestore: a user-requested line edit applies
    in place and the follow-up ingest does NOT re-propose it as a pending
    Apply/Dismiss card, while a page the user never touched still proposes
    normally (founder bug 2026-10-28)."""
    uid = "u1"
    db = FakeDb()
    db.docs[("users", uid, "wiki_pages", "career")] = {
        "page_type": "career",
        "visibility": "public",
        "ai_body": (
            "I work as a teacher in Austin. "
            "I did my bachelor of technology in a CMS."
        ),
    }

    edit = _bound("edit_story_entry", db, uid=uid)
    out = edit(
        section="career",
        find_text="I did my bachelor of technology in a CMS",
        new_text="I did my BTech at Mahatma Gandhi University",
    )
    assert "Mahatma Gandhi University" in out

    page = db.docs[("users", uid, "wiki_pages", "career")]
    # The edit applied in place: only that sentence changed, and the one-shot
    # suppress flag is set so the next ingest won't re-propose it.
    assert page["suppress_next_proposal"] is True
    assert "I did my BTech at Mahatma Gandhi University" in page["user_edits"]
    assert "I work as a teacher in Austin." in page["user_edits"]
    assert "bachelor of technology" not in page["user_edits"]

    # The follow-up ingest recompiles ai_body with different wording — a public
    # text change that would normally become a pending card. The user's own
    # edit must NOT: the flag suppresses it and is consumed (one-shot).
    wiki_ingest._write_page(db, uid, "s1", {
        "page_id": "career", "page_type": "career", "visibility": "public",
        "ai_body": "I teach in Austin. I hold a BTech from MG University.",
    })
    assert pm.list_proposals(db, uid) == []
    assert db.docs[("users", uid, "wiki_pages", "career")][
        "suppress_next_proposal"
    ] is False

    # Control: a page the user did NOT edit still gets a normal proposal, so the
    # suppression above is specific to the user's own edit, not blanket.
    db.docs[("users", uid, "wiki_pages", "interests")] = {
        "page_type": "interests",
        "visibility": "public",
        "ai_body": "She climbs on weekends.",
    }
    wiki_ingest._write_page(db, uid, "s1", {
        "page_id": "interests", "page_type": "interests", "visibility": "public",
        "ai_body": "She climbs and surfs.",
    })
    assert [p["page_id"] for p in pm.list_proposals(db, uid)] == ["interests"]
