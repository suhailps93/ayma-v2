"""dm_moderation: never blocks, fails open (launch-readiness audit Task 1)."""

import asyncio

import dm_moderation
import gemini


def test_allowed_text_returns_unflagged(monkeypatch):
    async def _fake(*_a, **_kw):
        return {"flagged": False, "reason": "", "categories": []}

    monkeypatch.setattr(gemini, "generate_json", _fake)
    verdict = asyncio.run(dm_moderation.moderate("hey, how's your day going?"))
    assert verdict == {"flagged": False, "reason": "", "categories": []}


def test_flagged_text_returns_flagged_verdict(monkeypatch):
    async def _fake(*_a, **_kw):
        return {
            "flagged": True,
            "reason": "harassment",
            "categories": ["harassment"],
        }

    monkeypatch.setattr(gemini, "generate_json", _fake)
    verdict = asyncio.run(dm_moderation.moderate("nasty message"))
    assert verdict["flagged"] is True
    assert verdict["reason"] == "harassment"
    assert verdict["categories"] == ["harassment"]


def test_model_error_fails_open(monkeypatch):
    async def _boom(*_a, **_kw):
        raise RuntimeError("gemini timeout")

    monkeypatch.setattr(gemini, "generate_json", _boom)
    verdict = asyncio.run(dm_moderation.moderate("anything"))
    assert verdict == {"flagged": False, "reason": "", "categories": []}


def test_unparseable_result_fails_open(monkeypatch):
    async def _weird(*_a, **_kw):
        return ["not", "a", "dict"]

    monkeypatch.setattr(gemini, "generate_json", _weird)
    verdict = asyncio.run(dm_moderation.moderate("anything"))
    assert verdict == {"flagged": False, "reason": "", "categories": []}


def test_moderation_never_enforces_credit_cap(monkeypatch):
    """The sender's credit balance must never be able to block a DM send."""
    seen_kwargs = {}

    async def _fake(contents, **kwargs):
        seen_kwargs.update(kwargs)
        return {"flagged": False, "reason": "", "categories": []}

    monkeypatch.setattr(gemini, "generate_json", _fake)
    asyncio.run(dm_moderation.moderate("hello"))
    assert seen_kwargs.get("enforce_cap") is False


def test_empty_text_short_circuits_without_a_model_call(monkeypatch):
    def _should_not_be_called(*_a, **_kw):
        raise AssertionError("moderate() should not call the model on blank text")

    monkeypatch.setattr(gemini, "generate_json", _should_not_be_called)
    verdict = asyncio.run(dm_moderation.moderate("   "))
    assert verdict == {"flagged": False, "reason": "", "categories": []}
