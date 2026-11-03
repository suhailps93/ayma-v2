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


def test_submit_feedback_is_text_only_not_voice():
    # Available to text chat (declarations) but never in the voice registry.
    decls = {d["name"] for d in skills.session_tool_declarations()}
    assert "submit_feedback" in decls
    assert "submit_feedback" not in {s.name for s in skills.all_skills()}


def test_submit_feedback_tool_drafts_a_card_and_never_persists(monkeypatch):
    # A write would blow up — the tool must only populate the sink.
    def _boom(*a, **k):  # pragma: no cover - asserts it's never called
        raise AssertionError("submit_feedback must not write Firestore")

    monkeypatch.setattr(feedback_ops, "record_submission", _boom)
    sink: dict = {}
    fns = skills.make_session_tool_fns(object(), "u9", feedback_result=sink)
    out = fns["submit_feedback"]("bug", "Orb flickers", "it flickers on messages")
    assert "review" in out.lower() and "send" in out.lower()
    assert sink == {
        "kind": "bug",
        "title": "Orb flickers",
        "body": "it flickers on messages",
    }


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
    import asyncio

    seen = []

    def fn(x):
        seen.append(("call", x))
        return "sync-" + x

    wrapped = skills._instrumented(
        fn, "my_tool", lambda phase, name, label: seen.append((phase, name))
    )
    # Sync skills are wrapped as an *async* callable too (see _instrumented's
    # docstring) — livekit-agents always `await`s a function_tool's return
    # value, and awaiting a plain sync return raised TypeError, silently
    # turned into a generic tool-error response the model could never
    # relay (the read_dm_thread hallucination bug).
    assert asyncio.iscoroutinefunction(wrapped)
    assert asyncio.run(wrapped("hi")) == "sync-hi"
    assert seen == [("start", "my_tool"), ("call", "hi"), ("end", "my_tool")]


def test_instrumented_wraps_an_async_call_with_start_and_end_hooks():
    import asyncio

    seen = []

    async def fn(x):
        seen.append(("call", x))
        return "async-" + x

    wrapped = skills._instrumented(
        fn, "my_tool", lambda phase, name, label: seen.append((phase, name))
    )
    assert asyncio.run(wrapped("hi")) == "async-hi"
    assert seen == [("start", "my_tool"), ("call", "hi"), ("end", "my_tool")]


def test_instrumented_still_fires_the_end_hook_when_the_call_raises():
    import asyncio

    import pytest

    seen = []

    def fn():
        raise ValueError("boom")

    wrapped = skills._instrumented(
        fn, "my_tool", lambda phase, name, label: seen.append(phase)
    )
    with pytest.raises(ValueError):
        asyncio.run(wrapped())
    assert seen == ["start", "end"]


def test_instrumented_async_still_fires_the_end_hook_when_the_call_raises():
    import asyncio

    import pytest

    seen = []

    async def fn():
        raise ValueError("boom")

    wrapped = skills._instrumented(
        fn, "my_tool", lambda phase, name, label: seen.append(phase)
    )
    with pytest.raises(ValueError):
        asyncio.run(wrapped())
    assert seen == ["start", "end"]


def test_instrumented_passes_the_outcome_label_at_end():
    """A send_dm_message preview must never show a "Sent" chip in a call."""
    import asyncio

    seen = []

    async def fn():
        return "PREVIEW ONLY, nothing sent yet."

    wrapped = skills._instrumented(
        fn, "send_dm_message", lambda phase, name, label: seen.append((phase, label))
    )
    asyncio.run(wrapped())
    assert seen == [("start", None), ("end", "Drafted a message")]


def test_instrumented_preserves_the_wrapped_signature_for_schema_introspection():
    import inspect

    def fn(question_text: str, category: str = "misc") -> str:
        return "ok"

    wrapped = skills._instrumented(fn, "add_followup_question", lambda *a: None)
    assert inspect.signature(wrapped) == inspect.signature(fn)
    assert wrapped.__wrapped__ is fn


def test_livekit_tool_for_a_sync_skill_is_truly_awaitable(monkeypatch):
    """Regression for the read_dm_thread hallucination bug: livekit-agents'
    ``function_tool`` executor unconditionally does ``await tool(...)``
    (voice/tool_executor.py::_execute_tool) — a callable that runs correctly
    but returns a plain value (not a coroutine) blows up there with
    ``TypeError: object str can't be used in 'await' expression``, which the
    SDK silently turns into a generic error response. The model then never
    sees the tool's real return value and has to improvise, which is exactly
    what the founder saw: three ``read_dm_thread`` calls, three different
    hallucinated excuses, none matching any of read_dm_thread.py's own return
    strings. This calls the live-kit tool exactly the way the SDK does
    (``await tool(...)``) and asserts the real return string comes back
    unharmed instead of raising."""
    import asyncio

    import pytest

    pytest.importorskip("livekit.agents")

    from skills import read_dm_thread as read_dm_thread_module

    monkeypatch.setattr(
        read_dm_thread_module, "_resolve_other_uid", lambda db, uid, person: None
    )

    tools = skills.make_livekit_tools(
        object(), "u9", on_call=lambda phase, name, label: None
    )
    tool = next(t for t in tools if t.info.name == "read_dm_thread")

    # This is the exact call shape livekit-agents' _ToolExecutor uses — before
    # the fix, a sync skill wrapped this way raised TypeError right here.
    result = asyncio.run(tool(person="Jordan"))
    assert result == (
        "couldn't find a conversation with 'Jordan' — check the "
        "name, or they may not be a match yet"
    )


