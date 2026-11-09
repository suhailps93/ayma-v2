"""LiveKit Inference routing (inference_llm.py + the gemini.py call sites).

The gateway is mocked at ``inference_llm.complete`` / the OpenAI client — no
network. Founder rule (2026-11-04, permanent): Inference is the ONLY route —
no Vertex branch, no fallback, no percent/allowlist splitting. A gateway
failure raises honestly.
"""

from __future__ import annotations

import asyncio
import dataclasses
from types import SimpleNamespace

import pytest

import config
import feature_flags
import gemini
import inference_llm
import llm_routing
import token_ledger
from config import CONFIG


def _resp(text="", calls=None, usage=(10, 5, 15, 0), finish_reason=None):
    p, c, t, cached = usage
    return inference_llm.InferenceResponse(
        text=text,
        function_calls=calls or [],
        assistant_message={"role": "assistant", "content": text},
        usage_metadata=SimpleNamespace(
            prompt_token_count=p, candidates_token_count=c,
            total_token_count=t, cached_content_token_count=cached,
        ),
        finish_reason=finish_reason,
    )


def _cfg(monkeypatch, **kw):
    """Config patched with test overrides (branch defaults are asserted
    separately); routing ignores these for provider choice."""
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, **kw)
    )
    monkeypatch.setattr(inference_llm, "CONFIG", gemini.CONFIG)
    monkeypatch.setattr(feature_flags, "CONFIG", gemini.CONFIG)


def _doc(monkeypatch, legacy: dict) -> None:
    """Serve a legacy-shaped ``config/llm_routing`` doc through the flag loader."""
    monkeypatch.setattr(
        feature_flags, "_read_docs", lambda: feature_flags._legacy_routing(legacy)
    )


def test_branch_defaults_route_everything_through_inference_without_fallback():
    assert CONFIG.llm_route_json == "inference"
    assert CONFIG.llm_route_vision == "inference"
    assert CONFIG.llm_route_chat == "inference"
    assert CONFIG.voice_provider == "inference"
    assert CONFIG.llm_percent_voice == 100
    assert CONFIG.llm_inference_fallback is False


def test_invalid_route_env_fails_loudly(monkeypatch):
    monkeypatch.setenv("LLM_ROUTE_JSON", "inferense")
    with pytest.raises(ValueError):
        config._load()


def test_generate_json_routes_to_inference_and_meters(monkeypatch):
    _cfg(monkeypatch)
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


def test_json_with_images_goes_to_inference(monkeypatch):
    _cfg(monkeypatch)
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


def test_json_inference_failure_raises_without_fallback(monkeypatch):
    _cfg(monkeypatch)
    calls = []
    recorded = []

    async def boom(**kw):
        calls.append(kw)
        raise RuntimeError("429")

    monkeypatch.setattr(inference_llm, "complete", boom)
    monkeypatch.setattr(
        token_ledger, "record",
        lambda *a, **k: recorded.append((a, k)),
    )
    with pytest.raises(RuntimeError):
        asyncio.run(gemini.generate_json("c", "s", None, enforce_cap=False))
    assert len(calls) == 1  # the gateway was tried once, nothing else
    assert recorded == []  # a failed call meters nothing


def test_fenced_json_is_tolerated():
    assert gemini._parse_json_text('```json\n{"a": 1}\n```') == {"a": 1}


def test_chat_inference_runs_a_tool_round_and_replays_the_assistant_turn(
    monkeypatch,
):
    _cfg(monkeypatch, gemini_web_search=False)
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


def test_chat_web_search_tool_reports_unavailable_honestly_when_unconfigured(
    monkeypatch,
):
    # Since the 2026-11-07 capped-search restore the tool works when search
    # is configured; with no key/engine configured it must still surface an
    # honest "not available" tool result the model relays — the turn
    # completes, and no provider call is ever attempted.
    _cfg(monkeypatch, gemini_web_search=True)
    tools_seen = {}
    call = inference_llm.FunctionCall(id="s1", name="web_search",
                                      args={"query": "who won"})
    replies = [_resp("", [call]), _resp("Search is unavailable right now.")]

    async def fake_complete(**kw):
        tools_seen.setdefault("tools", kw["tools"])
        tools_seen.setdefault("sent", []).append([dict(m) for m in kw["messages"]])
        return replies.pop(0)

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)

    # The tool arrives via the skills registry composition (the caller
    # passes its declaration + bound fn), as in production since the
    # 2026-11-07 fix — gemini.py no longer hand-appends it.
    from skills import web_search as _ws_skill

    out = asyncio.run(
        gemini.generate_reply(
            "who won?",
            system_prompt="p",
            tool_declarations=[_ws_skill.DECLARATION],
            tool_fns={"web_search": _ws_skill.SKILL.bind(object(), "u1")},
        )
    )
    assert [t["function"]["name"] for t in tools_seen["tools"]] == ["web_search"]
    tool_msg = tools_seen["sent"][1][-1]
    assert tool_msg["role"] == "tool"
    assert "not available" in tool_msg["content"]
    assert "internal error" not in tool_msg["content"].lower()
    assert out.text == "Search is unavailable right now."
    assert out.tools_used == ["Searched the web"]


