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
    get_vision_provider,
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
    # Defaults as loaded: gemini everywhere EXCEPT dm_coach and translate,
    # which the founder directed onto the Meta/Muse brain for the hackathon
    # (cross-language DM translation is "powered by Muse"; both default ``meta``).
    for surface in llm_provider.SURFACES:
        provider = get_llm_provider(surface)
        if surface in ("dm_coach", "translate"):
            assert isinstance(provider, MetaProvider)
        else:
            assert isinstance(provider, GeminiProvider)


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


def test_provider_vision_capability_flags():
    # Gemini genuinely reads images; Muse/Meta is text/reasoning-only.
    assert GeminiProvider().supports_vision is True
    assert MetaProvider().supports_vision is False


def test_vision_provider_falls_back_to_gemini_when_surface_is_vision_less(monkeypatch):
    # § founder 2026-10-28 (ISSUE 7): with the reports surface flipped to Meta
    # (Muse Spark, vision-less), a vision call must still go to Gemini so the
    # face/body appearance report truly analyses the photo instead of
    # hallucinating a read off an image the model never processed.
    _with_flags(monkeypatch, llm_provider_reports="meta", llm_meta_fallback=True)
    assert isinstance(get_llm_provider("reports"), MetaProvider)  # chat path unchanged
    assert isinstance(get_vision_provider("reports"), GeminiProvider)


def test_vision_provider_keeps_a_vision_capable_surface(monkeypatch):
    _with_flags(monkeypatch, llm_provider_reports="gemini")
    assert isinstance(get_vision_provider("reports"), GeminiProvider)


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
async def test_generate_json_strips_whitespace_in_keys(_no_ledger):
    raw = '{"strengths ": ["a"], "quick_facts": {" age": 3}, "rows": [{"k ": 1}]}'
    client = _FakeClient([_FakeResponse(_FakeMessage(content=raw))])
    out = await MetaProvider(client=client).generate_json(
        "c", "s", uid="u1", feature="face_report",
    )
    assert out == {"strengths": ["a"], "quick_facts": {"age": 3}, "rows": [{"k": 1}]}


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


# --- unified Brain: capability map + resolver (§13.10) -------------------- #

from llm_provider import (  # noqa: E402
    CAP_JSON,
    CAP_TEXT,
    CAP_TOOLS,
    CAP_VISION,
    CAP_WEB,
    PROVIDER_GEMINI,
    PROVIDER_META,
    available_brains,
    brain_capabilities,
    get_user_brain_provider,
)


def test_capability_map_gemini_has_everything():
    caps = brain_capabilities(PROVIDER_GEMINI)
    assert caps == {CAP_TEXT, CAP_JSON, CAP_VISION, CAP_WEB, CAP_TOOLS}
    # And the provider instance exposes the same set.
    assert GeminiProvider().capabilities == caps


def test_capability_map_meta_is_text_json_tools_only():
    caps = brain_capabilities(PROVIDER_META)
    assert caps == {CAP_TEXT, CAP_JSON, CAP_TOOLS}
    # The accurate map: Muse Spark does text/json/tools but NOT vision/web.
    assert CAP_VISION not in caps and CAP_WEB not in caps
    assert MetaProvider().capabilities == caps
    # ``supports_vision`` is derived from the one map.
    assert MetaProvider().supports_vision is False
    assert GeminiProvider().supports_vision is True


def test_capability_map_unknown_brain_defaults_to_gemini():
    assert brain_capabilities("banana") == brain_capabilities(PROVIDER_GEMINI)


def test_available_brains_shape():
    brains = available_brains()
    assert [b["id"] for b in brains] == [PROVIDER_GEMINI, PROVIDER_META]
    for b in brains:
        assert b["label"] and b["description"] and b["available"] is True
        assert set(b["capabilities"]) == brain_capabilities(b["id"])


def _brain(monkeypatch, value):
    """Pretend the user saved ``value`` as ``ayma_brain_model`` (no Firestore)."""
    monkeypatch.setattr(llm_provider, "read_brain_pref", lambda uid: value)


