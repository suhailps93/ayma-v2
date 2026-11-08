"""LiveKit Inference brains (founder order 2026-11-07: "Wire all the
LiveKit models in").

Every non-Gemini model in the live LiveKit Inference LLM catalog is a
selectable Brain vendor, served ONLY through ``inference_llm.complete``
(the same gateway + project LiveKit credentials Gemini uses) by
:class:`llm_provider.LiveKitProvider`. These tests pin: resolvability,
the credited gate, truthful capability/vision flags, the GPT-5 token
parameter, voice-catalog mapping, and selection integrity — a saved pick
serves, and a failed call raises instead of falling back to Gemini.
GLM is absent on purpose: it is not in the live catalog.
"""

import dataclasses
from types import SimpleNamespace

import pytest

import llm_provider
import voice_catalog as vc
from config import CONFIG
from llm_provider import (
    CAP_JSON,
    CAP_TEXT,
    CAP_TOOLS,
    CAP_VISION,
    CAP_WEB,
    LIVEKIT_BRAIN_VENDORS,
    LiveKitProvider,
    available_brains,
    brain_capabilities,
    brain_is_credited,
    get_llm_provider,
    get_user_brain_provider,
    livekit_brain_model,
)

# vendor -> the catalog model id from the live LiveKit Inference LLM
# catalog (docs.livekit.io/agents/models/llm, fetched 2026-11-07).
EXPECTED_MODELS = {
    "gemma": "google/gemma-4-31b-it",
    "openai": "openai/gpt-5",
    "openai-chat": "openai/chat-latest",
    "openai-oss": "openai/gpt-oss-120b",
    "kimi": "moonshotai/kimi-k2.6",
    "deepseek": "deepseek-ai/deepseek-v4-pro",
    "grok": "xai/grok-4.7",
}

STAGING_CREDITED = (
    "gemini", "gemma", "openai", "openai-chat", "openai-oss",
    "kimi", "deepseek", "grok",
)


def _config(monkeypatch, **over):
    cfg = dataclasses.replace(CONFIG, **over)
    for mod in (llm_provider, vc):
        monkeypatch.setattr(mod, "CONFIG", cfg)
    vc.clear_cache()
    return cfg


class _FakeResponse:
    def __init__(self, text="", function_calls=None, finish_reason="stop"):
        self.text = text
        self.function_calls = function_calls or []
        self.finish_reason = finish_reason
        self.usage_metadata = None


def _fake_complete(text='{"chips": ["a", "b", "c"], "tip": "t"}', calls=None):
    async def _complete(**kwargs):
        if calls is not None:
            calls.append(kwargs)
        return _FakeResponse(text=text)
    return _complete


# --- catalog + config wiring ----------------------------------------------


def test_vendor_set_matches_the_live_catalog():
    assert set(LIVEKIT_BRAIN_VENDORS) == set(EXPECTED_MODELS)
    # No GLM: absent from the live LiveKit catalog — never invent an id.
    assert "glm" not in LIVEKIT_BRAIN_VENDORS
    assert livekit_brain_model("glm") == ""


def test_every_vendor_resolves_to_its_catalog_model_id():
    for vendor, model in EXPECTED_MODELS.items():
        assert livekit_brain_model(vendor) == model
        provider = llm_provider._provider_for_name(vendor)
        assert isinstance(provider, LiveKitProvider)
        assert provider.name == vendor
        assert provider.model == model


def test_get_llm_provider_accepts_livekit_vendors(monkeypatch):
    # The surface flags are dataclass fields read via lambdas over the
    # module CONFIG; replacing the whole config object is the reliable pin.
    cfg = dataclasses.replace(CONFIG, llm_provider_chat="kimi")
    monkeypatch.setattr(llm_provider, "CONFIG", cfg)
    provider = get_llm_provider("chat")
    assert isinstance(provider, LiveKitProvider)
    assert provider.name == "kimi"


def test_catalog_entries_exist_with_labels():
    for vendor in LIVEKIT_BRAIN_VENDORS:
        entry = llm_provider.BRAINS[vendor]
        assert entry["id"] == vendor
        assert entry["label"] and entry["description"]
        assert entry["available"] is True
        # Vendor ids, never model ids, in the user-facing catalog.
        assert "/" not in vendor