def test_chat_passes_configured_completion_budget(monkeypatch):
    # The budget is a single source in config.py, never a literal in gemini.py.
    _cfg(monkeypatch, gemini_web_search=False, inference_chat_max_tokens=8192)
    seen = {}

    async def fake_complete(**kw):
        seen.update(kw)
        return _resp("hello")

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    out = asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert out.text == "hello"
    assert seen["max_tokens"] == 8192


def test_chat_throws_when_completion_budget_not_configured(monkeypatch):
    _cfg(monkeypatch, gemini_web_search=False, inference_chat_max_tokens=0)

    async def fake_complete(**kw):  # pragma: no cover - must not be reached
        raise AssertionError("gateway must not be called without a budget")

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    with pytest.raises(RuntimeError):
        asyncio.run(gemini.generate_reply("hi", system_prompt="p"))


def test_parse_captures_finish_reason():
    raw = SimpleNamespace(
        choices=[SimpleNamespace(
            finish_reason="length",
            message=SimpleNamespace(content="", tool_calls=None),
        )],
        usage=None,
    )
    assert inference_llm._parse(raw).finish_reason == "length"


def test_chat_empty_length_retries_once_with_a_larger_budget(monkeypatch):
    _cfg(monkeypatch, gemini_web_search=False, inference_chat_max_tokens=8192)
    budgets = []
    replies = [
        _resp("", finish_reason="length"),  # all budget spent on reasoning
        _resp("Here you go."),              # room to answer at 2x
    ]

    async def fake_complete(**kw):
        budgets.append(kw["max_tokens"])
        return replies.pop(0)

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    out = asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert out.text == "Here you go."
    assert budgets == [8192, 16384]  # one retry at 2x, no loop


def test_chat_empty_length_retry_still_empty_raises(monkeypatch):
    _cfg(monkeypatch, gemini_web_search=False, inference_chat_max_tokens=8192)
    calls = []

    async def fake_complete(**kw):
        calls.append(kw["max_tokens"])
        return _resp("", finish_reason="length")

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    with pytest.raises(RuntimeError):
        asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert calls == [8192, 16384]  # tried once more, then gave up honestly


def test_chat_empty_non_length_does_not_retry_and_raises(monkeypatch):
    _cfg(monkeypatch, gemini_web_search=False, inference_chat_max_tokens=8192)
    calls = []

    async def fake_complete(**kw):
        calls.append(kw["max_tokens"])
        return _resp("", finish_reason="stop")  # genuinely empty, not truncated

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    with pytest.raises(RuntimeError):
        asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert calls == [8192]  # no retry for a non-length empty


def test_chat_non_empty_response_passes_straight_through(monkeypatch):
    _cfg(monkeypatch, gemini_web_search=False, inference_chat_max_tokens=8192)
    calls = []

    async def fake_complete(**kw):
        calls.append(kw["max_tokens"])
        return _resp("All good.", finish_reason="stop")

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    out = asyncio.run(gemini.generate_reply("hi", system_prompt="p"))
    assert out.text == "All good."
    assert calls == [8192]  # no retry when content is present


def test_chat_first_call_failure_raises_without_fallback(monkeypatch):
    _cfg(monkeypatch, gemini_web_search=False)

    async def boom(**kw):
        raise RuntimeError("down")

    monkeypatch.setattr(inference_llm, "complete", boom)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    with pytest.raises(RuntimeError):
        asyncio.run(gemini.generate_reply("hi"))


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


def test_live_model_id_is_always_the_inference_model(monkeypatch):
    _cfg(monkeypatch)
    monkeypatch.setattr(token_ledger, "CONFIG", gemini.CONFIG)
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


