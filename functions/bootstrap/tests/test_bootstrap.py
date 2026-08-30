from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

from main import app

client = TestClient(app)


def test_bootstrap_requires_a_token():
    resp = client.post("/bootstrap")
    assert resp.status_code in (401, 403)  # missing Bearer credentials


def test_bootstrap_rejects_a_bad_token(monkeypatch):
    def _raise(_token):
        raise firebase_auth.InvalidIdTokenError("bad token")

    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)
    resp = client.post("/bootstrap", headers={"Authorization": "Bearer nope"})
    assert resp.status_code == 401


def test_bootstrap_returns_session_mode_for_a_valid_token(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _token: {"uid": "test-uid-123"}
    )
    resp = client.post("/bootstrap", headers={"Authorization": "Bearer valid"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["session_mode"] in ("marketing", "interview", "active")
    assert body["uid"] == "test-uid-123"
