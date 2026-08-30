import gemini
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

from main import app

client = TestClient(app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    return {"Authorization": "Bearer valid"}


def _stub_gemini(monkeypatch, reply="a real-ish reply"):
    async def _fake(_message):
        return reply

    monkeypatch.setattr(gemini, "generate_reply", _fake)


def test_chat_requires_a_token():
    resp = client.post("/chat", json={"message": "hi"})
    assert resp.status_code in (401, 403)


def test_chat_returns_gemini_reply(monkeypatch):
    _stub_gemini(monkeypatch, "hello from the model")
    resp = client.post(
        "/chat", json={"message": "hi ayma"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert resp.json()["reply"] == "hello from the model"


def test_chat_rejects_empty_message(monkeypatch):
    resp = client.post("/chat", json={"message": ""}, headers=_auth(monkeypatch))
    assert resp.status_code == 422


def test_chat_502_when_gemini_fails(monkeypatch):
    async def _boom(_message):
        raise RuntimeError("model exploded")

    monkeypatch.setattr(gemini, "generate_reply", _boom)
    resp = client.post(
        "/chat", json={"message": "hi"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 502
