import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    # The app-wide gate verifies the same token independently (main.py).
    monkeypatch.setattr(
        main._firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
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


# --- B9-PUSH regression: a fresh account (no biometric consent yet) must be
# able to register/remove its own FCM token before onboarding completes. ------


def test_fresh_account_without_consent_can_register_token(monkeypatch):
    """A just-created authenticated user who has NOT recorded biometric consent
    still registers their push token (200). Pre-fix the app-wide consent gate
    returned 403 for every fresh sign-up. The token is scoped to the caller's
    OWN uid — the ops is invoked with the authenticated uid, never another."""
    monkeypatch.setattr(
        main.biometric_consent, "has_consent", lambda _db, _uid: False
    )
    seen = {}
    monkeypatch.setattr(
        main.notifications_ops, "register_token",
        lambda db, uid, tok: seen.update(uid=uid, tok=tok),
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/notifications/token",
        headers=_auth(monkeypatch, uid="fresh-uid"),
        json={"token": "new-device"},
    )
    assert resp.status_code == 200
    assert seen == {"uid": "fresh-uid", "tok": "new-device"}


def test_fresh_account_without_consent_can_remove_token(monkeypatch):
    """Token removal (sign-out / rotation) is likewise usable before consent."""
    monkeypatch.setattr(
        main.biometric_consent, "has_consent", lambda _db, _uid: False
    )
    seen = {}
    monkeypatch.setattr(
        main.notifications_ops, "unregister_token",
        lambda db, uid, tok: seen.update(uid=uid, tok=tok),
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/notifications/token/remove",
        headers=_auth(monkeypatch, uid="fresh-uid"),
        json={"token": "old-device"},
    )
    assert resp.status_code == 200
    assert seen == {"uid": "fresh-uid", "tok": "old-device"}


def test_register_token_still_rejects_unauthenticated():
    """The exemption only skips the consent gate — the route's own auth still
    rejects a caller with no valid Firebase token (401/403, never 200)."""
    assert client.post(
        "/notifications/token", json={"token": "t"}
    ).status_code in (401, 403)
    assert client.post(
        "/notifications/token/remove", json={"token": "t"}
    ).status_code in (401, 403)
