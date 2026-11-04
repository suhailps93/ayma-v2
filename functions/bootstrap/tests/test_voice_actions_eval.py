"""Live eval for the voice-actions skill: every fixture in
``fixtures/voice_actions_eval.json`` runs against the REAL model path
(``skills.voice_actions.interpret_voice_action`` → LiveKit Inference) — not
a stub.

Runs ONLY when explicitly opted in (it spends real LiveKit credits and needs
network + credentials)::

    set -a; source /path/to/.env.local; set +a   # LIVEKIT_API_KEY/SECRET
    VOICE_ACTIONS_EVAL_LIVE=1 .venv-agent/bin/python -m pytest \\
        tests/test_voice_actions_eval.py -q

Without ``VOICE_ACTIONS_EVAL_LIVE=1`` (or without LiveKit credentials) every
case skips, so the standard unit suites stay hermetic and green. ``uid`` is
left unset so the eval writes nothing to any ledger.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path

import pytest

from skills import voice_actions
from skills.voice_actions import CallContext

_FIXTURES = json.loads(
    (Path(__file__).parent / "fixtures" / "voice_actions_eval.json")
    .read_text(encoding="utf-8")
)["cases"]

_LIVE = os.getenv("VOICE_ACTIONS_EVAL_LIVE") == "1"
_CREDS = bool(os.getenv("LIVEKIT_API_KEY") and os.getenv("LIVEKIT_API_SECRET"))

requires_live = pytest.mark.skipif(
    not (_LIVE and _CREDS),
    reason="live eval: set VOICE_ACTIONS_EVAL_LIVE=1 with LiveKit creds",
)


def _norm(text: str) -> str:
    return " ".join(str(text or "").strip().lower().split())


def _check(case: dict, verdict: voice_actions.Verdict) -> None:
    """Assert a live verdict matches the fixture's expected intent (names
    compared case-insensitively — the executor's own resolver is too)."""
    expected = case["expected"]
    assert verdict.action == expected["action"], (
        f"{case['id']}: action {verdict.action!r} != {expected['action']!r} "
        f"for {case['transcript']!r} (full verdict: {verdict})"
    )
    for key in ("page", "member", "partner", "tool"):
        if key in expected:
            assert _norm(getattr(verdict, key)) == _norm(expected[key]), (
                f"{case['id']}: {key} {getattr(verdict, key)!r} != "
                f"{expected[key]!r} (full verdict: {verdict})"
            )
    if "value" in expected:
        command = voice_actions.verdict_to_command(verdict)
        assert command is not None, f"{case['id']}: no command: {verdict}"
        _name, kwargs = command
        (value,) = kwargs.values()
        assert _norm(value) == _norm(expected["value"]), (
            f"{case['id']}: value {value!r} != {expected['value']!r}"
        )
    if "value_contains" in expected:
        command = voice_actions.verdict_to_command(verdict)
        assert command is not None, f"{case['id']}: no command: {verdict}"
        _name, kwargs = command
        (value,) = kwargs.values()
        assert _norm(expected["value_contains"]) in _norm(value), (
            f"{case['id']}: value {value!r} lacks "
            f"{expected['value_contains']!r}"
        )
    if "for" in expected:
        assert _norm(verdict.clarify_for) == _norm(expected["for"]), (
            f"{case['id']}: clarify_for {verdict.clarify_for!r} != "
            f"{expected['for']!r}"
        )
    for key, want in (case.get("voice") or {}).items():
        assert _norm(want) in _norm(getattr(verdict, key)), (
            f"{case['id']}: voice {key} {getattr(verdict, key)!r} lacks "
            f"{want!r}"
        )


@requires_live
@pytest.mark.parametrize("case", _FIXTURES, ids=[c["id"] for c in _FIXTURES])
def test_live_fixture_matches_its_expected_intent(case):
    context = CallContext(
        member=case.get("member") or "",
        page=case.get("page") or "",
        turns=tuple(
            (role, text) for role, text in (case.get("turns") or [])
        ),
    )
    verdict = asyncio.run(
        voice_actions.interpret_voice_action(case["transcript"], context)
    )
    _check(case, verdict)


def test_fixture_set_covers_the_six_founder_verbatims():
    by_id = {c["id"]: c for c in _FIXTURES}
    assert by_id["founder-1-explore"]["expected"] == {
        "action": "navigate", "page": "explore",
    }
    assert by_id["founder-2-models"]["expected"] == {
        "action": "navigate", "page": "voice_preference",
    }
    assert by_id["founder-3-sim-her"]["expected"] == {
        "action": "launch_sim", "partner": "Dillu",
    }
    assert by_id["founder-4-agent-her"]["expected"] == {
        "action": "launch_sim", "partner": "Dillu",
    }
    assert by_id["founder-5-practice-her"]["expected"] == {
        "action": "launch_practice", "partner": "Dillu",
    }
    assert by_id["founder-6-goodbye"]["expected"] == {"action": "end_call"}
    for fid in (
        "founder-3-sim-her", "founder-4-agent-her", "founder-5-practice-her",
    ):
        assert by_id[fid]["member"] == "Dillu", fid
