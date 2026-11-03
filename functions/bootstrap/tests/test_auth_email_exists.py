"""POST /auth/email-exists — the sign-in screen's existence oracle.

Under Firebase's email-enumeration protection the client sees
``invalid-credential`` for BOTH "email exists, wrong password" and "email does
not exist" (verified against staging: identical INVALID_LOGIN_CREDENTIALS for
test1@gmail.com+wrong-password and a guaranteed-nonexistent address, and
createAuthUri returns no signinMethods for either). Only the Admin SDK can
tell them apart, so the client asks here before deciding whether a failed
sign-in stays (wrong password) or flips to sign-up (unknown email).
"""

import main
import ratelimit
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _user(email):
    class _U:
        pass

    u = _U()
    u.email = email
    u.uid = "uid-1"
    return u


def test_existing_email_returns_true_and_nothing_else(monkeypatch):
    seen = []
    def _get(email):
        seen.append(email)
        return _user(email)
    monkeypatch.setattr(firebase_auth, "get_user_by_email", _get)

    r = client.post("/auth/email-exists", json={"email": "Test1@Gmail.com "})

    assert r.status_code == 200
    assert r.json() == {"exists": True}
    # Normalised before lookup; the response carries no uid or profile data.
    assert seen == ["test1@gmail.com"]


def test_unknown_email_returns_false(monkeypatch):
    def _raise(email):
        raise firebase_auth.UserNotFoundError("No user record.")
    monkeypatch.setattr(firebase_auth, "get_user_by_email", _raise)

    r = client.post("/auth/email-exists", json={"email": "nobody@example.com"})

    assert r.status_code == 200
    assert r.json() == {"exists": False}


def test_malformed_email_is_rejected():
    r = client.post("/auth/email-exists", json={"email": "not-an-email"})
    assert r.status_code == 400


def test_transient_admin_failure_is_a_503_not_a_guess(monkeypatch):
    def _boom(email):
        raise RuntimeError("admin backend down")
    monkeypatch.setattr(firebase_auth, "get_user_by_email", _boom)

    r = client.post("/auth/email-exists", json={"email": "a@b.com"})

    # The client stays on sign-in with a generic error on non-200 — never a
    # fabricated exists/not-exists answer.
    assert r.status_code == 503


def test_route_is_tightened_against_bulk_harvesting():
    assert ratelimit.rate_for("/auth/email-exists") == "20/minute"
