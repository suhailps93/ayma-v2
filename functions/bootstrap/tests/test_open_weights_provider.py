"""Tests for the open-weights low-cost path (``OpenWeightsProvider``).

Covers: a surface flag of ``open-weights`` routes the call to the configured
``OPEN_WEIGHTS_BASE_URL`` with the configured ``meta_open_weights_model`` id
(the OpenAI client constructor is mocked, so no live HTTP); a missing base URL
or key fails with the explicit ``OpenWeightsUnconfiguredError``; and a failure
on this path NEVER falls back to a paid route — the error propagates.
"""

from __future__ import annotations

import dataclasses
import json

import pytest

import llm_provider
import token_ledger
from config import CONFIG
from llm_provider import (
    CAP_JSON,
    CAP_TEXT,
    CAP_TOOLS,
    PROVIDER_GEMINI,
    PROVIDER_OPEN_WEIGHTS,
    GeminiProvider,
    OpenWeightsProvider,
    OpenWeightsUnconfiguredError,
    get_llm_provider,
    get_user_brain_provider,
)


# --- fakes ---------------------------------------------------------------- #


class _FakeUsage:
    def __init__(self, p=11, c=7, t=18):
        self.prompt_tokens, self.completion_tokens, self.total_tokens = p, c, t


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


# --- routing to the open-weights endpoint --------------------------------- #


@pytest.mark.asyncio
async def test_call_routes_to_open_weights_base_url_with_configured_model(
    monkeypatch, _no_ledger
):
    """The provider builds its OpenAI-compatible client from the
    ``OPEN_WEIGHTS_*`` env and sends the configured open-weights model id —
    the mocked endpoint sees exactly that base URL + model, nothing paid."""
    import openai

    base_url = "https://ow.example.test/v1"
    _with_flags(monkeypatch, open_weights_api_base_url=base_url)
    monkeypatch.setenv("OPEN_WEIGHTS_API_KEY", "ow-test-key")

    built: dict = {}
    fake = _FakeClient([_FakeResponse(_FakeMessage(content='{"ok": 1}'))])

    def _factory(**kwargs):
        built.update(kwargs)
        return fake

    monkeypatch.setattr(openai, "AsyncOpenAI", _factory)

    out = await OpenWeightsProvider().generate_json(
        "contents", "system",
        response_schema={"type": "object", "properties": {"ok": {"type": "number"}}},
        uid="u1", feature="matching",
    )
    assert out == {"ok": 1}
    # The client was pointed at the open-weights endpoint, authed with its key…
    assert built["base_url"] == base_url
    assert built["api_key"] == "ow-test-key"
    # …and the call carried the configured open-weights model id.
    sent = fake.chat.completions.calls[0]
    assert sent["model"] == CONFIG.meta_open_weights_model
    assert sent["model"] == "meta-models/muse-spark-open-1026"
    assert sent["response_format"]["type"] == "json_schema"
    assert _no_ledger[0]["model"] == CONFIG.meta_open_weights_model


@pytest.mark.asyncio
async def test_chat_turn_uses_open_weights_model_without_meta_only_knobs():
    client = _FakeClient([_FakeResponse(_FakeMessage(content="cheap hello"))])
    events = [
        ev async for ev in OpenWeightsProvider(client=client).generate_reply_events(
            "hi", system_prompt="be nice", uid="u1", feature="chat",
        )
    ]
    assert events[0] == {"type": "status", "label": "Thinking…"}
    assert events[-1] == {"type": "reply", "text": "cheap hello", "tools_used": []}
    sent = client.chat.completions.calls[0]
    assert sent["model"] == CONFIG.meta_open_weights_model
    # No Meta-Model-API-only knobs leak to the generic endpoint.
    assert "extra_body" not in sent
    assert "reasoning_effort" not in json.dumps(sent)