def test_resolver_uses_users_brain_when_capable(monkeypatch):
    # User picked Meta; a json surface it supports → Meta honoured.
    _with_flags(monkeypatch, llm_meta_fallback=True)
    _brain(monkeypatch, PROVIDER_META)
    assert isinstance(
        get_user_brain_provider("u1", "matching", needs=CAP_JSON), MetaProvider
    )
    # text/tools likewise stay on the chosen brain.
    assert isinstance(
        get_user_brain_provider("u1", "chat", needs=CAP_TOOLS), MetaProvider
    )


def test_resolver_web_always_gemini(monkeypatch):
    _brain(monkeypatch, PROVIDER_META)
    assert isinstance(
        get_user_brain_provider("u1", "chat", needs=CAP_WEB), GeminiProvider
    )


def test_resolver_vision_always_gemini(monkeypatch):
    _brain(monkeypatch, PROVIDER_META)
    assert isinstance(
        get_user_brain_provider("u1", "chat", needs=CAP_VISION), GeminiProvider
    )
    # And when the user's brain IS Gemini, vision stays Gemini too.
    _brain(monkeypatch, PROVIDER_GEMINI)
    assert isinstance(
        get_user_brain_provider("u1", "chat", needs=CAP_VISION), GeminiProvider
    )


def test_resolver_gemini_brain_keeps_gemini(monkeypatch):
    _brain(monkeypatch, PROVIDER_GEMINI)
    for cap in (CAP_TEXT, CAP_JSON, CAP_TOOLS, CAP_WEB, CAP_VISION):
        assert isinstance(
            get_user_brain_provider("u1", "chat", needs=cap), GeminiProvider
        )


def test_resolver_unset_falls_back_to_env_flag(monkeypatch):
    # No saved brain → the per-surface env flag decides (production default).
    _brain(monkeypatch, "")
    _with_flags(monkeypatch, llm_provider_chat="gemini", llm_provider_matching="meta",
                llm_meta_fallback=True)
    assert isinstance(
        get_user_brain_provider("u1", "chat", needs=CAP_TOOLS), GeminiProvider
    )
    assert isinstance(
        get_user_brain_provider("u1", "matching", needs=CAP_JSON), MetaProvider
    )
    # A capability the env-flag brain lacks still routes to Gemini.
    assert isinstance(
        get_user_brain_provider("u1", "matching", needs=CAP_WEB), GeminiProvider
    )


def test_resolver_unknown_brain_value_falls_back_to_env_flag(monkeypatch):
    _brain(monkeypatch, "banana")
    _with_flags(monkeypatch, llm_provider_chat="meta", llm_meta_fallback=True)
    assert isinstance(
        get_user_brain_provider("u1", "chat", needs=CAP_TOOLS), MetaProvider
    )


def test_resolver_none_uid_uses_env_flag(monkeypatch):
    # No uid (e.g. an anonymous translate caller) → env flag default, no crash.
    monkeypatch.setattr(llm_provider, "read_brain_pref", llm_provider.read_brain_pref)
    _with_flags(monkeypatch, llm_provider_translate="meta", llm_meta_fallback=True)
    assert isinstance(
        get_user_brain_provider(None, "translate", needs=CAP_JSON), MetaProvider
    )


def test_resolver_no_needs_returns_chosen_brain(monkeypatch):
    _brain(monkeypatch, PROVIDER_META)
    _with_flags(monkeypatch, llm_meta_fallback=True)
    assert isinstance(
        get_user_brain_provider("u1", "chat"), MetaProvider
    )


def test_resolver_rejects_unknown_surface(monkeypatch):
    _brain(monkeypatch, PROVIDER_META)
    with pytest.raises(ValueError):
        get_user_brain_provider("u1", "nope", needs=CAP_JSON)


def test_resolver_rejects_unknown_capability(monkeypatch):
    _brain(monkeypatch, PROVIDER_META)
    with pytest.raises(ValueError):
        get_user_brain_provider("u1", "chat", needs="telepathy")


def test_read_brain_pref_none_uid_is_empty():
    assert llm_provider.read_brain_pref(None) == ""
    assert llm_provider.read_brain_pref("") == ""