def test_routing_overrides_are_ignored_everything_stays_on_inference(
    monkeypatch,
):
    """A hostile routing doc (every group pinned to Vertex/Google, percents 0,
    fallback on) cannot re-arm the direct path — the settings are retained
    but no longer honored."""
    _cfg(monkeypatch)
    _doc(monkeypatch, {
        "json": "vertex",
        "chat": {"provider": "vertex", "percent": 0},
        "vision": {"provider": "vertex"},
        "voice": {"provider": "google", "percent": 0, "allowlist": ["founder"]},
        "fallback": True,
    })
    for group in ("json", "vision", "chat", "voice"):
        assert llm_routing.route_for(group) == "inference"
        assert llm_routing.route_for(group, uid="founder") == "inference"
        assert llm_routing.route_for(group, uid="someone") == "inference"
    assert llm_routing.fallback_enabled() is False


def test_percent_allowlist_and_env_overrides_are_ignored(monkeypatch):
    _cfg(monkeypatch)
    monkeypatch.setenv("FLAG_LLM_ROUTE_JSON", "vertex")
    monkeypatch.setenv("FLAG_VOICE_PROVIDER", "google")
    monkeypatch.setenv("FLAG_LLM_FALLBACK_TO_GOOGLE", "true")
    _doc(monkeypatch, {
        "json": {"provider": "inference", "percent": 30},
        "voice": {"provider": "inference", "percent": 0,
                  "allowlist": ["founder"]},
    })
    for _ in range(50):
        assert llm_routing.route_for("json") == "inference"
        assert llm_routing.route_for("voice", uid="founder") == "inference"
        assert llm_routing.route_for("voice", uid="someone") == "inference"
        assert llm_routing.route_for("voice") == "inference"
    assert llm_routing.fallback_enabled() is False


def test_provider_for_models():
    assert token_ledger.provider_for("chat", "google/gemini-3.8-flash") == "livekit_inference"
    assert token_ledger.provider_for("voice", "google/gemini-3.8-live") == "livekit_inference"
    # Historical rows (pre-kill) still map to the direct providers.
    assert token_ledger.provider_for("chat", "gemini-3.7-flash") == "google_vertex"
    assert token_ledger.provider_for("voice", "gemini-3.8-live") in (
        "google_vertex", "google_dev_api")


def test_add_writes_provider_and_fallback_fields(monkeypatch):
    events, user_writes = [], []

    class _Col:
        def add(self, e):
            events.append(e)

        def count(self):
            return SimpleNamespace(get=lambda: [[SimpleNamespace(value=1)]])

    class _User:
        def set(self, d, merge=False):
            user_writes.append(d)

        def collection(self, _):
            return _Col()

    monkeypatch.setattr(
        token_ledger, "get_db",
        lambda: SimpleNamespace(collection=lambda _: SimpleNamespace(document=lambda _: _User())),
    )
    token_ledger.add(
        "u", "chat", 150, input_tokens=100, output_tokens=50,
        model="gemini-3.7-flash", fallback_from="livekit_inference",
    )
    assert events[0]["provider"] == "google_vertex"
    assert events[0]["fallback_from"] == "livekit_inference"
    prov = user_writes[0]["token_usage"]["providers"]["google_vertex"]
    assert set(prov) == {"tokens", "cost_usd", "features", "fallbacks"}


# --- vision / media routing -------------------------------------------------

_VISION_FEATURES = [
    token_ledger.FEATURE_BODY_REPORT, token_ledger.FEATURE_FACE_REPORT,
    token_ledger.FEATURE_PHYSICAL_ATTRS, token_ledger.FEATURE_PHOTO_ATTRS,
    token_ledger.FEATURE_PHOTO_CAPTION, token_ledger.FEATURE_PHOTO_MODERATION,
    token_ledger.FEATURE_DEEPDIVE, token_ledger.FEATURE_DM_INGEST,
]


@pytest.mark.parametrize("feature", _VISION_FEATURES)
def test_every_vision_feature_routes_to_inference_and_is_provider_tagged(
    monkeypatch, feature
):
    _cfg(monkeypatch)
    recorded = []

    async def fake_complete(**kw):
        return _resp('{"ok": true}')

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(
        token_ledger, "record",
        lambda uid, f, response, **kw: recorded.append((f, kw)),
    )
    out = asyncio.run(gemini.generate_json(
        "c", "s", None, images=[(b"\xff\xd8", "image/jpeg")] * 2,
        feature=feature, enforce_cap=False,
    ))
    assert out == {"ok": True}
    assert recorded[0][0] == feature
    assert token_ledger.provider_for(feature, recorded[0][1]["model"]) == (
        token_ledger.PROVIDER_LIVEKIT_INFERENCE
    )
    assert "fallback_from" not in recorded[0][1]


