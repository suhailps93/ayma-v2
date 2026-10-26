"""Tests for the LLM provider abstraction (hackathon Deliverable A).

Covers: per-surface provider selection and the gemini default, the
structured-output (JSON schema) mapping to the OpenAI ``response_format`` with
mocked Meta responses (schema by schema), the chat tool round-trip over the
Meta path, and fallback to Gemini on a Meta failure. No live HTTP — the Meta
client is a fake injected into :class:`MetaProvider`.
"""

from __future__ import annotations

import dataclasses
import json

import pytest

import llm_provider
import token_ledger
from config import CONFIG
from llm_provider import (
    GeminiProvider,
    MetaProvider,
    _response_format,
    get_llm_provider,
)


# --- fakes ---------------------------------------------------------------- #


class _FakeUsage:
    def __init__(self, p=11, c=7, t=18):
        self.prompt_tokens, self.completion_tokens, self.total_tokens = p, c, t


class _FakeFunc:
    def __init__(self, name, arguments):
        self.name, self.arguments = name, arguments


class _FakeToolCall:
    def __init__(self, cid, name, arguments):
        self.id = cid
        self.function = _FakeFunc(name, arguments)


class _FakeMessage:
    def __init__(self, content=None, tool_calls=None):
        self.content = content
        self.tool_calls = tool_calls


class _FakeResponse:
    def __init__(self, message, usage=None):
        self.choices = [type("C", (), {"message": message})()]
        self.usage = usage or _FakeUsage()


class _FakeCompletions:
    def __init__(self, responses):
        self._responses = list(responses)
        self.calls: list[dict] = []

    async def create(self, **kwargs):
        self.calls.append(kwargs)
        if isinstance(self._responses[0], Exception):
            raise self._responses[0]
        return self._responses.pop(0) if len(self._responses) > 1 else self._responses[0]


class _FakeClient:
    def __init__(self, responses):
        self.chat = type("Chat", (), {"completions": _FakeCompletions(responses)})()


@pytest.fixture(autouse=True)
def _no_ledger(monkeypatch):
    """Keep the token ledger off Firestore; record what it was asked to meter."""
    recorded: list[dict] = []
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    monkeypatch.setattr(
        token_ledger,
        "record",
        lambda uid, feature, response, **kw: recorded.append(
            {"uid": uid, "feature": feature, "model": kw.get("model"),
             "usage": response.usage_metadata}
        ),
    )
    return recorded


def _with_flags(monkeypatch, **flags):
    monkeypatch.setattr(
        llm_provider, "CONFIG", dataclasses.replace(CONFIG, **flags)
    )


# --- selection ------------------------------------------------------------ #


def test_default_is_gemini_for_every_surface(monkeypatch):
    # Defaults as loaded (all gemini) — production behaviour unchanged.
    for surface in llm_provider.SURFACES:
        assert isinstance(get_llm_provider(surface), GeminiProvider)


def test_per_surface_flip_is_independent(monkeypatch):
    _with_flags(
        monkeypatch,
        llm_provider_chat="meta",
        llm_provider_matching="gemini",
        llm_provider_reports="meta",
        llm_provider_practice="gemini",
        llm_provider_voice="gemini",
    )
    assert isinstance(get_llm_provider("chat"), MetaProvider)
    assert isinstance(get_llm_provider("matching"), GeminiProvider)
    assert isinstance(get_llm_provider("reports"), MetaProvider)
    assert isinstance(get_llm_provider("practice"), GeminiProvider)


def test_unknown_surface_raises():
    with pytest.raises(ValueError):
        get_llm_provider("nope")


def test_unknown_flag_value_falls_back_to_gemini(monkeypatch):
    _with_flags(monkeypatch, llm_provider_chat="banana")
    assert isinstance(get_llm_provider("chat"), GeminiProvider)


def test_meta_fallback_disabled_means_no_fallback(monkeypatch):
    _with_flags(monkeypatch, llm_provider_chat="meta", llm_meta_fallback=False)
    assert get_llm_provider("chat")._fallback is None
    _with_flags(monkeypatch, llm_provider_chat="meta", llm_meta_fallback=True)
    assert get_llm_provider("chat")._fallback is not None


# --- structured-output mapping ------------------------------------------- #


def test_response_format_none_is_json_object():
    assert _response_format(None, "matching") == {"type": "json_object"}


def test_response_format_wraps_schema_non_strict():
    schema = {"type": "object", "properties": {"x": {"type": "number"}}}
    rf = _response_format(schema, "matching")
    assert rf["type"] == "json_schema"
    assert rf["json_schema"]["name"] == "matching"
    assert rf["json_schema"]["schema"] is schema
    assert rf["json_schema"]["strict"] is False


# Real schema shapes from matching_skill and the photo reports.
import matching_skill  # noqa: E402

_MATCHING_SCHEMA = matching_skill._response_schema([])


