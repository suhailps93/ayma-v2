import asyncio
import dataclasses
import types as pytypes

import pytest

import gemini
import inference_llm
import skills
import token_ledger
from config import CONFIG

# The chat `web_search` function tool (grounded lookup is disabled with the
# direct-Google kill, but the tool name still needs labels for the kicker).
_GROUNDING_TOOLS = ["web_search", "url_context", "google_maps"]


def _every_chat_tool_name() -> list[str]:
    """Every tool name that can surface in the chat kicker: all registered
    skills (including the story-edit and profile-edit sets) plus grounding."""
    decls = skills.session_tool_declarations(story=True, profile_edit=True)
    return [d["name"] for d in decls] + _GROUNDING_TOOLS


def test_every_registered_tool_has_a_non_generic_label_in_both_maps():
    missing_persistent = []
    missing_working = []
    for name in _every_chat_tool_name():
        if name not in gemini._TOOL_LABELS:
            missing_persistent.append(name)
        if name not in gemini._WORKING_LABELS:
            missing_working.append(name)
        # never the raw "Read dm thread" / "Working…" fallback
        assert gemini._tool_label(name) != name.replace("_", " ").capitalize(), (
            f"{name!r} falls through to the generic persistent label"
        )
        assert gemini._working_label(name) != "Working…", (
            f"{name!r} falls through to the generic working label"
        )
    assert not missing_persistent, f"no _TOOL_LABELS entry: {missing_persistent}"
    assert not missing_working, f"no _WORKING_LABELS entry: {missing_working}"


def _resp(text="", calls=None):
    return inference_llm.InferenceResponse(
        text=text,
        function_calls=list(calls or []),
        assistant_message={"role": "assistant", "content": text},
        usage_metadata=pytypes.SimpleNamespace(
            prompt_token_count=10, candidates_token_count=5,
            total_token_count=15, cached_content_token_count=0,
        ),
    )


def _call(name, args=None, cid="c1"):
    return inference_llm.FunctionCall(
        id=cid, name=name, args=dict(args or {}))


def _install_complete(monkeypatch, replies):
    """Serve scripted gateway replies; returns the captured request kwargs."""
    sent = []
    queue = list(replies)

    async def _fake_complete(**kw):
        sent.append(kw)
        return queue.pop(0)

    monkeypatch.setattr(inference_llm, "complete", _fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    return sent


def test_generate_reply_events_emits_a_working_status_then_the_label(monkeypatch):
    sent = _install_complete(monkeypatch, [
        _resp("", [_call("record_feedback", {"note": "loved it"})]),
        _resp("Noted, thanks for telling me."),
    ])
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=False)
    )

    events = []

    async def _collect():
        async for ev in gemini.generate_reply_events(
            "that reply was great",
            system_prompt="persona",
            tool_declarations=[{"name": "record_feedback"}],
            tool_fns={"record_feedback": lambda **k: "logged"},
        ):
            events.append(ev)

    asyncio.run(_collect())

    labels = [e["label"] for e in events if e["type"] == "status"]
    assert "Making a note of your feedback…" in labels
    reply = next(e for e in events if e["type"] == "reply")
    assert reply["tools_used"] == ["Noted your feedback"]
    assert len(sent) == 2


def test_generate_reply_runs_one_tool_round(monkeypatch):
    sent = _install_complete(monkeypatch, [
        _resp("", [_call("add_followup_question", {
            "question_text": "how's your dad?", "category": "family"})]),
        _resp("Noted — let's get back to your message."),
    ])
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=False)
    )

    invoked = {}

    def _tool(question_text, category="misc", target_page=""):
        invoked.update(question_text=question_text, category=category)
        return "queued (q-9)"

    out = asyncio.run(
        gemini.generate_reply(
            "help me word a text",
            system_prompt="persona",
            tool_declarations=[{"name": "add_followup_question"}],
            tool_fns={"add_followup_question": _tool},
        )
    )

    assert out.text == "Noted — let's get back to your message."
    assert out.tools_used == ["Noted a follow-up"]
    assert invoked == {"question_text": "how's your dad?", "category": "family"}
    assert len(sent) == 2


def test_generate_reply_without_tools_is_a_single_call(monkeypatch):
    sent = _install_complete(monkeypatch, [_resp("hello!")])
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=False)
    )
    out = asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert out.text == "hello!"
    assert len(sent) == 1


def _tool_names(sent_kw):
    return [t["function"]["name"] for t in (sent_kw.get("tools") or [])]


def test_web_search_tool_attached_when_enabled(monkeypatch):
    sent = _install_complete(monkeypatch, [_resp("the film is out friday")])
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=True)
    )
    asyncio.run(gemini.generate_reply("when's the new dune out?", system_prompt="p"))
    assert _tool_names(sent[0]) == ["web_search"]


def test_web_search_tool_sits_alongside_function_tools(monkeypatch):
    sent = _install_complete(monkeypatch, [_resp("ok")])
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=True)
    )
    asyncio.run(
        gemini.generate_reply(
            "hi",
            system_prompt="p",
            tool_declarations=[{"name": "add_followup_question"}],
            tool_fns={"add_followup_question": lambda **k: "ok"},
        )
    )
    assert _tool_names(sent[0]) == ["add_followup_question", "web_search"]


def test_web_search_tool_absent_when_disabled(monkeypatch):
    sent = _install_complete(monkeypatch, [_resp("hi")])
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=False)
    )
    asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert sent[0].get("tools") is None