def test_vision_goes_to_inference_by_default(monkeypatch):
    _cfg(monkeypatch)
    seen = {}

    async def fake_complete(**kw):
        seen.update(kw)
        return _resp('{"v": 1}')

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    assert asyncio.run(gemini.generate_json(
        "c", "s", None, image=(b"x", "image/png"), enforce_cap=False
    )) == {"v": 1}
    assert seen["model"] == CONFIG.inference_json_model


def test_vision_inference_failure_raises_without_fallback(monkeypatch):
    _cfg(monkeypatch)

    async def boom(**kw):
        raise RuntimeError("content_filter")

    monkeypatch.setattr(inference_llm, "complete", boom)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    with pytest.raises(RuntimeError):
        asyncio.run(gemini.generate_json(
            "c", "s", None, image=(b"x", "image/png"), enforce_cap=False
        ))


def test_moderation_fails_closed_when_inference_fails(monkeypatch):
    import photo_moderation

    _cfg(monkeypatch)

    async def boom(**kw):
        raise RuntimeError("down")

    monkeypatch.setattr(inference_llm, "complete", boom)
    out = asyncio.run(photo_moderation.moderate(b"x", "image/jpeg"))
    assert out["allowed"] is False and out["reason"] == "moderation_error"


def test_moderation_uses_inference_verdict(monkeypatch):
    import photo_moderation

    _cfg(monkeypatch)

    async def fake_complete(**kw):
        return _resp('{"allowed": true, "reason": "", "categories": []}')

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    assert asyncio.run(photo_moderation.moderate(b"x", "image/jpeg"))["allowed"]


def test_dm_voice_note_wav_goes_to_inference_as_input_audio(monkeypatch):
    import dm_ingest

    _cfg(monkeypatch)
    seen = {}

    async def fake_complete(**kw):
        seen.update(kw)
        return _resp('{"text": "hello there"}')

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    assert asyncio.run(dm_ingest._voice_transcript(b"RIFF", "audio/wav")) == (
        "hello there"
    )
    part = seen["messages"][1]["content"][0]
    assert part["type"] == "input_audio" and part["input_audio"]["format"] == "wav"


@pytest.mark.parametrize("mime", ["audio/mp4", "audio/webm", "image/heic"])
def test_unsupported_media_raises_instead_of_going_to_vertex(monkeypatch, mime):
    """Media the gateway cannot take raises honestly — the silent straight-to-
    Vertex path is gone."""
    _cfg(monkeypatch)

    async def never(**kw):
        raise AssertionError("gateway must not be called")

    monkeypatch.setattr(inference_llm, "complete", never)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    with pytest.raises(llm_routing.DirectGoogleDisabledError):
        asyncio.run(gemini.generate_json(
            "c", "s", None, image=(b"x", mime), enforce_cap=False
        ))


def test_media_part_shapes():
    assert inference_llm.media_part(b"x", "image/jpeg")["type"] == "image_url"
    assert inference_llm.media_part(b"x", "audio/mpeg; codecs=x")["input_audio"][
        "format"] == "mp3"
    assert inference_llm.media_part(b"x", "audio/ogg") is None


def test_persist_raw_turns_tags_voice_provider():
    import post_turn
    from transcript import Turn

    class Db:
        def collection(self, _n):
            return self

        def document(self, _n):
            return self

        def set(self, payload, merge=False):
            self.payload = payload

    db = Db()
    db.doc = db
    post_turn.persist_raw_turns(
        db, "u", "s", [Turn(role="user", text="hi")], voice_provider="livekit_inference"
    )
    assert db.doc.payload["voice_provider"] == "livekit_inference"
    post_turn.persist_raw_turns(db, "u", "s", [Turn(role="user", text="hi")])
    assert "voice_provider" not in db.doc.payload


# --- disabled direct-Google sub-paths ---------------------------------------

def test_research_is_disabled():
    with pytest.raises(llm_routing.DirectGoogleDisabledError):
        asyncio.run(gemini.research("q"))