# --- capabilities: truthful vision flags -----------------------------------


def test_capability_flags_match_live_probe_facts():
    # Vision verified live through the gateway 2026-11-07 (known-image
    # probe): GPT-5, ChatGPT Latest and Kimi read it; Gemma answered wrong
    # twice and Grok rejects image input with HTTP 422, so both are
    # vision-less on this serving path and image jobs route to Gemini.
    assert CAP_VISION in brain_capabilities("openai")
    assert CAP_VISION in brain_capabilities("openai-chat")
    assert CAP_VISION in brain_capabilities("kimi")
    for vendor in ("gemma", "openai-oss", "deepseek", "grok"):
        assert CAP_VISION not in brain_capabilities(vendor)
    for vendor in LIVEKIT_BRAIN_VENDORS:
        caps = brain_capabilities(vendor)
        assert CAP_TEXT in caps and CAP_JSON in caps
        # No LiveKit brain has Gemini's web grounding.
        assert CAP_WEB not in caps
        assert LiveKitProvider(vendor).supports_vision == (
            CAP_VISION in caps
        )
    # GPT OSS uses a different native tool format — tools stay on Gemini.
    assert CAP_TOOLS not in brain_capabilities("openai-oss")


# --- credited gate ------------------------------------------------------------


def test_livekit_vendors_credited_by_default_and_on_staging_pin(monkeypatch):
    for vendor in LIVEKIT_BRAIN_VENDORS:
        assert brain_is_credited(vendor) is True  # shipped default config
    _config(monkeypatch, brain_credited_providers=STAGING_CREDITED)
    for vendor in LIVEKIT_BRAIN_VENDORS:
        assert brain_is_credited(vendor) is True
    ids = [b["id"] for b in available_brains()]
    assert ids == ["gemini", *LIVEKIT_BRAIN_VENDORS]
    assert "meta" not in ids


def test_livekit_vendor_hidden_when_not_credited(monkeypatch):
    _config(monkeypatch, brain_credited_providers=("gemini",))
    assert [b["id"] for b in available_brains()] == ["gemini"]
    assert brain_is_credited("grok") is False


# --- selection integrity -------------------------------------------------------


def _saved(monkeypatch, value):
    monkeypatch.setattr(llm_provider, "read_brain_pref", lambda uid: value)


@pytest.mark.asyncio
async def test_saved_pick_serves_through_livekit_transport(monkeypatch):
    _saved(monkeypatch, "kimi")
    provider = get_user_brain_provider("u1", "chat", needs=CAP_TEXT)
    assert isinstance(provider, LiveKitProvider)
    calls = []
    provider._complete = _fake_complete(text="hello from kimi", calls=calls)
    reply = await provider.generate_reply("hi", "sys", uid="u1", feature="chat")
    assert reply.text == "hello from kimi"
    assert calls and calls[0]["model"] == "moonshotai/kimi-k2.6"


@pytest.mark.asyncio
async def test_saved_pick_json_parses(monkeypatch):
    _saved(monkeypatch, "deepseek")
    provider = get_user_brain_provider("u1", "dm_coach", needs=CAP_JSON)
    provider._complete = _fake_complete()
    out = await provider.generate_json("ctx", "sys", {"type": "object"})
    assert out["chips"] == ["a", "b", "c"]


@pytest.mark.asyncio
async def test_failed_call_raises_never_falls_back(monkeypatch):
    _saved(monkeypatch, "grok")

    async def _boom(**kwargs):
        raise RuntimeError("gateway down")

    provider = get_user_brain_provider("u1", "chat", needs=CAP_TEXT)
    provider._complete = _boom
    with pytest.raises(RuntimeError, match="gateway down"):
        await provider.generate_reply("hi", "sys")


def test_capability_gap_still_routes_to_gemini(monkeypatch):
    _saved(monkeypatch, "grok")
    # Grok has no vision on this path: a vision-needing call is Gemini's.
    provider = get_user_brain_provider("u1", "reports", needs=CAP_VISION)
    assert provider.name == "gemini"
    provider = get_user_brain_provider("u1", "chat", needs=CAP_WEB)
    assert provider.name == "gemini"


