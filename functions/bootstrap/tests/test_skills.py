import pending_questions
from skills import (
    FOLLOWUP_DECLARATION,
    make_add_followup_question,
    make_session_tool_fns,
    session_tool_declarations,
)


def test_declaration_shape():
    assert FOLLOWUP_DECLARATION["name"] == "add_followup_question"
    props = FOLLOWUP_DECLARATION["parameters"]["properties"]
    assert set(props) == {"question_text", "category", "target_page"}
    assert FOLLOWUP_DECLARATION["parameters"]["required"] == [
        "question_text",
        "category",
    ]
    assert session_tool_declarations() == [FOLLOWUP_DECLARATION]


def test_make_session_tool_fns_binds_the_tool(monkeypatch):
    monkeypatch.setattr(
        pending_questions, "add_followup_question", lambda *a, **k: "q-7"
    )
    fns = make_session_tool_fns(object(), "u1")
    assert set(fns) == {"add_followup_question"}
    assert fns["add_followup_question"]("q?", "career") == "queued (q-7)"


def test_bound_tool_forwards_to_pending_questions(monkeypatch):
    seen = {}

    def _fake(db, uid, question_text, category, target_page=None, source="followup"):
        seen.update(
            db=db,
            uid=uid,
            question_text=question_text,
            category=category,
            target_page=target_page,
        )
        return "q-1"

    monkeypatch.setattr(pending_questions, "add_followup_question", _fake)

    sentinel_db = object()
    tool = make_add_followup_question(sentinel_db, "u9")
    out = tool("How's your sister doing?", "family", "family")

    assert out == "queued (q-1)"
    assert seen == {
        "db": sentinel_db,
        "uid": "u9",
        "question_text": "How's your sister doing?",
        "category": "family",
        "target_page": "family",
    }
    assert tool.__doc__  # has a docstring for tool introspection


def test_bound_tool_reports_when_nothing_queued(monkeypatch):
    monkeypatch.setattr(
        pending_questions, "add_followup_question", lambda *a, **k: None
    )
    tool = make_add_followup_question(object(), "u9")
    assert tool("", "misc") == "not queued"
