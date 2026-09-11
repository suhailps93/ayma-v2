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


def test_registry_exposes_the_questionnaire_skills_in_text_and_voice():
    want = {"next_questions", "record_answer", "set_relationship_intent"}
    assert want <= {s.name for s in skills.all_skills()}
    assert want <= {d["name"] for d in skills.session_tool_declarations()}
    try:
        tools = skills.make_livekit_tools(object(), "u1")
    except ModuleNotFoundError:
        return  # livekit-agents only present in the voice venv
    names = {getattr(t, "name", getattr(t, "__name__", "")) for t in tools}
    assert want <= names


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


# --- _instrumented / make_livekit_tools on_call hook (voice tool_used) ----


def test_instrumented_wraps_a_sync_call_with_start_and_end_hooks():
    seen = []

    def fn(x):
        seen.append(("call", x))
        return "sync-" + x

    wrapped = skills._instrumented(
        fn, "my_tool", lambda phase, name: seen.append((phase, name))
    )
    assert wrapped("hi") == "sync-hi"
    assert seen == [("start", "my_tool"), ("call", "hi"), ("end", "my_tool")]


def test_instrumented_wraps_an_async_call_with_start_and_end_hooks():
    import asyncio

    seen = []

    async def fn(x):
        seen.append(("call", x))
        return "async-" + x

    wrapped = skills._instrumented(
        fn, "my_tool", lambda phase, name: seen.append((phase, name))
    )
    assert asyncio.run(wrapped("hi")) == "async-hi"
    assert seen == [("start", "my_tool"), ("call", "hi"), ("end", "my_tool")]


def test_instrumented_still_fires_the_end_hook_when_the_call_raises():
    import pytest

    seen = []

    def fn():
        raise ValueError("boom")

    wrapped = skills._instrumented(
        fn, "my_tool", lambda phase, name: seen.append(phase)
    )
    with pytest.raises(ValueError):
        wrapped()
    assert seen == ["start", "end"]


def test_instrumented_async_still_fires_the_end_hook_when_the_call_raises():
    import asyncio

    import pytest

    seen = []

    async def fn():
        raise ValueError("boom")

    wrapped = skills._instrumented(
        fn, "my_tool", lambda phase, name: seen.append(phase)
    )
    with pytest.raises(ValueError):
        asyncio.run(wrapped())
    assert seen == ["start", "end"]


def test_instrumented_preserves_the_wrapped_signature_for_schema_introspection():
    import inspect

    def fn(question_text: str, category: str = "misc") -> str:
        return "ok"

    wrapped = skills._instrumented(fn, "add_followup_question", lambda *a: None)
    assert inspect.signature(wrapped) == inspect.signature(fn)
    assert wrapped.__wrapped__ is fn


def test_make_livekit_tools_instruments_every_tool_when_on_call_is_given():
    import pytest

    pytest.importorskip("livekit.agents")  # voice venv only, like the test above

    from skills import app_control

    tools = skills.make_livekit_tools(
        object(), "u9", on_call=lambda phase, name: None
    )
    assert len(tools) == len(skills.all_skills()) + len(app_control.VOICE_SKILLS)
    # every tool's underlying callable is the _instrumented wrapper (carries
    # __wrapped__ back to the raw bound skill), not the raw bind() output.
    for t in tools:
        assert getattr(t._func, "__wrapped__", None) is not None


def test_make_livekit_tools_omits_instrumentation_when_on_call_is_absent():
    import pytest

    pytest.importorskip("livekit.agents")

    tools = skills.make_livekit_tools(object(), "u9")
    # no on_call given -> the raw bound callables go straight to function_tool,
    # none of them happen to define their own __wrapped__.
    assert all(getattr(t._func, "__wrapped__", None) is None for t in tools)
