"""``report_bug`` — app crash/bug reports captured directly in Ayma chat
(founder request 2026-09-16), separate from ``record_feedback``'s
conversational-conduct bucket. Covers registration (always-on, not gated
behind story/profile_edit/photo like the scoped tool sets), the bound
callable's Firestore write, and that an attached screenshot's ``image_path``
is threaded through when present and omitted when absent."""

import bug_reports_ops
import skills
from skills import report_bug


def test_report_bug_is_registered_and_always_on():
    names = {s.name for s in skills.all_skills()}
    assert "report_bug" in names

    # Always-on: present in the base declarations, not only behind one of
    # the gated extras (story / profile_edit / photo) — a crash can happen
    # on any screen.
    base = {d["name"] for d in skills.session_tool_declarations()}
    assert "report_bug" in base


def test_report_bug_exposed_to_voice_too():
    try:
        tools = skills.make_livekit_tools(object(), "u1")
    except ModuleNotFoundError:
        return  # livekit-agents only present in the voice venv
    names = {getattr(t, "name", getattr(t, "__name__", "")) for t in tools}
    assert "report_bug" in names


def test_declaration_shape():
    decl = report_bug.DECLARATION
    assert decl["name"] == "report_bug"
    assert decl["parameters"]["required"] == ["description"]


def test_report_bug_tool_writes_the_expected_doc_shape(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        bug_reports_ops, "record",
        lambda db, uid, description, **kw: seen.update(
            uid=uid, description=description, **kw
        ) or "b-1",
    )
    fn = skills.make_session_tool_fns(object(), "u9")["report_bug"]
    out = fn("the app crashed when I opened my profile")
    assert out == "logged (b-1)"
    assert seen == {
        "uid": "u9",
        "description": "the app crashed when I opened my profile",
        "image_path": "",
    }


def test_report_bug_includes_attached_image_path_when_present(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        bug_reports_ops, "record",
        lambda db, uid, description, **kw: seen.update(
            uid=uid, description=description, **kw
        ) or "b-2",
    )
    fn = skills.make_session_tool_fns(
        object(), "u9", image_path="uploads/u9/shot.png"
    )["report_bug"]
    out = fn("this button does nothing, see the screenshot")
    assert out == "logged with your screenshot (b-2)"
    assert seen["image_path"] == "uploads/u9/shot.png"


def test_report_bug_omits_image_path_when_no_attachment(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        bug_reports_ops, "record",
        lambda db, uid, description, **kw: seen.update(**kw) or "b-3",
    )
    fn = skills.make_session_tool_fns(object(), "u9", image_path="")["report_bug"]
    fn("lost my chat history")
    assert seen["image_path"] == ""


def test_report_bug_tool_handles_a_failed_write():
    fn = skills.make_session_tool_fns(object(), "u9")["report_bug"]
    # bug_reports_ops.record with a real (non-monkeypatched) fake db lacking
    # firestore.SERVER_TIMESTAMP just fails softly and returns None.
    class _BadDb:
        def collection(self, name):
            raise RuntimeError("no firestore here")

    fn2 = skills.make_session_tool_fns(_BadDb(), "u9")["report_bug"]
    out = fn2("the app crashed")
    assert out == "couldn't log that — try describing the problem again"
