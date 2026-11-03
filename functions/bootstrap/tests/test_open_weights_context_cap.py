"""Open-weights cascade context cap (founder bug, 2026-11-02).

The open-weights voice brain (Modal-hosted Llama-3.1-8B) serves a HARD context
window (vLLM ``--max-model-len``, 8192). The LiveKit AgentSession sends the
full, growing chat context every turn, so once system prompt + history + the
new turn exceed the window the server returns ``400 maximum context length``
(retryable=False) and the turn fails — the voice sticks on "Listening".

These checks verify the agent-side fix: ``cap_chat_ctx`` trims a long history
to fit a small window (keeping the system prompt + the most-recent turns,
dropping the oldest first), never over-trims a large-context brain, and the
open-weights brain is wired to a context-capped LLM while the Meta brain is not.
"""

import dataclasses

import pytest

pytest.importorskip("livekit.agents")
pytest.importorskip("livekit.plugins.openai")

from livekit.agents import llm  # noqa: E402

import agent  # noqa: E402
import config as config_module  # noqa: E402
import voice_catalog  # noqa: E402


def _ctx(system_chars: int, turn_count: int, turn_chars: int) -> llm.ChatContext:
    """A ChatContext: one system message, then ``turn_count`` alternating
    user/assistant turns labelled by index so we can assert which survived."""
    cc = llm.ChatContext.empty()
    cc.add_message(role="system", content="S" * system_chars)
    for i in range(turn_count):
        role = "user" if i % 2 == 0 else "assistant"
        cc.add_message(role=role, content=f"{i}:" + ("x" * turn_chars))
    return cc


def _est_total(ctx: llm.ChatContext) -> int:
    return sum(agent._est_item_tokens(it) for it in ctx.items)


def test_cap_trims_long_history_under_budget_keeping_system_and_recent():
    ctx = _ctx(system_chars=300, turn_count=30, turn_chars=120)
    budget = 400
    capped = agent.cap_chat_ctx(ctx, budget)

    # Fits under the budget now (it did not before).
    assert _est_total(ctx) > budget
    assert _est_total(capped) <= budget

    items = list(capped.items)
    # System prompt is always kept, and kept first.
    assert items[0].role == "system"
    assert items[0].text_content == "S" * 300
    assert sum(1 for it in items if getattr(it, "role", None) == "system") == 1

    # The OLDEST turns were dropped and the MOST-RECENT turns kept (sliding
    # window): the final turn survives, an early turn does not.
    kept_labels = [
        it.text_content.split(":", 1)[0]
        for it in items
        if getattr(it, "role", None) != "system"
    ]
    assert "29" in kept_labels  # newest turn survives
    assert "0" not in kept_labels  # oldest turn dropped
    # Kept turns are a contiguous recent suffix (ascending, ending at the newest).
    nums = [int(x) for x in kept_labels]
    assert nums == sorted(nums)
    assert nums[-1] == 29


def test_cap_keeps_system_even_when_it_alone_exceeds_budget():
    ctx = _ctx(system_chars=6000, turn_count=4, turn_chars=100)
    capped = agent.cap_chat_ctx(ctx, token_budget=500)
    items = list(capped.items)
    assert len(items) == 1
    assert items[0].role == "system"  # never dropped


def test_large_context_brain_is_not_over_trimmed():
    # A large budget (a large-context brain, e.g. Gemini) leaves the context
    # untouched — same object returned, nothing dropped.
    ctx = _ctx(system_chars=300, turn_count=30, turn_chars=120)
    out = agent.cap_chat_ctx(ctx, token_budget=1_000_000)
    assert out is ctx


def test_capped_llm_trims_the_sent_context_on_chat(monkeypatch):
    captured = {}

    def _fake_super_chat(self, *, chat_ctx, **kwargs):
        captured["chat_ctx"] = chat_ctx
        return "stream"

    from livekit.plugins import openai as lk_openai

    monkeypatch.setattr(lk_openai.LLM, "chat", _fake_super_chat)

    budget = 400
    brain = agent._build_context_capped_open_weights_llm(
        model="m", base_url="http://x/v1", api_key="k", token_budget=budget
    )
    long_ctx = _ctx(system_chars=300, turn_count=30, turn_chars=120)
    brain.chat(chat_ctx=long_ctx, tools=None)

    sent = captured["chat_ctx"]
    assert _est_total(sent) <= budget
    assert _est_total(long_ctx) > budget  # it really was too big
    assert list(sent.items)[0].role == "system"


def _configured_cfg(monkeypatch, **env):
    for key, val in env.items():
        monkeypatch.setenv(key, val)
    cfg = config_module._load()
    monkeypatch.setattr(agent, "CONFIG", cfg)
    monkeypatch.setattr(voice_catalog, "CONFIG", cfg)
    voice_catalog.clear_cache()
    return cfg


def test_open_weights_brain_is_context_capped_meta_brain_is_not(monkeypatch):
    cfg = _configured_cfg(
        monkeypatch,
        OPEN_WEIGHTS_BASE_URL="http://modal.example/v1",
        OPEN_WEIGHTS_MODEL="meta-models/muse-spark-open-1026",
        OPEN_WEIGHTS_MAX_CONTEXT_TOKENS="8192",
        OPEN_WEIGHTS_RESPONSE_TOKEN_MARGIN="1200",
        META_API_KEY="test-key",
    )

    ow = agent._build_cascade_brain(voice_catalog.BRAIN_OPEN_WEIGHTS)
    # Context-capped: budget is window minus the reply margin.
    assert hasattr(ow, "_ctx_token_budget")
    assert ow._ctx_token_budget == (
        cfg.open_weights_max_context_tokens - cfg.open_weights_response_token_margin
    )
    assert ow._ctx_token_budget == 6992

    meta = agent._build_cascade_brain(voice_catalog.BRAIN_META)
    # The large-context Meta brain is a plain LLM — never context-capped.
    assert not hasattr(meta, "_ctx_token_budget")
    assert type(meta).__name__ != type(ow).__name__