def test_reply_reports_a_web_search_label_when_the_tool_runs(monkeypatch):
    # Grounding itself is disabled with the kill, but the tool round-trip and
    # its kicker label still work: the error result is reported to the model.
    sent = _install_complete(monkeypatch, [
        _resp("", [_call("web_search", {"query": "dune release"})]),
        _resp("Out this Friday."),
    ])
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=True)
    )
    out = asyncio.run(gemini.generate_reply("when's dune out?", system_prompt="p"))
    assert out.tools_used == ["Searched the web"]
    assert sent[1]["messages"][-1]["role"] == "tool"


def test_reply_tools_used_is_empty_for_a_plain_answer(monkeypatch):
    _install_complete(monkeypatch, [_resp("just chatting")])
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=False)
    )
    out = asyncio.run(gemini.generate_reply("hey", system_prompt="p"))
    assert out.tools_used == []


def test_chat_thinking_level_is_applied(monkeypatch):
    sent = _install_complete(monkeypatch, [_resp("ok")])
    monkeypatch.setattr(
        gemini, "CONFIG",
        dataclasses.replace(
            CONFIG, gemini_web_search=False, gemini_chat_thinking_level="low"),
    )
    asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert sent[0]["reasoning_effort"] == "low"


def test_chat_thinking_level_blank_leaves_the_model_default(monkeypatch):
    sent = _install_complete(monkeypatch, [_resp("ok")])
    monkeypatch.setattr(
        gemini, "CONFIG",
        dataclasses.replace(
            CONFIG, gemini_web_search=False, gemini_chat_thinking_level=""),
    )
    asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert sent[0].get("reasoning_effort") is None


# --- credit gate: still intact everywhere except the wiki-ingest bypass ---


def test_generate_json_default_still_enforces_the_credit_cap(monkeypatch):
    """Wiki ingest was exempted from the credit gate via generate_json's
    ``enforce_cap=False`` (2026-09-20 founder directive), by threading that
    flag through one specific call site — not by weakening the shared gate
    itself. Any caller that doesn't explicitly pass ``enforce_cap=False``
    (chat, voice bootstrap checks, matching, icebreakers, ...) must still
    raise exactly as before when the user is out of credits."""

    def _out_of_credits(_uid):
        raise token_ledger.TokenCapExceeded("out of credits")

    monkeypatch.setattr(token_ledger, "check", _out_of_credits)

    with pytest.raises(token_ledger.TokenCapExceeded):
        asyncio.run(gemini.generate_json("hi", "system prompt", uid="u1"))


def test_generate_reply_events_still_enforces_the_credit_cap(monkeypatch):
    """Same proof for the chat/voice-reply path (``generate_reply_events``,
    which has no ``enforce_cap`` param at all — it always gates)."""

    def _out_of_credits(_uid):
        raise token_ledger.TokenCapExceeded("out of credits")

    monkeypatch.setattr(token_ledger, "check", _out_of_credits)

    async def _drain():
        async for _ in gemini.generate_reply_events("hi", uid="u1"):
            pass

    with pytest.raises(token_ledger.TokenCapExceeded):
        asyncio.run(_drain())


# --- strip_inline_refs: leaked grounding citations --------------------


def test_strip_inline_refs_removes_grounding_chunk_ids():
    s = gemini.strip_inline_refs
    dirty = (
        "backed up across alumni and industry records "
        "[AUZIYQELvjHWNKGhDseXxb3dFKuo5ATTL-oB0Jez0uiHVXBXGZEFZc8OX_v6dh, "
        "AUZIYQG49nOVmfmZAfBP0H-_YJZ4x7V6E0Hh].")
    assert gemini.strip_inline_refs(dirty) == (
        "backed up across alumni and industry records."
    )
    assert s("as noted [1] and [2, 3] too.") == "as noted and too."


def test_strip_inline_refs_keeps_real_brackets():
    s = gemini.strip_inline_refs
    kept = "see [the paper](https://x.com/p) and [likely] and [note]."
    assert s(kept) == kept
    # a long plain word in brackets (no digit/underscore/dash) is left alone
    assert s("plan [expialidocious] works") == "plan [expialidocious] works"
    assert s("") == ""


def test_a_hung_gateway_call_times_out_instead_of_hanging(monkeypatch):
    class _HangingCompletions:
        async def create(self, **kw):
            await asyncio.sleep(3600)

    fake_client = pytypes.SimpleNamespace(
        chat=pytypes.SimpleNamespace(completions=_HangingCompletions()))
    monkeypatch.setattr(inference_llm, "_client", lambda: fake_client)
    monkeypatch.setattr(
        inference_llm, "CONFIG",
        dataclasses.replace(CONFIG, inference_timeout_seconds=0.05),
    )

    async def _drain():
        async for _ in gemini.generate_reply_events("hi", system_prompt="p"):
            pass

    with pytest.raises(asyncio.TimeoutError):
        asyncio.run(_drain())


def test_a_hung_tool_is_reported_to_the_model_and_the_turn_still_replies(
    monkeypatch,
):
    monkeypatch.setattr(gemini, "_TOOL_TIMEOUT_SECONDS", 0.05)
    sent = _install_complete(monkeypatch, [
        _resp("", [_call("record_feedback", {})]),
        _resp("That didn't work, sorry."),
    ])
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=False)
    )

    async def _hang(**_k):
        await asyncio.sleep(3600)

    events = []

    async def _collect():
        async for ev in gemini.generate_reply_events(
            "x", system_prompt="p",
            tool_declarations=[{"name": "record_feedback"}],
            tool_fns={"record_feedback": _hang},
        ):
            events.append(ev)

    asyncio.run(_collect())
    assert events[-1]["type"] == "reply"
    assert "took too long" in sent[1]["messages"][-1]["content"]
