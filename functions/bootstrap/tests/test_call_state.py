"""Voice-call state on /chat, /chat/stream and /bootstrap (ledger 2cy).

Founder defect 2026-11-07: his voice call ended by 30 s of silence, he
typed "disconnect please" in the chat, and Ayma answered that they were
not on a call — the /chat payload carried no call state, so the text
model had never been told a call existed. The client now attaches
`call_state`; the backend renders it into the prompt
(main._call_state_context) for both the text prompt and the voice seed,
so a disconnect request after an ended call is acknowledged, never
denied.
"""

import gemini
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

from main import app

client = TestClient(app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    return {"Authorization": "Bearer <redacted>"}


def _stub_gemini(monkeypatch, reply="a real-ish reply"):
    async def _fake(_message, **_kw):
        return gemini.Reply(text=reply)

    monkeypatch.setattr(gemini, "generate_reply", _fake)


# --- the renderer -------------------------------------------------------


def test_no_call_state_no_line():
    assert main._call_state_context(None) == ""


def test_in_call_line():
    line = main._call_state_context(main.CallStateModel(in_call=True))
    assert "live voice call" in line
    assert "disconnect" in line


def test_just_ended_idle_timeout_acknowledges():
    line = main._call_state_context(
        main.CallStateModel(
            ended_seconds_ago=42, end_reason="client_idle_timeout"
        )
    )
    assert "ended 42 seconds ago" in line
    assert "30 seconds of silence" in line
    assert "already ended" in line
    assert "never say you were not on a call" in line


def test_just_ended_text_disconnect_reason():
    line = main._call_state_context(
        main.CallStateModel(ended_seconds_ago=3, end_reason="text_disconnect")
    )
    assert "just now" in line
    assert "typing their disconnect request" in line


def test_just_ended_minutes_rendering():
    line = main._call_state_context(
        main.CallStateModel(ended_seconds_ago=600, end_reason="user_stop")
    )
    assert "10 minutes ago" in line
    assert "the user hung up" in line


def test_stale_call_is_not_context():
    assert (
        main._call_state_context(
            main.CallStateModel(ended_seconds_ago=3600, end_reason="user_stop")
        )
        == ""
    )


def test_unknown_reason_falls_back():
    line = main._call_state_context(
        main.CallStateModel(ended_seconds_ago=30, end_reason="something_new")
    )
    assert "ended 30 seconds ago" in line


def test_out_of_range_seconds_are_clamped_not_rejected():
    line = main._call_state_context(
        main.CallStateModel(ended_seconds_ago=-50, end_reason="dropped")
    )
    assert "just now" in line


# --- the request models ---------------------------------------------------


def test_chat_request_parses_call_state():
    req = main.ChatRequest(
        message="disconnect please",
        call_state={
            "in_call": False,
            "ended_seconds_ago": 12,
            "end_reason": "client_idle_timeout",
        },
    )
    assert req.call_state is not None
    assert req.call_state.ended_seconds_ago == 12


def test_chat_request_call_state_defaults_to_none():
    assert main.ChatRequest(message="hi").call_state is None


def test_overlong_end_reason_truncates_instead_of_422():
    req = main.ChatRequest(
        message="hi",
        call_state={"end_reason": "x" * 64},
    )
    assert req.call_state is not None
    assert len(req.call_state.end_reason) == 32


def test_bootstrap_request_parses_call_state():
    req = main.BootstrapRequest(
        call_state={"ended_seconds_ago": 5, "end_reason": "dropped"}
    )
    assert req.call_state is not None
    assert req.call_state.end_reason == "dropped"


# --- the prompt -----------------------------------------------------------


def test_compose_includes_call_state_line():
    composed = main.compose_system_prompt(
        call_state_context="Call state: a voice call with the user ended just now."
    )
    assert "Call state: a voice call with the user ended just now." in composed


def test_compose_default_is_byte_identical_without_call_state():
    assert main.compose_system_prompt() == main.compose_system_prompt(
        call_state_context=""
    )


# --- the endpoint ---------------------------------------------------------


def test_chat_send_with_call_state_is_accepted(monkeypatch):
    _stub_gemini(monkeypatch)
    resp = client.post(
        "/chat",
        json={
            "message": "disconnect please",
            "call_state": {
                "in_call": False,
                "ended_seconds_ago": 65,
                "end_reason": "client_idle_timeout",
            },
        },
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200


def test_chat_send_with_overlong_end_reason_is_accepted(monkeypatch):
    _stub_gemini(monkeypatch)
    resp = client.post(
        "/chat",
        json={
            "message": "hi",
            "call_state": {"end_reason": "x" * 64},
        },
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200


# --- the prompt the model actually receives -------------------------------


def _capturing_gemini(monkeypatch):
    """Stub generate_reply, recording the system prompt it was handed."""
    seen = {}

    async def _fake(_message, **kw):
        seen.update(kw)
        return gemini.Reply(text="a real-ish reply")

    monkeypatch.setattr(gemini, "generate_reply", _fake)
    return seen


def test_chat_prompt_acknowledges_idle_ended_call(monkeypatch):
    """The founder's exact sequence: a call ended by silence, then a
    typed "disconnect please" — the model's prompt must carry the
    ended call and the acknowledgment instruction, never a denial."""
    seen = _capturing_gemini(monkeypatch)
    resp = client.post(
        "/chat",
        json={
            "message": "disconnect please",
            "call_state": {
                "in_call": False,
                "ended_seconds_ago": 42,
                "end_reason": "client_idle_timeout",
            },
        },
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    prompt = seen["system_prompt"]
    assert "ended 42 seconds ago" in prompt
    assert "30 seconds of silence" in prompt
    assert "never say you were not on a call" in prompt


def test_chat_prompt_marks_live_call(monkeypatch):
    seen = _capturing_gemini(monkeypatch)
    resp = client.post(
        "/chat",
        json={"message": "can you hear me?", "call_state": {"in_call": True}},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    assert "live voice call" in seen["system_prompt"]


def test_chat_prompt_without_call_state_has_no_call_line(monkeypatch):
    seen = _capturing_gemini(monkeypatch)
    resp = client.post(
        "/chat", json={"message": "hi ayma"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert "Call state:" not in seen["system_prompt"]


def test_chat_stream_prompt_carries_call_state(monkeypatch):
    """The streaming path shares _prepare_chat — same prompt guarantee."""
    seen = {}

    async def _events(_message, *_a, **kw):
        seen.update(kw)
        yield {"type": "reply", "text": "found it", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    monkeypatch.setattr(
        __import__("main").chat_history,
        "append",
        lambda _db, uid, role, text, **kw: None,
    )
    resp = client.post(
        "/chat/stream",
        json={
            "message": "disconnect please",
            "call_state": {
                "in_call": False,
                "ended_seconds_ago": 42,
                "end_reason": "client_idle_timeout",
            },
        },
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    assert "never say you were not on a call" in seen["system_prompt"]
