"""LiveKit Inference routing (inference_llm.py + the gemini.py route switches).

The gateway is mocked at ``inference_llm.complete`` / the OpenAI client — no
network. Defaults must stay on Vertex."""

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
    """Config with the pre-rollout baseline (everything on Google, fallback on)
    unless a test says otherwise; the branch defaults are tested separately."""
    base = dict(
        llm_route_json="vertex", llm_route_vision="vertex", llm_route_chat="vertex",
        voice_provider="google", llm_inference_fallback=True,
    )
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, **{**base, **kw})
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
    _cfg(monkeypatch, voice_provider="inference")
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


def test_firestore_override_beats_env_and_supports_strings(monkeypatch):
    _cfg(monkeypatch)
    _doc(monkeypatch, {
        "json": "inference", "chat": {"provider": "inference", "percent": 0},
        "vision": {"provider": "bogus"}, "voice": {"provider": "inference"},
    })
    assert llm_routing.route_for("json") == "inference"
    assert llm_routing.route_for("chat") == "vertex"  # 0 %
    assert llm_routing.route_for("vision") == "vertex"  # invalid ignored
    assert llm_routing.route_for("voice") == "inference"


def test_percent_rollout_splits_traffic(monkeypatch):
    _cfg(monkeypatch)
    _doc(monkeypatch, {"json": {"provider": "inference", "percent": 30}})
    hits = sum(llm_routing.route_for("json") == "inference" for _ in range(4000))
    assert 0.24 < hits / 4000 < 0.36


def test_routing_doc_is_cached_and_failures_keep_last_good(monkeypatch):
    _cfg(monkeypatch)
    monkeypatch.undo()  # drop the autouse _read_docs stub for this test
    _cfg(monkeypatch)
    calls = []

    class _Snap:
        def __init__(self, name):
            self.exists = name == "llm_routing"
            self._name = name

        def to_dict(self):
            return {"json": "inference"}

    class _Doc:
        def __init__(self, name):
            self.name = name

        def get(self, timeout=None):
            calls.append(1)
            if len(calls) > 3:
                raise RuntimeError("firestore down")
            return _Snap(self.name)

    class _DB:
        def collection(self, _):
            return SimpleNamespace(document=lambda n: _Doc(n))

    import db

    monkeypatch.setattr(db, "get_db", lambda: _DB())
    llm_routing.reset_cache()
    assert llm_routing.route_for("json") == "inference"
    assert llm_routing.route_for("json") == "inference"
    assert len(calls) == 3  # one read per doc, then cached
    feature_flags._cache["at"] = -1e9  # expire
    assert llm_routing.route_for("json") == "inference"  # last good kept
    llm_routing.reset_cache()


def test_fallback_flag_can_be_flipped_at_runtime(monkeypatch):
    _cfg(monkeypatch)
    _doc(monkeypatch, {"fallback": False})
    assert llm_routing.fallback_enabled() is False


def test_fallback_is_recorded_with_provider_fields(monkeypatch):
    _cfg(monkeypatch, llm_route_json="inference")
    monkeypatch.setattr(llm_routing, "route_for", lambda g: "inference")

    async def boom(**kw):
        raise RuntimeError("timeout")

    async def vertex(client, **kw):
        return SimpleNamespace(text="{}", usage_metadata=None)

    seen = {}
    monkeypatch.setattr(inference_llm, "complete", boom)
    monkeypatch.setattr(gemini, "_client", lambda: object())
    monkeypatch.setattr(gemini, "_generate", vertex)
    monkeypatch.setattr(
        token_ledger, "record", lambda *a, **k: seen.update(k)
    )
    asyncio.run(gemini.generate_json("c", "s", None, enforce_cap=False))
    assert seen["fallback_from"] == token_ledger.PROVIDER_LIVEKIT_INFERENCE


def test_provider_for_models():
    assert token_ledger.provider_for("chat", "google/gemini-3.8-flash") == "livekit_inference"
    assert token_ledger.provider_for("voice", "google/gemini-3.8-live") == "livekit_inference"
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
    _cfg(monkeypatch, llm_route_vision="inference")
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


def test_vision_stays_on_vertex_by_default(monkeypatch):
    _cfg(monkeypatch)

    async def never(**kw):
        raise AssertionError("gateway must not be called")

    async def vertex(client, **kw):
        return SimpleNamespace(text='{"v": 1}', usage_metadata=None)

    monkeypatch.setattr(inference_llm, "complete", never)
    monkeypatch.setattr(gemini, "_client", lambda: object())
    monkeypatch.setattr(gemini, "_generate", vertex)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    assert asyncio.run(gemini.generate_json(
        "c", "s", None, image=(b"x", "image/png"), enforce_cap=False
    )) == {"v": 1}


