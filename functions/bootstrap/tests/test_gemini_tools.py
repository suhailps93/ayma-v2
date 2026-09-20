import asyncio
import dataclasses
import types as pytypes

import pytest

import gemini
import skills
import token_ledger
from config import CONFIG

# The built-in grounding tools Ayma can use without a function round-trip —
# ``gemini._grounding_tools`` emits these names, so they need labels too.
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


def test_generate_reply_events_emits_a_working_status_then_the_label(monkeypatch):
    fake = _FakeClient(
        [
            _FakeResponse(
                function_calls=[_FakeCall("record_feedback", {"note": "loved it"})]
            ),
            _FakeResponse(text="Noted, thanks for telling me."),
        ]
    )
    monkeypatch.setattr(gemini, "_client", lambda: fake)

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


class _FakeCall:
    def __init__(self, name, args):
        self.name = name
        self.args = args


class _FakeResponse:
    def __init__(self, *, function_calls=None, text=None, searched=False):
        self.function_calls = function_calls or []
        self.text = text
        gm = (
            pytypes.SimpleNamespace(
                web_search_queries=["new dune release date"],
                grounding_chunks=[object()],
            )
            if searched
            else None
        )
        self.candidates = [
            pytypes.SimpleNamespace(
                content="<model-turn>",
                grounding_metadata=gm,
                url_context_metadata=None,
            )
        ]


class _FakeModels:
    def __init__(self, responses):
        self._responses = list(responses)
        self.calls = []

    async def generate_content(self, *, model, contents, config):
        self.calls.append(contents)
        self.configs = getattr(self, "configs", [])
        self.configs.append(config)
        return self._responses.pop(0)


class _FakeClient:
    def __init__(self, responses):
        self.aio = pytypes.SimpleNamespace(models=_FakeModels(responses))


def test_generate_reply_runs_one_tool_round(monkeypatch):
    fake = _FakeClient(
        [
            _FakeResponse(
                function_calls=[
                    _FakeCall(
                        "add_followup_question",
                        {"question_text": "how's your dad?", "category": "family"},
                    )
                ]
            ),
            _FakeResponse(text="Noted — let's get back to your message."),
        ]
    )
    monkeypatch.setattr(gemini, "_client", lambda: fake)

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
    assert len(fake.aio.models.calls) == 2


def test_generate_reply_without_tools_is_a_single_call(monkeypatch):
    fake = _FakeClient([_FakeResponse(text="hello!")])
    monkeypatch.setattr(gemini, "_client", lambda: fake)
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=False)
    )
    out = asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert out.text == "hello!"
    assert len(fake.aio.models.calls) == 1


def _tool_kinds(config):
    kinds = set()
    for t in config.tools or []:
        if getattr(t, "google_search", None) is not None:
            kinds.add("google_search")
        if getattr(t, "url_context", None) is not None:
            kinds.add("url_context")
        if getattr(t, "function_declarations", None):
            kinds.add("functions")
    return kinds


def test_web_search_tools_attached_when_enabled(monkeypatch):
    fake = _FakeClient([_FakeResponse(text="the film is out friday")])
    monkeypatch.setattr(gemini, "_client", lambda: fake)
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=True)
    )
    asyncio.run(gemini.generate_reply("when's the new dune out?", system_prompt="p"))
    assert _tool_kinds(fake.aio.models.configs[0]) == {
        "google_search",
        "url_context",
    }


def test_web_search_tools_sit_alongside_function_tools(monkeypatch):
    fake = _FakeClient([_FakeResponse(text="ok")])
    monkeypatch.setattr(gemini, "_client", lambda: fake)
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
    assert _tool_kinds(fake.aio.models.configs[0]) == {
        "functions",
        "google_search",
        "url_context",
    }


def test_web_search_tools_absent_when_disabled(monkeypatch):
    fake = _FakeClient([_FakeResponse(text="hi")])
    monkeypatch.setattr(gemini, "_client", lambda: fake)
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=False)
    )
    asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert not (fake.aio.models.configs[0].tools or [])


def test_reply_reports_a_web_search_label_when_the_model_grounded(monkeypatch):
    fake = _FakeClient([_FakeResponse(text="Out this Friday.", searched=True)])
    monkeypatch.setattr(gemini, "_client", lambda: fake)
    out = asyncio.run(gemini.generate_reply("when's dune out?", system_prompt="p"))
    assert out.tools_used == ["Searched the web"]


def test_reply_tools_used_is_empty_for_a_plain_answer(monkeypatch):
    fake = _FakeClient([_FakeResponse(text="just chatting")])
    monkeypatch.setattr(gemini, "_client", lambda: fake)
    out = asyncio.run(gemini.generate_reply("hey", system_prompt="p"))
    assert out.tools_used == []


def test_chat_thinking_level_is_applied(monkeypatch):
    fake = _FakeClient([_FakeResponse(text="ok")])
    monkeypatch.setattr(gemini, "_client", lambda: fake)
    monkeypatch.setattr(
        gemini, "CONFIG",
        dataclasses.replace(CONFIG, gemini_chat_thinking_level="low"),
    )
    asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    tc = fake.aio.models.configs[0].thinking_config
    assert tc is not None and str(tc.thinking_level).lower().endswith("low")


def test_chat_thinking_level_blank_leaves_the_model_default(monkeypatch):
    fake = _FakeClient([_FakeResponse(text="ok")])
    monkeypatch.setattr(gemini, "_client", lambda: fake)
    monkeypatch.setattr(
        gemini, "CONFIG",
        dataclasses.replace(CONFIG, gemini_chat_thinking_level=""),
    )
    asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert fake.aio.models.configs[0].thinking_config is None


def test_maps_tool_added_only_when_a_key_is_configured(monkeypatch):
    fake = _FakeClient([_FakeResponse(text="ok"), _FakeResponse(text="ok")])
    monkeypatch.setattr(gemini, "_client", lambda: fake)

    monkeypatch.setattr(
        gemini, "CONFIG",
        dataclasses.replace(CONFIG, gemini_maps_api_key="", gemini_web_search=True),
    )
    asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    kinds = {
        "maps"
        for t in (fake.aio.models.configs[0].tools or [])
        if getattr(t, "google_maps", None) is not None
    }
    assert kinds == set()

    monkeypatch.setattr(
        gemini, "CONFIG",
        dataclasses.replace(
            CONFIG, gemini_maps_api_key="k-123", gemini_web_search=True
        ),
    )
    asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert any(
        getattr(t, "google_maps", None) is not None
        for t in (fake.aio.models.configs[1].tools or [])
    )


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
