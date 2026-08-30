import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def test_usage_requires_auth():
    assert client.get("/usage").status_code in (401, 403)


def test_usage_returns_total_cap_remaining_and_breakdown(monkeypatch):
    monkeypatch.setattr(
        main.token_ledger, "usage",
        lambda uid: {
            "total": 42000,
            "cap": 100000,
            "remaining": 58000,
            "features": {"chat": 30000, "voice": 9000, "matching": 3000},
        },
    )
    resp = client.get("/usage", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 42000 and body["cap"] == 100000
    assert body["remaining"] == 58000
    assert body["features"]["voice"] == 9000
