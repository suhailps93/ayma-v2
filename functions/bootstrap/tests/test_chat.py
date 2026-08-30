from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

from main import app

client = TestClient(app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    return {"Authorization": "Bearer valid"}


def test_chat_requires_a_token():
    resp = client.post("/chat", json={"message": "hi"})
    assert resp.status_code in (401, 403)


def test_chat_echoes_the_message(monkeypatch):
    resp = client.post(
        "/chat", json={"message": "  hello ayma  "}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert resp.json()["reply"] == '(stub reply) You said: "hello ayma"'


def test_chat_rejects_empty_message(monkeypatch):
    resp = client.post(
        "/chat", json={"message": ""}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 422
