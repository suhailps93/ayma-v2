"""Context-carried fields must never reject a /chat send with a 422.

Regression for 2026-11-07: a 4,642-char self-check summary bubble in the
chat history made every later send bounce (TurnModel.text cap 4,000),
because the client attaches recent_turns + screen context to every send.
Context fields now truncate to their caps; the users own `message` stays
strict.
"""

import gemini
import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth
from pydantic import ValidationError

import main
from main import app

client = TestClient(app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    return {"Authorization": "Bearer test-token"}


def _stub_gemini(monkeypatch, reply="a real-ish reply"):
    async def _fake(_message, **_kw):
        return gemini.Reply(text=reply)

    monkeypatch.setattr(gemini, "generate_reply", _fake)


def test_turn_model_truncates_overlong_text():
    turn = main.TurnModel(role="ayma", text="x" * 4500)
    assert len(turn.text) == 4000


def test_chat_request_truncates_context_fields():
    req = main.ChatRequest(
        message="hi",
        recent_turns=[{"role": "ayma", "text": "x" * 4642}],
        screen_visible="v" * 3201,
        screen_detail="d" * 2000,
        screen_note="n" * 900,
        story_passage="p" * 9000,
        deep_dive_target="t" * 3000,
    )
    assert len(req.recent_turns[0].text) == 4000
    assert len(req.screen_visible) == 3200
    assert len(req.screen_detail) == 1500
    assert len(req.screen_note) == 500
    assert len(req.story_passage) == 8000
    assert len(req.deep_dive_target) == 2200


def test_chat_request_normal_send_is_unchanged():
    req = main.ChatRequest(
        message="hello",
        recent_turns=[{"role": "user", "text": "earlier"}],
        screen_visible="some visible text",
    )
    assert req.message == "hello"
    assert req.recent_turns[0].text == "earlier"
    assert req.screen_visible == "some visible text"


def test_chat_request_message_stays_strict():
    with pytest.raises(ValidationError):
        main.ChatRequest(message="x" * 4001)


def test_chat_send_with_overlong_history_bubble_is_accepted(monkeypatch):
    _stub_gemini(monkeypatch, "reply after the long bubble")
    resp = client.post(
        "/chat",
        json={
            "message": "are you there?",
            "recent_turns": [{"role": "ayma", "text": "x" * 4642}],
        },
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    assert resp.json()["reply"] == "reply after the long bubble"


def test_chat_send_with_overlong_screen_visible_is_accepted(monkeypatch):
    _stub_gemini(monkeypatch)
    resp = client.post(
        "/chat",
        json={"message": "hi", "screen_visible": "v" * 3201},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
