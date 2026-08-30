import asyncio
import types as pytypes

import gemini


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
    out = asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert out == "hello!"
    assert len(fake.aio.models.calls) == 1
