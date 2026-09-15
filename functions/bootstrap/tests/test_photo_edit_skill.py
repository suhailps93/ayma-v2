"""delete_photo — Ayma can remove the in-focus "Chat about it" photo herself
when asked, instead of just explaining how to do it manually (§ founder bug:
"you do it" -> "I don't have the controls...")."""

import photo_notes
import skills
from skills import photo_edit


def test_delete_photo_is_registered_and_exposed_with_the_photo_flag():
    names = {s.name for s in photo_edit.SKILLS}
    assert {"update_photo_note", "delete_photo"} <= names

    base = {d["name"] for d in skills.session_tool_declarations()}
    withphoto = {d["name"] for d in skills.session_tool_declarations(photo=True)}
    assert withphoto - base == {"update_photo_note", "delete_photo"}


def test_delete_photo_calls_hide_photo_with_uid_url_and_source(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        photo_notes, "hide_photo",
        lambda db, uid, url, *, source="": seen.update(
            db=db, uid=uid, url=url, source=source
        ),
    )
    sentinel = object()
    fn = skills.make_session_tool_fns(
        sentinel, "u9",
        photo_ctx={"url": "https://x/p.jpg", "source": "profile"},
    )["delete_photo"]

    out = fn()

    assert out == "done — removed that photo"
    assert seen == {
        "db": sentinel, "uid": "u9", "url": "https://x/p.jpg", "source": "profile",
    }


def test_delete_photo_with_no_photo_in_focus_does_not_error(monkeypatch):
    def _boom(*_a, **_kw):  # pragma: no cover
        raise AssertionError("hide_photo should not be called")

    monkeypatch.setattr(photo_notes, "hide_photo", _boom)
    fn = photo_edit._bind_delete(object(), "u9", url="", source="profile")
    assert fn() == "no photo in focus"


def test_photo_edit_context_mentions_she_can_delete_it():
    import main

    url = "https://x/p.jpg"
    attached = main._photo_edit_context(url, "profile", attached=True)
    not_attached = main._photo_edit_context(url, "profile", attached=False)
    for text in (attached, not_attached):
        assert "delete_photo" in text
        assert "you CAN do that yourself" in text