def test_make_livekit_tools_instruments_every_tool_when_on_call_is_given():
    import pytest

    pytest.importorskip("livekit.agents")  # voice venv only, like the test above

    from skills import app_control

    tools = skills.make_livekit_tools(
        object(), "u9", on_call=lambda phase, name, label: None
    )
    # all_skills() + the always-on story edit/remove tools + the voice-only
    # current_screen and the shared app-command tools.
    assert len(tools) == (
        len(skills.all_skills())
        + len(skills._STORY_MANAGE_REGISTRY)
        + len(app_control.VOICE_SKILLS)
    )
    # every tool's underlying callable is the _instrumented wrapper (carries
    # __wrapped__ back to the raw bound skill), not the raw bind() output.
    for t in tools:
        assert getattr(t._func, "__wrapped__", None) is not None


def test_make_livekit_tools_bounds_every_tool_even_without_on_call():
    import pytest

    pytest.importorskip("livekit.agents")

    tools = skills.make_livekit_tools(object(), "u9")
    # Even with no on_call (no instrumentation), every tool is wrapped by
    # _bounded (the per-tool wall-clock backstop against a voice hang — founder
    # bug 2026-11-03), so each carries __wrapped__ back to its raw bound skill
    # (which also preserves the signature for livekit schema introspection).
    assert tools
    for t in tools:
        assert getattr(t._func, "__wrapped__", None) is not None


# --- _guarded (voice misheard-fragment guard) -----------------------------


def test_guarded_refuses_without_running_the_tool():
    import asyncio

    ran = []

    def fn(x):
        ran.append(x)
        return "ran"

    wrapped = skills._guarded(fn, lambda: "Not done: misheard")
    assert asyncio.iscoroutinefunction(wrapped)
    assert asyncio.run(wrapped("a")) == "Not done: misheard"
    assert ran == []


def test_guarded_runs_sync_and_async_tools_when_clear():
    import asyncio

    async def afn(x):
        return "async-" + x

    assert asyncio.run(skills._guarded(lambda x: "sync-" + x, lambda: None)("a")) == "sync-a"
    assert asyncio.run(skills._guarded(afn, lambda: None)("b")) == "async-b"


# --- _bounded (voice per-tool wall-clock backstop) ------------------------
# Founder bug 2026-11-03: a voice tool whose sub-call hung (an inline deep_dive
# whose grounded search stalled) blocked the turn forever with a stuck
# "Searching the web…". The text loop already bounds every tool await; this is
# the voice counterpart.


def test_bounded_passes_a_fast_async_tool_through_untouched():
    import asyncio

    async def afn(x):
        return "ok-" + x

    wrapped = skills._bounded(afn, "afn", timeout=5.0)
    assert asyncio.iscoroutinefunction(wrapped)
    assert asyncio.run(wrapped("a")) == "ok-a"


def test_bounded_passes_a_sync_tool_through_untouched():
    import asyncio

    wrapped = skills._bounded(lambda x: "sync-" + x, "fn", timeout=5.0)
    assert asyncio.run(wrapped("b")) == "sync-b"


def test_bounded_returns_an_honest_error_instead_of_hanging():
    import asyncio

    async def _hangs():
        await asyncio.sleep(60)
        return "never"

    wrapped = skills._bounded(_hangs, "deep_dive", timeout=0.05)
    result = asyncio.run(wrapped())
    # Honest, model-relayable result — NOT a raise (so _instrumented's "end"
    # still fires and clears the live indicator) and NOT a silent hang.
    assert result == skills._TOOL_TIMEOUT_RESULT
    assert "too long" in result


def test_bounded_preserves_the_wrapped_signature_for_schema_introspection():
    import inspect

    async def deep_dive(full_name, subject="other", context=""):
        return "x"

    wrapped = skills._bounded(deep_dive, "deep_dive")
    assert list(inspect.signature(wrapped).parameters) == [
        "full_name", "subject", "context",
    ]
    assert getattr(wrapped, "__wrapped__", None) is deep_dive
