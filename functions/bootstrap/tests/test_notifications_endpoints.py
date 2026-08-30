import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def test_register_token_requires_auth():
    assert client.post("/notifications/token", json={"token": "t"}).status_code \
        in (401, 403)


def test_register_token_calls_ops(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        main.notifications_ops, "register_token",
        lambda db, uid, tok: seen.update(uid=uid, tok=tok),
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/notifications/token",
        headers=_auth(monkeypatch, uid="u1"),
        json={"token": "device-xyz"},
    )
    assert resp.status_code == 200
    assert seen == {"uid": "u1", "tok": "device-xyz"}


def test_register_token_maps_valueerror_to_400(monkeypatch):
    def _boom(db, uid, tok):
        raise ValueError("empty FCM token")

    monkeypatch.setattr(main.notifications_ops, "register_token", _boom)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/notifications/token",
        headers=_auth(monkeypatch),
        json={"token": "x"},
    )
    assert resp.status_code == 400


def test_remove_token_calls_ops(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        main.notifications_ops, "unregister_token",
        lambda db, uid, tok: seen.update(uid=uid, tok=tok),
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/notifications/token/remove",
        headers=_auth(monkeypatch, uid="u2"),
        json={"token": "gone"},
    )
    assert resp.status_code == 200
    assert seen == {"uid": "u2", "tok": "gone"}