@pytest.mark.parametrize(
    "schema,payload",
    [
        (
            _MATCHING_SCHEMA,
            {
                "dimensions": [
                    {"key": "values", "score": 82, "rationale": "aligned"}
                ],
                "user_explanation": {"A": "a", "B": "b"},
                "ai_explanation": "because",
            },
        ),
        (
            {
                "type": "object",
                "properties": {
                    "usable": {"type": "boolean"},
                    "overall_score": {"type": "number"},
                },
                "required": ["usable"],
            },
            {"usable": True, "overall_score": 7.5},
        ),
    ],
)
@pytest.mark.asyncio
async def test_generate_json_maps_schema_and_parses(schema, payload):
    client = _FakeClient(
        [_FakeResponse(_FakeMessage(content=json.dumps(payload)))]
    )
    provider = MetaProvider(client=client)
    out = await provider.generate_json(
        "contents", "system", response_schema=schema,
        uid="u1", feature="matching",
    )
    assert out == payload
    sent = client.chat.completions.calls[0]
    assert sent["model"] == CONFIG.meta_chat_model
    assert sent["response_format"]["type"] == "json_schema"
    assert sent["response_format"]["json_schema"]["schema"] is schema


@pytest.mark.asyncio
async def test_generate_json_records_usage(monkeypatch, _no_ledger):
    client = _FakeClient([_FakeResponse(_FakeMessage(content='{"ok": 1}'))])
    out = await MetaProvider(client=client).generate_json(
        "c", "s", uid="u1", feature="matching",
    )
    assert out == {"ok": 1}
    assert _no_ledger[0]["model"] == CONFIG.meta_chat_model
    assert _no_ledger[0]["usage"].total_token_count == 18


@pytest.mark.asyncio
async def test_generate_json_image_sends_multimodal_content():
    client = _FakeClient([_FakeResponse(_FakeMessage(content='{"usable": true}'))])
    await MetaProvider(client=client).generate_json(
        "describe", "s", image=(b"\x89PNG", "image/png"),
        uid="u1", feature="body_report",
    )
    content = client.chat.completions.calls[0]["messages"][1]["content"]
    assert isinstance(content, list)
    assert content[0]["type"] == "image_url"
    assert content[0]["image_url"]["url"].startswith("data:image/png;base64,")


# --- chat (events + tool round trip) ------------------------------------- #


@pytest.mark.asyncio
async def test_meta_chat_plain_reply():
    client = _FakeClient([_FakeResponse(_FakeMessage(content="hello there"))])
    events = []
    async for ev in MetaProvider(client=client).generate_reply_events(
        "hi", system_prompt="be nice", uid="u1", feature="chat",
    ):
        events.append(ev)
    assert events[0] == {"type": "status", "label": "Thinking…"}
    assert events[-1] == {"type": "reply", "text": "hello there", "tools_used": []}


@pytest.mark.asyncio
async def test_meta_chat_tool_round_trip():
    tool_call = _FakeToolCall("call_1", "remember_fact", '{"fact": "likes hiking"}')
    client = _FakeClient([
        _FakeResponse(_FakeMessage(content="", tool_calls=[tool_call])),
        _FakeResponse(_FakeMessage(content="Noted!")),
    ])
    ran = {}

    def remember_fact(fact):
        ran["fact"] = fact
        return "stored"

    reply = await MetaProvider(client=client).generate_reply(
        "remember I like hiking",
        system_prompt="s",
        tool_declarations=[{"name": "remember_fact", "description": "",
                            "parameters": {"type": "object"}}],
        tool_fns={"remember_fact": remember_fact},
        uid="u1", feature="chat",
    )
    assert ran["fact"] == "likes hiking"
    assert reply.text == "Noted!"
    # second call carried the tool result back to the model
    second = client.chat.completions.calls[1]["messages"]
    assert any(m.get("role") == "tool" and m["content"] == "stored" for m in second)


# --- fallback to Gemini --------------------------------------------------- #


@pytest.mark.asyncio
async def test_generate_json_falls_back_to_gemini(monkeypatch):
    import gemini

    async def fake_gem_json(*a, **k):
        return {"from": "gemini"}

    monkeypatch.setattr(gemini, "generate_json", fake_gem_json)
    client = _FakeClient([RuntimeError("meta down")])
    provider = MetaProvider(client=client, fallback=GeminiProvider())
    out = await provider.generate_json("c", "s", uid="u1", feature="matching")
    assert out == {"from": "gemini"}


@pytest.mark.asyncio
async def test_generate_json_no_fallback_raises():
    client = _FakeClient([RuntimeError("meta down")])
    with pytest.raises(RuntimeError):
        await MetaProvider(client=client).generate_json(
            "c", "s", uid="u1", feature="matching",
        )


@pytest.mark.asyncio
async def test_chat_falls_back_to_gemini(monkeypatch):
    import gemini

    async def fake_events(*a, **k):
        yield {"type": "reply", "text": "gemini reply", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", fake_events)
    client = _FakeClient([RuntimeError("meta down")])
    provider = MetaProvider(client=client, fallback=GeminiProvider())
    out = [
        ev async for ev in provider.generate_reply_events(
            "hi", uid="u1", feature="chat",
        )
    ]
    assert out[-1]["text"] == "gemini reply"


@pytest.mark.asyncio
async def test_meta_without_key_raises_clear_error(monkeypatch):
    monkeypatch.delenv("META_API_KEY", raising=False)
    with pytest.raises(RuntimeError, match="META_API_KEY"):
        await MetaProvider().generate_json("c", "s", uid=None, feature="matching")