def test_vision_inference_failure_falls_back_with_tag(monkeypatch):
    _cfg(monkeypatch, llm_route_vision="inference")
    seen = {}

    async def boom(**kw):
        raise RuntimeError("content_filter")

    async def vertex(client, **kw):
        return SimpleNamespace(text='{"v": 1}', usage_metadata=None)

    monkeypatch.setattr(inference_llm, "complete", boom)
    monkeypatch.setattr(gemini, "_client", lambda: object())
    monkeypatch.setattr(gemini, "_generate", vertex)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: seen.update(k))
    asyncio.run(gemini.generate_json(
        "c", "s", None, image=(b"x", "image/png"), enforce_cap=False
    ))
    assert seen["fallback_from"] == token_ledger.PROVIDER_LIVEKIT_INFERENCE


def test_moderation_fails_closed_when_both_providers_fail(monkeypatch):
    import photo_moderation

    _cfg(monkeypatch, llm_route_vision="inference")

    async def boom(**kw):
        raise RuntimeError("down")

    async def vertex_boom(client, **kw):
        raise RuntimeError("vertex down")

    monkeypatch.setattr(inference_llm, "complete", boom)
    monkeypatch.setattr(gemini, "_client", lambda: object())
    monkeypatch.setattr(gemini, "_generate", vertex_boom)
    out = asyncio.run(photo_moderation.moderate(b"x", "image/jpeg"))
    assert out["allowed"] is False and out["reason"] == "moderation_error"


def test_moderation_uses_inference_verdict(monkeypatch):
    import photo_moderation

    _cfg(monkeypatch, llm_route_vision="inference")

    async def fake_complete(**kw):
        return _resp('{"allowed": true, "reason": "", "categories": []}')

    monkeypatch.setattr(inference_llm, "complete", fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    assert asyncio.run(photo_moderation.moderate(b"x", "image/jpeg"))["allowed"]


def test_dm_voice_note_wav_goes_to_inference_as_input_audio(monkeypatch):
    import dm_ingest

    _cfg(monkeypatch, llm_route_vision="inference")
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
def test_unsupported_media_skips_inference_without_fallback_tag(monkeypatch, mime):
    _cfg(monkeypatch, llm_route_vision="inference")
    seen = {}

    async def never(**kw):
        raise AssertionError("gateway must not be called")

    async def vertex(client, **kw):
        return SimpleNamespace(text='{"text": "x"}', usage_metadata=None)

    monkeypatch.setattr(inference_llm, "complete", never)
    monkeypatch.setattr(gemini, "_client", lambda: object())
    monkeypatch.setattr(gemini, "_generate", vertex)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: seen.update(k))
    asyncio.run(gemini.generate_json(
        "c", "s", None, image=(b"x", mime), enforce_cap=False
    ))
    assert seen.get("fallback_from") is None


def test_media_part_shapes():
    assert inference_llm.media_part(b"x", "image/jpeg")["type"] == "image_url"
    assert inference_llm.media_part(b"x", "audio/mpeg; codecs=x")["input_audio"][
        "format"] == "mp3"
    assert inference_llm.media_part(b"x", "audio/ogg") is None


def test_voice_allowlist_limits_inference_to_listed_uids(monkeypatch):
    _cfg(monkeypatch)
    _doc(monkeypatch, {
        "voice": {"provider": "inference", "percent": 100, "allowlist": ["founder"]},
    })
    assert llm_routing.route_for("voice", uid="founder") == "inference"
    assert llm_routing.route_for("voice", uid="someone") == "vertex"
    assert llm_routing.route_for("voice") == "vertex"


def test_voice_allowlist_empty_or_invalid_does_not_restrict(monkeypatch):
    _cfg(monkeypatch)
    for allow in ([], "founder"):
        _doc(monkeypatch, {"voice": {"provider": "inference", "allowlist": allow}})
        assert llm_routing.route_for("voice", uid="anyone") == "inference"


def test_voice_percent_applies_within_allowlist(monkeypatch):
    _cfg(monkeypatch)
    _doc(monkeypatch, {
        "voice": {"provider": "inference", "percent": 0, "allowlist": ["founder"]},
    })
    assert llm_routing.route_for("voice", uid="founder") == "vertex"


def test_voice_default_stays_google_without_doc(monkeypatch):
    _cfg(monkeypatch)
    _doc(monkeypatch, {})
    assert llm_routing.route_for("voice", uid="founder") == "vertex"


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