def test_surface_flag_selects_open_weights(monkeypatch):
    _with_flags(monkeypatch, llm_provider_matching="open-weights")
    provider = get_llm_provider("matching")
    assert isinstance(provider, OpenWeightsProvider)
    # The cheap path carries no paid fallback, whatever the fallback flag says.
    _with_flags(
        monkeypatch, llm_provider_matching="open-weights", llm_meta_fallback=True
    )
    assert not hasattr(get_llm_provider("matching"), "_fallback")


def test_gemini_default_untouched(monkeypatch):
    # No flag set anywhere near open-weights: the production default stands.
    _with_flags(monkeypatch, llm_provider_chat="gemini")
    assert isinstance(get_llm_provider("chat"), GeminiProvider)


# --- explicit unconfigured failure, never a silent paid fallback ---------- #


@pytest.mark.asyncio
async def test_missing_base_url_fails_explicitly(monkeypatch):
    _with_flags(monkeypatch, open_weights_api_base_url="")
    monkeypatch.setenv("OPEN_WEIGHTS_API_KEY", "ow-test-key")
    with pytest.raises(OpenWeightsUnconfiguredError, match="OPEN_WEIGHTS_BASE_URL"):
        await OpenWeightsProvider().generate_json(
            "c", "s", uid="u1", feature="matching"
        )


@pytest.mark.asyncio
async def test_missing_key_fails_explicitly(monkeypatch):
    _with_flags(
        monkeypatch, open_weights_api_base_url="https://ow.example.test/v1"
    )
    monkeypatch.delenv("OPEN_WEIGHTS_API_KEY", raising=False)
    with pytest.raises(OpenWeightsUnconfiguredError, match="OPEN_WEIGHTS_API_KEY"):
        await OpenWeightsProvider().generate_json(
            "c", "s", uid="u1", feature="matching"
        )


@pytest.mark.asyncio
async def test_endpoint_failure_never_falls_back_to_a_paid_route(monkeypatch):
    """A transport failure on the cheap path propagates — Gemini is never
    consulted, so an outage here can never silently become paid spend."""
    import gemini

    def _must_not_run(*a, **k):
        raise AssertionError("open-weights must not fall back to a paid route")

    monkeypatch.setattr(gemini, "generate_json", _must_not_run)
    monkeypatch.setattr(gemini, "generate_reply_events", _must_not_run)
    client = _FakeClient([RuntimeError("ow endpoint down")])
    with pytest.raises(RuntimeError, match="ow endpoint down"):
        await OpenWeightsProvider(client=client).generate_json(
            "c", "s", uid="u1", feature="matching"
        )


# --- capabilities ---------------------------------------------------------- #


def test_open_weights_capabilities_mirror_meta_without_vision_or_web():
    provider = OpenWeightsProvider()
    assert provider.name == PROVIDER_OPEN_WEIGHTS
    assert provider.capabilities == {CAP_TEXT, CAP_JSON, CAP_TOOLS}
    assert provider.supports_vision is False


def test_resolver_routes_open_weights_json_to_open_weights(monkeypatch):
    monkeypatch.setattr(
        llm_provider, "read_brain_pref", lambda uid: PROVIDER_OPEN_WEIGHTS
    )
    assert isinstance(
        get_user_brain_provider("u1", "matching", needs=CAP_JSON),
        OpenWeightsProvider,
    )


def test_resolver_web_on_open_weights_still_gemini(monkeypatch):
    # The cheap path has no grounding — web always resolves to Gemini.
    from llm_provider import CAP_WEB

    monkeypatch.setattr(
        llm_provider, "read_brain_pref", lambda uid: PROVIDER_OPEN_WEIGHTS
    )
    assert isinstance(
        get_user_brain_provider("u1", "chat", needs=CAP_WEB), GeminiProvider
    )


def test_open_weights_base_url_defaults_to_empty(monkeypatch):
    import config

    monkeypatch.delenv("OPEN_WEIGHTS_BASE_URL", raising=False)
    assert config._load().open_weights_api_base_url == ""
