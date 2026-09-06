import feedback_ops
import pending_questions
import skills
import steering_ops
from skills import followup


def test_registry_exposes_the_followup_skill():
    names = {s.name for s in skills.all_skills()}
    assert "add_followup_question" in names


def test_registry_exposes_the_feedback_and_steering_skills():
    names = {s.name for s in skills.all_skills()}
    assert {"record_feedback", "set_user_steering"} <= names
    decls = {d["name"] for d in skills.session_tool_declarations()}
    assert {"record_feedback", "set_user_steering"} <= decls


def test_record_feedback_tool_writes_to_the_feedback_bucket(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        feedback_ops, "record",
        lambda db, uid, category, note, **kw: seen.update(
            uid=uid, category=category, note=note, **kw
        ) or "f-9",
    )
    fn = skills.make_session_tool_fns(object(), "u9")["record_feedback"]
    out = fn("repeated_question", "re-asked her job", "you asked that", "medium")
    assert out == "logged (f-9)"
    assert seen["uid"] == "u9" and seen["source"] == "ayma"
    assert seen["quote"] == "you asked that"


def test_set_user_steering_tool_appends_a_rule(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        steering_ops, "add_rule",
        lambda db, uid, rule: seen.update(uid=uid, rule=rule) or rule,
    )
    fn = skills.make_session_tool_fns(object(), "u9")["set_user_steering"]
    assert fn("Don't ask about my dog") == 'saved: "Don\'t ask about my dog"'
    assert seen == {"uid": "u9", "rule": "Don't ask about my dog"}


def test_declaration_shape():
    decl = followup.DECLARATION
    assert decl["name"] == "add_followup_question"
    props = decl["parameters"]["properties"]
    assert set(props) == {"question_text", "category", "target_page"}
    assert decl["parameters"]["required"] == ["question_text", "category"]
    assert decl in skills.session_tool_declarations()


def test_make_session_tool_fns_binds_every_skill(monkeypatch):
    seen = {}

    def _fake(db, uid, question_text, category, target_page=None, source="followup"):
        seen.update(db=db, uid=uid, q=question_text, cat=category, tp=target_page)
        return "q-1"

    monkeypatch.setattr(pending_questions, "add_followup_question", _fake)

    sentinel = object()
    fns = skills.make_session_tool_fns(sentinel, "u9")
    assert "add_followup_question" in fns

    out = fns["add_followup_question"]("How's your sister?", "family", "family")
    assert out == "queued (q-1)"
    assert seen == {
        "db": sentinel,
        "uid": "u9",
        "q": "How's your sister?",
        "cat": "family",
        "tp": "family",
    }


def test_bound_tool_reports_when_nothing_queued(monkeypatch):
    monkeypatch.setattr(
        pending_questions, "add_followup_question", lambda *a, **k: None
    )
    fn = skills.make_session_tool_fns(object(), "u9")["add_followup_question"]
    assert fn("", "misc") == "not queued"