def test_generate_image_and_edit_image_route_through_image_gen(monkeypatch):
    """Image generation is the ONE founder-authorized direct-Google exception
    (2026-11-08): generate_image / edit_image are restored and route through
    image_gen (where the scoped direct call + cap live). They no longer raise
    DirectGoogleDisabledError; an ``ok`` outcome returns (bytes, mime)."""
    import image_gen

    seen = []

    async def fake_generate(prompt, *, image=None, uid=None, feature="misc"):
        seen.append((prompt, image, uid, feature))
        return image_gen.ImageOutcome(
            image_gen.STATUS_OK, image_bytes=b"PNGBYTES", mime="image/png"
        )

    monkeypatch.setattr(image_gen, "generate", fake_generate)
    monkeypatch.setattr(gemini.token_ledger, "check", lambda uid: None)

    assert asyncio.run(gemini.generate_image("a sunset")) == (
        b"PNGBYTES", "image/png"
    )
    assert asyncio.run(
        gemini.edit_image(b"x", "image/png", "make it pop")
    ) == (b"PNGBYTES", "image/png")
    # edit_image grounds the generation in the input image.
    assert seen[1][1] == (b"x", "image/png")


def test_generate_image_surfaces_the_honest_outcome_message(monkeypatch):
    """A non-ok outcome (paused/unconfigured/error) raises RuntimeError with
    the outcome's user-safe message — never a silent image, never a stub."""
    import image_gen

    async def fake_generate(prompt, *, image=None, uid=None, feature="misc"):
        return image_gen.ImageOutcome(
            image_gen.STATUS_PAUSED, message=image_gen.PAUSED_MESSAGE
        )

    monkeypatch.setattr(image_gen, "generate", fake_generate)
    monkeypatch.setattr(gemini.token_ledger, "check", lambda uid: None)
    with pytest.raises(RuntimeError) as exc:
        asyncio.run(gemini.generate_image("a sunset"))
    assert "used up for today" in str(exc.value)


def test_embeddings_are_gone_and_face_match_is_the_seam():
    """Stored face embeddings are gone (Nov 8 founder decision: replaced by
    the pairwise LiveKit face check). media_embed is a plain storage
    downloader now — no embedding function is exposed anywhere — and
    identity checks go through face_match instead."""
    import deep_dive_images
    import face_match
    import media_embed

    assert not hasattr(media_embed, "embed_image_bytes")
    assert not hasattr(media_embed, "find_similar_media")
    assert not hasattr(media_embed, "process_media")
    assert not hasattr(deep_dive_images, "reference_embeddings_for")
    assert not hasattr(deep_dive_images, "classify_face_match")
    assert callable(face_match.classify_photo)
    assert callable(face_match.check_same_person)
    assert callable(face_match.get_reference_photos)


def test_batch_submit_and_poll_are_disabled():
    import gemini_batch

    with pytest.raises(llm_routing.DirectGoogleDisabledError):
        gemini_batch.submit_json_batch(["a"], "s", {}, job_tag="t")
    with pytest.raises(llm_routing.DirectGoogleDisabledError):
        gemini_batch.poll_json_batch("job-1")


def test_voice_preview_synthesis_is_disabled():
    import voice_preview

    with pytest.raises(llm_routing.DirectGoogleDisabledError):
        asyncio.run(voice_preview._synthesize("Aoede"))


def test_warmup_pings_the_gateway_and_never_raises(monkeypatch):
    seen = {}

    async def fake_complete(**kw):
        seen.update(kw)
        return _resp("pong")

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    asyncio.run(gemini.warmup())  # must not raise
    assert seen["model"] == CONFIG.inference_chat_model

    async def boom(**kw):
        raise RuntimeError("down")

    monkeypatch.setattr(inference_llm, "complete", boom)
    asyncio.run(gemini.warmup())  # best-effort: still must not raise


def test_generate_json_logs_the_raw_reply_when_unparseable(monkeypatch, caplog):
    """A model reply that fails to parse (e.g. filler padding that burned
    the completion budget and truncated the JSON) must leave the raw reply
    in the log — best-effort callers swallow the raise, so without this the
    failure is undiagnosable."""
    import json as _json
    import logging as _logging

    _cfg(monkeypatch)

    async def fake_complete(**kw):
        return _resp("{\"chips\": [\"this reply never ends", finish_reason="length")

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    with caplog.at_level(_logging.WARNING, logger="ayma.gemini"):
        with pytest.raises(_json.JSONDecodeError):
            asyncio.run(
                gemini.generate_json(
                    "c", "sys", {"type": "object"}, uid="u1",
                    feature="icebreakers", enforce_cap=False,
                )
            )
    assert "unparseable model reply" in caplog.text
    assert "finish_reason=length" in caplog.text
    assert "this reply never ends" in caplog.text