@pytest.mark.asyncio
async def test_json_parse_failure_retries_once_on_same_brain():
    # Grok intermittently returns truncated JSON through the gateway; the
    # provider retries the SAME brain once, then succeeds.
    texts = iter(['{"chips": ["cut off', '{"chips": ["a"], "tip": "t"}'])
    calls = []

    async def _flaky(**kwargs):
        calls.append(kwargs)
        return _FakeResponse(text=next(texts))

    provider = LiveKitProvider("grok", complete=_flaky)
    out = await provider.generate_json("c", "s", {"type": "object"})
    assert out["chips"] == ["a"]
    assert len(calls) == 2
    assert all(c["model"] == "xai/grok-4.7" for c in calls)


@pytest.mark.asyncio
async def test_json_parse_failure_twice_raises():
    provider = LiveKitProvider(
        "grok", complete=_fake_complete(text='{"chips": ["cut off')
    )
    with pytest.raises(Exception):
        await provider.generate_json("c", "s", {"type": "object"})


@pytest.mark.asyncio
async def test_vision_less_brain_refuses_image_payload():
    provider = LiveKitProvider("deepseek", complete=_fake_complete(text="x"))
    with pytest.raises(RuntimeError, match="cannot process images"):
        await provider.generate_json(
            "describe", "sys", {"type": "object"},
            image=(b"\x89PNG", "image/png"),
        )


# --- transport parameter shape -----------------------------------------------


@pytest.mark.asyncio
async def test_gpt5_family_uses_max_completion_tokens():
    for vendor in ("openai", "openai-chat"):
        calls = []
        provider = LiveKitProvider(vendor, complete=_fake_complete(calls=calls))
        await provider.generate_json("c", "s", {"type": "object"})
        assert "max_completion_tokens" in calls[0]
        assert "max_tokens" not in calls[0]


@pytest.mark.asyncio
async def test_other_vendors_use_max_tokens():
    calls = []
    provider = LiveKitProvider("kimi", complete=_fake_complete(calls=calls))
    await provider.generate_json("c", "s", {"type": "object"})
    assert "max_tokens" in calls[0]
    assert "max_completion_tokens" not in calls[0]


# --- voice catalog -------------------------------------------------------------


def test_voice_unified_mapping_round_trip(monkeypatch):
    _config(monkeypatch, brain_credited_providers=STAGING_CREDITED)
    assert set(vc.UNIFIED_BRAIN_VENDORS) == {
        "gemini", "meta", *LIVEKIT_BRAIN_VENDORS,
    }
    for vendor, model in EXPECTED_MODELS.items():
        assert vc.cascade_brain_for_unified(vendor) == model
        assert vc.unified_vendor_for_cascade(model) == vendor
        # The agent builds any inference brain id directly.
        assert vc.brain_route(model) == (vc.ROUTE_INFERENCE, model)


def test_voice_mapping_gemma_is_not_gemini(monkeypatch):
    _config(monkeypatch, brain_credited_providers=STAGING_CREDITED)
    # google/gemma-4-31b-it is a google/ id but the GEMMA vendor's model.
    assert vc.unified_vendor_for_cascade("google/gemma-4-31b-it") == "gemma"
    assert vc.unified_vendor_for_cascade("google/gemini-3.8-flash") == "gemini"


def test_voice_uncredited_pick_resolves_to_gemini_brain(monkeypatch):
    _config(monkeypatch, brain_credited_providers=("gemini",))
    assert vc.cascade_brain_for_unified("grok").startswith("google/gemini")
    import schema
    prof = {schema.PF_AYMA_BRAIN_MODEL: "grok"}
    assert vc.resolved_cascade_brain(prof).startswith("google/gemini")


def test_voice_catalog_lists_new_brains_as_available(monkeypatch):
    _config(monkeypatch, brain_credited_providers=STAGING_CREDITED)
    brains = {b["id"]: b for b in vc.catalog()["brains"]}
    for model in EXPECTED_MODELS.values():
        assert model in brains
        assert brains[model]["route"] == vc.ROUTE_INFERENCE
        assert brains[model]["available"] is True
