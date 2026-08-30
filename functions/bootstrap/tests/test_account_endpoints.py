import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "u-9"}
    )
    return {"Authorization": "Bearer valid"}


def test_delete_requires_a_token():
    assert client.post("/account/delete").status_code in (401, 403)


def test_delete_soft_deletes(monkeypatch):
    seen = {}

    def _fake(db, bucket, uid):
        seen["uid"] = uid
        return {"deleted": True, "files_moved": 2}

    monkeypatch.setattr(main.account_ops, "soft_delete", _fake)
    monkeypatch.setattr(main, "_bucket", lambda: object())

    resp = client.post("/account/delete", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json() == {"ok": True, "deleted": True, "files_moved": 2}
    assert seen["uid"] == "u-9"


def test_recover_409_when_nothing_to_recover(monkeypatch):
    monkeypatch.setattr(main, "_recovery_required", lambda _uid: False)
    resp = client.post("/account/recover", headers=_auth(monkeypatch))
    assert resp.status_code == 409


def test_recover_restores(monkeypatch):
    monkeypatch.setattr(main, "_recovery_required", lambda _uid: True)
    monkeypatch.setattr(
        main.account_ops,
        "recover",
        lambda db, bucket, uid: {"restored": True, "files_moved": 1},
    )
    monkeypatch.setattr(main, "_bucket", lambda: object())

    resp = client.post("/account/recover", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json() == {"ok": True, "restored": True, "files_moved": 1}


def test_bootstrap_returns_recovery_required(monkeypatch):
    monkeypatch.setattr(main, "_recovery_required", lambda _uid: True)
    resp = client.post("/bootstrap", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json() == {"recovery_required": True, "uid": "u-9"}


def test_require_admin_dependency(monkeypatch):
    import auth
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "a1", "admin": True},
    )
    import asyncio
    from fastapi.security import HTTPAuthorizationCredentials
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="x")
    assert asyncio.new_event_loop().run_until_complete(
        auth.require_admin(creds)
    ) == "a1"

    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "u2"}
    )
    import pytest
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as ei:
        asyncio.new_event_loop().run_until_complete(auth.require_admin(creds))
    assert ei.value.status_code == 403
