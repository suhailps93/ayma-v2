"""LiveKit Inference routing (inference_llm.py + the gemini.py route switches).

The gateway is mocked at ``inference_llm.complete`` / the OpenAI client — no
network. Defaults must stay on Vertex."""

from __future__ import annotations

import asyncio
import dataclasses
from types import SimpleNamespace

import pytest

import config
import gemini
import inference_llm
import token_ledger
from config import CONFIG


def _resp(text="", calls=None, usage=(10, 5, 15, 0)):
    p, c, t, cached = usage
    return inference_llm.InferenceResponse(
        text=text,
        function_calls=calls or [],
        assistant_message={"role": "assistant", "content": text},
        usage_metadata=SimpleNamespace(
            prompt_token_count=p, candidates_token_count=c,
            total_token_count=t, cached_content_token_count=cached,
        ),
    )


def _cfg(monkeypatch, **kw):
    monkeypatch.setattr(gemini, "CONFIG", dataclasses.replace(CONFIG, **kw))
    monkeypatch.setattr(inference_llm, "CONFIG", gemini.CONFIG)


def test_defaults_keep_everything_on_vertex():
    assert CONFIG.llm_route_json == "vertex"
    assert CONFIG.llm_route_vision == "vertex"
    assert CONFIG.llm_route_chat == "vertex"
    assert CONFIG.voice_provider == "google"


def test_invalid_route_env_fails_loudly(monkeypatch):
    monkeypatch.setenv("LLM_ROUTE_JSON", "inferense")
    with pytest.raises(ValueError):
        config._load()


def test_generate_json_routes_to_inference_and_meters(monkeypatch):
    _cfg(monkeypatch, llm_route_json="inference")
    seen = {}

    async def fake_complete(**kw):
        seen.update(kw)
        return _resp('{"score": 7}', usage=(100, 20, 120, 40))

    recorded = []
    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(
        token_ledger, "record",
        lambda uid, feature, response, **kw: recorded.append((uid, feature, kw)),
    )
    out = asyncio.run(
        gemini.generate_json(
            "c", "sys", {"type": "object"}, uid="u1", feature="matching",
            enforce_cap=False, temperature=0.0,
        )
    )
    assert out == {"score": 7}
    assert seen["model"] == CONFIG.inference_json_model
    assert seen["temperature"] == 0.0 and seen["max_tokens"] == 4096
    assert seen["response_schema"] == {"type": "object"}
    assert seen["messages"][0] == {"role": "system", "content": "sys"}
    assert recorded == [("u1", "matching", {
        "model": CONFIG.inference_json_model, "session_id": None})]


def test_json_with_images_follows_the_vision_route(monkeypatch):
    _cfg(monkeypatch, llm_route_json="vertex", llm_route_vision="inference")
    seen = {}

    async def fake_complete(**kw):
        seen.update(kw)
        return _resp("{}")

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    asyncio.run(
        gemini.generate_json(
            "c", "s", None, image=(b"\x89PNG", "image/png"), enforce_cap=False
        )
    )
    content = seen["messages"][1]["content"]
    assert content[0]["type"] == "image_url"
    assert content[0]["image_url"]["url"].startswith("data:image/png;base64,")
    assert content[1] == {"type": "text", "text": "c"}


def test_json_inference_failure_falls_back_to_vertex(monkeypatch):
    _cfg(monkeypatch, llm_route_json="inference")

    async def boom(**kw):
        raise RuntimeError("429")

    async def vertex(client, **kw):
        return SimpleNamespace(text='{"ok": true}', usage_metadata=None)

    monkeypatch.setattr(inference_llm, "complete", boom)
    monkeypatch.setattr(gemini, "_client", lambda: object())
    monkeypatch.setattr(gemini, "_generate", vertex)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    out = asyncio.run(gemini.generate_json("c", "s", None, enforce_cap=False))
    assert out == {"ok": True}


def test_json_inference_failure_raises_when_fallback_disabled(monkeypatch):
    _cfg(monkeypatch, llm_route_json="inference", llm_inference_fallback=False)

    async def boom(**kw):
        raise RuntimeError("429")

    monkeypatch.setattr(inference_llm, "complete", boom)
    with pytest.raises(RuntimeError):
        asyncio.run(gemini.generate_json("c", "s", None, enforce_cap=False))


def test_fenced_json_is_tolerated():
    assert gemini._parse_json_text('```json\n{"a": 1}\n```') == {"a": 1}


