"""OpenAI voice path in agent.py (docs/chatgpt-provider.md).

Offline checks only: model selection, the fallback to Gemini, and ledger
routing for OpenAI Realtime turns. The live Realtime round trip is unverified
(no client id / plan-token eligibility yet).
"""

import asyncio
import json
import sys
import types as _types

import pytest

pytest.importorskip("livekit.agents")
pytest.importorskip("livekit.plugins.google.realtime")

import agent  # noqa: E402
import llm_provider  # noqa: E402
import token_ledger  # noqa: E402
from config import CONFIG  # noqa: E402


def _install_fake_openai_realtime(monkeypatch, captured):
    class _OpenAIRealtime:
        def __init__(self, **kwargs):
            captured.update(kwargs)

    mod = _types.ModuleType("livekit.plugins.openai.realtime")
    mod.RealtimeModel = _OpenAIRealtime
    monkeypatch.setitem(sys.modules, "livekit.plugins.openai.realtime", mod)


def _seed(provider):
    return agent.RoomSeed(system_prompt="p", uid="u1", llm_provider=provider)


def _fake_metrics(*, total=150, input_tokens=100, output_tokens=50):
    from livekit.agents.metrics import RealtimeModelMetrics

    return RealtimeModelMetrics(
        request_id="r1",
        timestamp=0.0,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        total_tokens=total,
        input_token_details=RealtimeModelMetrics.InputTokenDetails(
            cached_tokens=40
        ),
        output_token_details=RealtimeModelMetrics.OutputTokenDetails(),
    )


class _FakeMetricsSession:
    def __init__(self):
        self._handlers = {}

    def on(self, name):
        def _register(fn):
            self._handlers[name] = fn
            return fn

        return _register

    def fire(self, metrics):
        ev = _types.SimpleNamespace(metrics=metrics)
        self._handlers["metrics_collected"](ev)


def test_read_room_seed_defaults_to_gemini_and_reads_the_hint():
    plain = _types.SimpleNamespace(
        room=_types.SimpleNamespace(
            metadata=json.dumps({"uid": "u1", "system_prompt": "x"})
        )
    )
    assert agent._read_room_seed(plain).llm_provider == "gemini"

    hinted = _types.SimpleNamespace(
        room=_types.SimpleNamespace(
            metadata=json.dumps(
                {"uid": "u1", "system_prompt": "x", "llm_provider": "openai"}
            )
        )
    )
    assert agent._read_room_seed(hinted).llm_provider == "openai"


def test_openai_realtime_model_uses_config_values(monkeypatch):
    captured = {}
    _install_fake_openai_realtime(monkeypatch, captured)
    agent.build_openai_realtime_model("tok")
    assert captured == {
        "model": CONFIG.openai_realtime_model,
        "voice": CONFIG.openai_realtime_voice,
        "api_key": "tok",
        "base_url": CONFIG.openai_base_url,
    }


def test_select_voice_model_stays_on_gemini_by_default(monkeypatch):
    sentinel = object()
    monkeypatch.setattr(agent, "build_realtime_model", lambda *a: sentinel)
    monkeypatch.setattr(llm_provider, "route_for", lambda uid: None)
    model, route = asyncio.run(agent._select_voice_model(_seed("gemini")))
    assert model is sentinel and route is None


def test_select_voice_model_needs_both_the_seed_hint_and_a_live_route(
    monkeypatch,
):
    sentinel = object()
    monkeypatch.setattr(agent, "build_realtime_model", lambda *a: sentinel)
    # Hint says openai but the live routing check disagrees -> Gemini.
    monkeypatch.setattr(llm_provider, "route_for", lambda uid: None)
    model, route = asyncio.run(agent._select_voice_model(_seed("openai")))
    assert model is sentinel and route is None
    # Live route says openai but the seed hint doesn't -> Gemini.
    r = llm_provider.Route(uid="u1", billing="plan")
    monkeypatch.setattr(llm_provider, "route_for", lambda uid: r)
    model, route = asyncio.run(agent._select_voice_model(_seed("gemini")))
    assert model is sentinel and route is None


def test_select_voice_model_openai_happy_path(monkeypatch):
    captured = {}
    _install_fake_openai_realtime(monkeypatch, captured)
    r = llm_provider.Route(uid="u1", billing="plan")
    monkeypatch.setattr(llm_provider, "route_for", lambda uid: r)

    async def _tok(route, **kw):
        return "plan-bearer"

    monkeypatch.setattr(llm_provider, "access_token", _tok)
    model, route = asyncio.run(agent._select_voice_model(_seed("openai")))
    assert route is r
    assert captured["api_key"] == "plan-bearer"


def test_select_voice_model_falls_back_to_gemini_when_the_token_fails(
    monkeypatch,
):
    sentinel = object()
    monkeypatch.setattr(agent, "build_realtime_model", lambda *a: sentinel)
    r = llm_provider.Route(uid="u1", billing="plan")
    monkeypatch.setattr(llm_provider, "route_for", lambda uid: r)

    async def _boom(route, **kw):
        raise RuntimeError("refresh rejected")

    monkeypatch.setattr(llm_provider, "access_token", _boom)
    model, route = asyncio.run(agent._select_voice_model(_seed("openai")))
    assert model is sentinel and route is None


def test_openai_plan_turns_use_record_openai_and_skip_the_credit_check(
    monkeypatch,
):
    recorded = []
    monkeypatch.setattr(
        token_ledger,
        "record_openai",
        lambda uid, feature, usage, **kw: recorded.append(
            (uid, feature, usage, kw)
        ),
    )
    monkeypatch.setattr(
        token_ledger,
        "add",
        lambda *a, **k: pytest.fail("Gemini add() must not run"),
    )
    checks = []
    monkeypatch.setattr(
        token_ledger, "check", lambda uid, **kw: checks.append((uid, kw))
    )

    route = llm_provider.Route(uid="u1", billing=token_ledger.BILLING_PLAN)
    session = _FakeMetricsSession()
    calls = []

    async def _on_exhausted():
        calls.append(True)

    agent.relay_token_usage(
        session,
        "u1",
        session_id="room-9",
        on_credits_exhausted=_on_exhausted,
        route=route,
    )

    async def _run():
        session.fire(_fake_metrics())
        await asyncio.sleep(0.01)

    asyncio.run(_run())

    assert len(recorded) == 1
    uid, feature, usage, kw = recorded[0]
    assert (uid, feature) == ("u1", token_ledger.FEATURE_VOICE)
    assert usage["input_tokens"] == 100 and usage["output_tokens"] == 50
    assert usage["input_token_details"] == {"cached_tokens": 40}
    assert kw == {
        "model": CONFIG.openai_realtime_model,
        "billing": token_ledger.BILLING_PLAN,
        "session_id": "room-9",
    }
    assert checks == [("u1", {"billing": token_ledger.BILLING_PLAN})]
    assert calls == []
