import asyncio
import dataclasses
import types as pytypes

import gemini
from config import CONFIG


class _FakeCall:
    def __init__(self, name, args):
        self.name = name
        self.args = args


class _FakeResponse:
    def __init__(self, *, function_calls=None, text=None):
        self.function_calls = function_calls or []
        self.text = text
        self.candidates = [pytypes.SimpleNamespace(content="<model-turn>")]


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

    assert out == "Noted — let's get back to your message."
    assert invoked == {"question_text": "how's your dad?", "category": "family"}
    assert len(fake.aio.models.calls) == 2


def test_generate_reply_without_tools_is_a_single_call(monkeypatch):
    fake = _FakeClient([_FakeResponse(text="hello!")])
    monkeypatch.setattr(gemini, "_client", lambda: fake)
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=False)
    )
    out = asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert out == "hello!"
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