def test_chat_inference_runs_a_tool_round_and_replays_the_assistant_turn(
    monkeypatch,
):
    _cfg(monkeypatch, llm_route_chat="inference", gemini_web_search=False)
    call = inference_llm.FunctionCall(
        id="c1", name="remember", args={"fact": "x"},
        extra_content={"google": {"thought_signature": "sig"}},
    )
    first = _resp("", [call])
    first.assistant_message = {
        "role": "assistant", "content": "",
        "tool_calls": [{"id": "c1", "type": "function",
                        "function": {"name": "remember", "arguments": "{}"},
                        "extra_content": {"google": {"thought_signature": "sig"}}}],
    }
    replies = [first, _resp("Got it.")]
    sent = []

    async def fake_complete(**kw):
        sent.append([dict(m) for m in kw["messages"]])
        return replies.pop(0)

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)

    out = asyncio.run(
        gemini.generate_reply(
            "hi", system_prompt="p",
            tool_declarations=[{"name": "remember", "description": "d"}],
            tool_fns={"remember": lambda fact: "saved"},
        )
    )
    assert out.text == "Got it."
    assert out.tools_used == [gemini._tool_label("remember")]
    second = sent[1]
    assert second[-2]["tool_calls"][0]["extra_content"]["google"][
        "thought_signature"] == "sig"
    assert second[-1]["role"] == "tool" and second[-1]["tool_call_id"] == "c1"


def test_chat_web_search_is_a_function_tool_backed_by_grounded_research(
    monkeypatch,
):
    _cfg(monkeypatch, llm_route_chat="inference", gemini_web_search=True)
    tools_seen = {}
    call = inference_llm.FunctionCall(id="s1", name="web_search",
                                      args={"query": "who won"})
    replies = [_resp("", [call]), _resp("The Chiefs.")]

    async def fake_complete(**kw):
        tools_seen.setdefault("tools", kw["tools"])
        return replies.pop(0)

    async def fake_research(prompt, system_prompt=None, **kw):
        assert prompt == "who won"
        return "Chiefs won.", [{"url": "https://e.com", "title": "e"}]

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(gemini, "research", fake_research)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)

    out = asyncio.run(gemini.generate_reply("who won?", system_prompt="p"))
    assert [t["function"]["name"] for t in tools_seen["tools"]] == ["web_search"]
    assert out.text == "The Chiefs."
    assert out.tools_used == ["Searched the web"]


def test_chat_first_call_failure_falls_back_to_vertex(monkeypatch):
    _cfg(monkeypatch, llm_route_chat="inference", gemini_web_search=False)

    async def boom(**kw):
        raise RuntimeError("down")

    async def vertex(client, **kw):
        return SimpleNamespace(
            text="from vertex", function_calls=None, candidates=[],
            usage_metadata=None,
        )

    monkeypatch.setattr(inference_llm, "complete", boom)
    monkeypatch.setattr(gemini, "_client", lambda: object())
    monkeypatch.setattr(gemini, "_generate", vertex)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    assert asyncio.run(gemini.generate_reply("hi")).text == "from vertex"


def test_usage_maps_into_the_ledger_shape():
    raw = SimpleNamespace(
        prompt_tokens=100, completion_tokens=30, total_tokens=130,
        prompt_tokens_details=SimpleNamespace(cached_tokens=60),
    )
    meta = inference_llm._usage(raw)
    assert token_ledger._usage_from_response(
        SimpleNamespace(usage_metadata=meta)
    ) == (100, 30, 130, 60)


def test_inference_models_are_priced():
    cost = token_ledger.cost_usd_for(
        "chat", 1_000_000, 1_000_000, model="google/gemini-3.8-flash"
    )
    assert cost == pytest.approx(0.75 + 3.75)
    assert token_ledger.cost_usd_for(
        "voice", 1_000_000, 1_000_000, model="google/gemini-3.8-live"
    ) == pytest.approx(15.0)


def test_live_model_id_follows_voice_provider(monkeypatch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, voice_provider="inference"),
    )
    assert token_ledger.live_model_id() == CONFIG.inference_live_model


def test_to_openai_tools_and_parse():
    tools = inference_llm.to_openai_tools(
        [{"name": "t", "description": "d",
          "parameters": {"type": "object", "properties": {}}}]
    )
    assert tools[0]["function"]["name"] == "t"

    raw = SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(
            content=None,
            tool_calls=[SimpleNamespace(
                id="i", function=SimpleNamespace(name="t", arguments='{"a": 1}'),
                extra_content={"google": {"thought_signature": "s"}},
            )],
        ))],
        usage=None,
    )
    parsed = inference_llm._parse(raw)
    assert parsed.function_calls[0].args == {"a": 1}
    assert parsed.assistant_message["tool_calls"][0]["extra_content"]
    assert parsed.usage_metadata.prompt_token_count == 0


def test_missing_credentials_raise(monkeypatch):
    monkeypatch.delenv("LIVEKIT_API_KEY", raising=False)
    monkeypatch.delenv("LIVEKIT_API_SECRET", raising=False)
    with pytest.raises(RuntimeError):
        inference_llm._mint_token()


def test_minted_token_carries_the_inference_grant(monkeypatch):
    import jwt

    monkeypatch.setenv("LIVEKIT_API_KEY", "k")
    monkeypatch.setenv("LIVEKIT_API_SECRET", "s" * 32)
    claims = jwt.decode(inference_llm._mint_token(), "s" * 32, algorithms=["HS256"])
    assert claims["inference"]["perform"] is True
