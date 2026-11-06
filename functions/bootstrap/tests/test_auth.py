"""Tests for auth.py — Firebase ID-token verification and FastAPI dependencies.

Every endpoint in the app depends on one of these auth functions to verify the
caller's Firebase ID token and extract session information. This module tests:
- Token verification and error handling (expired, invalid, revoked, etc.)
- Each dependency function (require_uid, require_caller, require_admin, etc.)
- Permission gates (dev-view, admin, cron, webhook)
- Edge cases (missing headers, malformed tokens, bad secrets)
"""

import asyncio
import dataclasses
import pytest
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials
from firebase_admin import auth as firebase_auth

import auth
from config import CONFIG


# --- Token Verification Tests -----------------------------------------------


def test_verify_token_returns_decoded_claims_on_success(monkeypatch):
    """_verify successfully decodes a valid Firebase ID token."""
    decoded = {"uid": "test-uid-123", "email": "test@example.com"}
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: decoded)

    result = auth._verify("valid-token")

    assert result == decoded


def test_verify_token_raises_401_on_invalid_id_token(monkeypatch):
    """_verify raises HTTPException 401 when Firebase reports an invalid token."""
    def _raise(_token):
        raise firebase_auth.InvalidIdTokenError("malformed")
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)

    with pytest.raises(HTTPException) as exc_info:
        auth._verify("bad-token")

    assert exc_info.value.status_code == 401
    assert "Invalid ID token" in exc_info.value.detail


def test_verify_token_raises_401_on_expired_token(monkeypatch):
    """_verify raises HTTPException 401 when the token has expired."""
    def _raise(_token):
        raise firebase_auth.ExpiredIdTokenError("expired", cause=Exception("expired"))
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)

    with pytest.raises(HTTPException) as exc_info:
        auth._verify("expired-token")

    assert exc_info.value.status_code == 401
    assert "Invalid ID token" in exc_info.value.detail


def test_verify_token_raises_401_on_revoked_token(monkeypatch):
    """_verify raises HTTPException 401 when the token has been revoked."""
    def _raise(_token):
        raise firebase_auth.RevokedIdTokenError("revoked")
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)

    with pytest.raises(HTTPException) as exc_info:
        auth._verify("revoked-token")

    assert exc_info.value.status_code == 401
    assert "Invalid ID token" in exc_info.value.detail


def test_verify_token_raises_401_on_certificate_fetch_error(monkeypatch):
    """_verify raises HTTPException 401 when Firebase certificates cannot be fetched."""
    def _raise(_token):
        raise firebase_auth.CertificateFetchError("certificates unavailable", cause=Exception("fetch error"))
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)

    with pytest.raises(HTTPException) as exc_info:
        auth._verify("cert-error-token")

    assert exc_info.value.status_code == 401
    assert "Invalid ID token" in exc_info.value.detail


def test_verify_token_raises_401_on_value_error(monkeypatch):
    """_verify raises HTTPException 401 on ValueError (caught as misconfiguration)."""
    def _raise(_token):
        raise ValueError("malformed JWT")
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)

    with pytest.raises(HTTPException) as exc_info:
        auth._verify("bad-jwt-token")

    assert exc_info.value.status_code == 401
    assert "Invalid ID token" in exc_info.value.detail


# --- Caller Dataclass Tests -------------------------------------------------


def test_caller_dataclass_is_frozen():
    """Caller is immutable to prevent accidental modifications."""
    caller = auth.Caller(
        uid="test-uid",
        is_anonymous=False,
        sign_in_provider="google.com"
    )
    with pytest.raises(AttributeError):
        caller.uid = "different-uid"


def test_caller_equality_and_hashing():
    """Caller instances are comparable and hashable."""
    caller1 = auth.Caller(uid="uid1", is_anonymous=False, sign_in_provider="google.com")
    caller2 = auth.Caller(uid="uid1", is_anonymous=False, sign_in_provider="google.com")
    caller3 = auth.Caller(uid="uid2", is_anonymous=False, sign_in_provider="google.com")

    assert caller1 == caller2
    assert caller1 != caller3
    assert len({caller1, caller2}) == 1  # hashable


# --- require_uid Dependency Tests -------------------------------------------


def test_require_uid_extracts_uid_from_valid_token(monkeypatch):
    """require_uid extracts and returns the uid from a valid token."""
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "test-uid-456", "email": "test@example.com"}
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    loop = asyncio.new_event_loop()
    result = loop.run_until_complete(auth.require_uid(creds))

    assert result == "test-uid-456"


def test_require_uid_raises_401_on_invalid_token(monkeypatch):
    """require_uid raises 401 when the token is invalid."""
    def _raise(_token):
        raise firebase_auth.InvalidIdTokenError("invalid")
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="bad-token")

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_uid(creds))

    assert exc_info.value.status_code == 401


# --- require_caller Dependency Tests ----------------------------------------


def test_require_caller_returns_caller_with_uid_and_auth_state(monkeypatch):
    """require_caller extracts uid, anonymous status, and sign-in provider."""
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {
            "uid": "user-123",
            "firebase": {"sign_in_provider": "google.com"}
        }
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    loop = asyncio.new_event_loop()
    result = loop.run_until_complete(auth.require_caller(creds))

    assert result.uid == "user-123"
    assert result.is_anonymous is False
    assert result.sign_in_provider == "google.com"


def test_require_caller_detects_anonymous_provider(monkeypatch):
    """require_caller detects when the sign-in provider is 'anonymous'."""
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {
            "uid": "anon-user-456",
            "firebase": {"sign_in_provider": "anonymous"}
        }
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    loop = asyncio.new_event_loop()
    result = loop.run_until_complete(auth.require_caller(creds))

    assert result.uid == "anon-user-456"
    assert result.is_anonymous is True
    assert result.sign_in_provider == "anonymous"


def test_require_caller_handles_missing_firebase_claim(monkeypatch):
    """require_caller gracefully handles missing firebase claim."""
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "user-no-firebase"}
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    loop = asyncio.new_event_loop()
    result = loop.run_until_complete(auth.require_caller(creds))

    assert result.uid == "user-no-firebase"
    assert result.is_anonymous is False
    assert result.sign_in_provider == ""


def test_require_caller_handles_missing_sign_in_provider(monkeypatch):
    """require_caller handles missing sign_in_provider in firebase claim."""
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "user-456", "firebase": {}}
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    loop = asyncio.new_event_loop()
    result = loop.run_until_complete(auth.require_caller(creds))

    assert result.uid == "user-456"
    assert result.is_anonymous is False
    assert result.sign_in_provider == ""


def test_require_caller_raises_401_on_invalid_token(monkeypatch):
    """require_caller raises 401 when the token is invalid."""
    def _raise(_token):
        raise firebase_auth.ExpiredIdTokenError("expired", cause=Exception("expired"))
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="expired-token")

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_caller(creds))

    assert exc_info.value.status_code == 401


# --- is_dev_token Tests -----------------------------------------------------


def test_is_dev_token_returns_true_for_dev_uid(monkeypatch):
    """is_dev_token returns True when uid is in dev_view_uids."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_uids=["dev-uid-1", "dev-uid-2"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    decoded = {"uid": "dev-uid-1"}

    assert auth.is_dev_token(decoded) is True


def test_is_dev_token_returns_false_for_non_dev_uid(monkeypatch):
    """is_dev_token returns False when uid is not in dev_view_uids."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_uids=["dev-uid-1"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    decoded = {"uid": "regular-uid"}

    assert auth.is_dev_token(decoded) is False


def test_is_dev_token_checks_verified_email_address(monkeypatch):
    """is_dev_token returns True when email is in dev_view_emails and verified."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_emails=["dev@example.com"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    decoded = {
        "uid": "user-123",
        "email": "dev@example.com",
        "email_verified": True
    }

    assert auth.is_dev_token(decoded) is True


def test_is_dev_token_ignores_unverified_email(monkeypatch):
    """is_dev_token returns False when email is not verified."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_emails=["dev@example.com"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    decoded = {
        "uid": "user-123",
        "email": "dev@example.com",
        "email_verified": False
    }

    assert auth.is_dev_token(decoded) is False


def test_is_dev_token_email_normalization(monkeypatch):
    """is_dev_token normalizes email to lowercase for comparison."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_emails=["dev@example.com"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    decoded = {
        "uid": "user-123",
        "email": "DEV@EXAMPLE.COM",
        "email_verified": True
    }

    assert auth.is_dev_token(decoded) is True


def test_is_dev_token_ignores_whitespace_in_email(monkeypatch):
    """is_dev_token strips whitespace from email."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_emails=["dev@example.com"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    decoded = {
        "uid": "user-123",
        "email": "  dev@example.com  ",
        "email_verified": True
    }

    assert auth.is_dev_token(decoded) is True


def test_is_dev_token_returns_false_for_none_email(monkeypatch):
    """is_dev_token handles None email gracefully."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_emails=["dev@example.com"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    decoded = {
        "uid": "user-123",
        "email": None,
        "email_verified": True
    }

    assert auth.is_dev_token(decoded) is False


def test_is_dev_token_returns_false_for_missing_email(monkeypatch):
    """is_dev_token handles missing email field gracefully."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_emails=["dev@example.com"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    decoded = {"uid": "user-123"}

    assert auth.is_dev_token(decoded) is False


def test_is_dev_token_uid_check_short_circuits_email_check(monkeypatch):
    """is_dev_token returns True early when uid matches (no email check)."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_uids=["dev-uid-1"], dev_view_emails=[])
    monkeypatch.setattr(auth, "CONFIG", patched)
    decoded = {
        "uid": "dev-uid-1",
        "email": None,  # Missing — would fail email check
        "email_verified": False
    }

    assert auth.is_dev_token(decoded) is True


# --- require_uid_and_dev_flag Dependency Tests ------------------------------


def test_require_uid_and_dev_flag_returns_uid_and_true_for_dev(monkeypatch):
    """require_uid_and_dev_flag returns (uid, True) when user is on dev list."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_uids=["dev-uid-1"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "dev-uid-1"}
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    loop = asyncio.new_event_loop()
    uid, is_dev = loop.run_until_complete(auth.require_uid_and_dev_flag(creds))

    assert uid == "dev-uid-1"
    assert is_dev is True


def test_require_uid_and_dev_flag_returns_uid_and_false_for_non_dev(monkeypatch):
    """require_uid_and_dev_flag returns (uid, False) when user is not on dev list."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_uids=[])
    monkeypatch.setattr(auth, "CONFIG", patched)
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "regular-user"}
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    loop = asyncio.new_event_loop()
    uid, is_dev = loop.run_until_complete(auth.require_uid_and_dev_flag(creds))

    assert uid == "regular-user"
    assert is_dev is False


def test_require_uid_and_dev_flag_raises_401_on_invalid_token(monkeypatch):
    """require_uid_and_dev_flag raises 401 when the token is invalid."""
    def _raise(_token):
        raise firebase_auth.InvalidIdTokenError("invalid")
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="bad-token")

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_uid_and_dev_flag(creds))

    assert exc_info.value.status_code == 401


# --- require_dev Dependency Tests -------------------------------------------


def test_require_dev_returns_uid_when_user_is_on_dev_list(monkeypatch):
    """require_dev returns uid when user is in dev_view_uids."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_uids=["dev-uid-1"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "dev-uid-1"}
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    loop = asyncio.new_event_loop()
    uid = loop.run_until_complete(auth.require_dev(creds))

    assert uid == "dev-uid-1"


def test_require_dev_raises_403_when_user_not_on_dev_list(monkeypatch):
    """require_dev raises 403 when user is not in dev_view_uids or emails."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_uids=[], dev_view_emails=[])
    monkeypatch.setattr(auth, "CONFIG", patched)
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "regular-user"}
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_dev(creds))

    assert exc_info.value.status_code == 403
    assert "Dev view only" in exc_info.value.detail


def test_require_dev_raises_401_on_invalid_token(monkeypatch):
    """require_dev raises 401 when the token is invalid (before permission check)."""
    def _raise(_token):
        raise firebase_auth.ExpiredIdTokenError("expired", cause=Exception("expired"))
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="expired-token")

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_dev(creds))

    assert exc_info.value.status_code == 401


def test_require_dev_allows_verified_dev_email(monkeypatch):
    """require_dev allows access when email is in dev_view_emails and verified."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_uids=[], dev_view_emails=["dev@example.com"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {
            "uid": "user-456",
            "email": "dev@example.com",
            "email_verified": True
        }
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    loop = asyncio.new_event_loop()
    uid = loop.run_until_complete(auth.require_dev(creds))

    assert uid == "user-456"


def test_require_dev_rejects_unverified_dev_email(monkeypatch):
    """require_dev rejects when email is in list but not verified."""
    patched = dataclasses.replace(auth.CONFIG, dev_view_uids=[], dev_view_emails=["dev@example.com"])
    monkeypatch.setattr(auth, "CONFIG", patched)
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {
            "uid": "user-456",
            "email": "dev@example.com",
            "email_verified": False
        }
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_dev(creds))

    assert exc_info.value.status_code == 403


# --- require_admin Dependency Tests -----------------------------------------


def test_require_admin_returns_uid_when_admin_claim_is_true(monkeypatch):
    """require_admin returns uid when the custom 'admin' claim is True."""
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "admin-user-1", "admin": True}
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    loop = asyncio.new_event_loop()
    uid = loop.run_until_complete(auth.require_admin(creds))

    assert uid == "admin-user-1"


def test_require_admin_raises_403_when_admin_claim_missing(monkeypatch):
    """require_admin raises 403 when the 'admin' claim is missing."""
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "regular-user"}
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_admin(creds))

    assert exc_info.value.status_code == 403
    assert "Admin only" in exc_info.value.detail


def test_require_admin_raises_403_when_admin_claim_is_false(monkeypatch):
    """require_admin raises 403 when the 'admin' claim is False."""
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "regular-user", "admin": False}
    )
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="valid-token")

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_admin(creds))

    assert exc_info.value.status_code == 403


def test_require_admin_raises_401_on_invalid_token(monkeypatch):
    """require_admin raises 401 when the token is invalid (before admin check)."""
    def _raise(_token):
        raise firebase_auth.RevokedIdTokenError("revoked")
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="revoked-token")

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_admin(creds))

    assert exc_info.value.status_code == 401


# --- require_admin_password Dependency Tests --------------------------------


def test_require_admin_password_allows_correct_password(monkeypatch):
    """require_admin_password succeeds when the header matches the config."""
    patched = dataclasses.replace(auth.CONFIG, admin_password="correct-secret")
    monkeypatch.setattr(auth, "CONFIG", patched)

    loop = asyncio.new_event_loop()
    loop.run_until_complete(auth.require_admin_password(x_admin_password="correct-secret"))
    # No exception raised


def test_require_admin_password_raises_403_on_wrong_password(monkeypatch):
    """require_admin_password raises 403 when the password doesn't match."""
    patched = dataclasses.replace(auth.CONFIG, admin_password="correct-secret")
    monkeypatch.setattr(auth, "CONFIG", patched)

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_admin_password(x_admin_password="wrong-secret"))

    assert exc_info.value.status_code == 403
    assert "Bad admin password" in exc_info.value.detail


def test_require_admin_password_raises_403_on_missing_header(monkeypatch):
    """require_admin_password raises 403 when the header is missing."""
    patched = dataclasses.replace(auth.CONFIG, admin_password="correct-secret")
    monkeypatch.setattr(auth, "CONFIG", patched)

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_admin_password(x_admin_password=None))

    assert exc_info.value.status_code == 403


def test_require_admin_password_fails_closed_when_unconfigured(monkeypatch):
    """require_admin_password raises 403 when ADMIN_PASSWORD is not set."""
    patched = dataclasses.replace(auth.CONFIG, admin_password="")
    monkeypatch.setattr(auth, "CONFIG", patched)

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_admin_password(x_admin_password="anything"))

    assert exc_info.value.status_code == 403
    assert "Bad admin password" in exc_info.value.detail


def test_require_admin_password_uses_constant_time_comparison(monkeypatch):
    """require_admin_password uses hmac.compare_digest to prevent timing attacks."""
    patched = dataclasses.replace(auth.CONFIG, admin_password="correct-secret")
    monkeypatch.setattr(auth, "CONFIG", patched)
    import hmac
    compare_calls = []

    original_compare = hmac.compare_digest
    def _spy(a, b):
        compare_calls.append((a, b))
        return original_compare(a, b)

    monkeypatch.setattr(hmac, "compare_digest", _spy)

    try:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_admin_password(x_admin_password="wrong"))
    except HTTPException:
        pass

    # hmac.compare_digest was called (timing-safe comparison)
    assert any(call[1] == "correct-secret" for call in compare_calls)


# --- require_cron Dependency Tests ------------------------------------------


def test_require_cron_allows_correct_secret(monkeypatch):
    """require_cron succeeds when the header matches the cron secret."""
    patched = dataclasses.replace(auth.CONFIG, cron_secret="cron-secret-123")
    monkeypatch.setattr(auth, "CONFIG", patched)

    loop = asyncio.new_event_loop()
    loop.run_until_complete(auth.require_cron(x_cron_secret="cron-secret-123"))
    # No exception raised


def test_require_cron_raises_403_on_wrong_secret(monkeypatch):
    """require_cron raises 403 when the secret doesn't match."""
    patched = dataclasses.replace(auth.CONFIG, cron_secret="cron-secret-123")
    monkeypatch.setattr(auth, "CONFIG", patched)

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_cron(x_cron_secret="wrong-secret"))

    assert exc_info.value.status_code == 403
    assert "Bad cron secret" in exc_info.value.detail


def test_require_cron_raises_403_on_missing_header(monkeypatch):
    """require_cron raises 403 when the header is missing."""
    patched = dataclasses.replace(auth.CONFIG, cron_secret="cron-secret-123")
    monkeypatch.setattr(auth, "CONFIG", patched)

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_cron(x_cron_secret=None))

    assert exc_info.value.status_code == 403


def test_require_cron_fails_closed_when_unconfigured(monkeypatch):
    """require_cron raises 403 when CRON_SECRET is not set (fails closed)."""
    patched = dataclasses.replace(auth.CONFIG, cron_secret="")
    monkeypatch.setattr(auth, "CONFIG", patched)

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_cron(x_cron_secret="anything"))

    assert exc_info.value.status_code == 403
    assert "Bad cron secret" in exc_info.value.detail


def test_require_cron_uses_constant_time_comparison(monkeypatch):
    """require_cron uses hmac.compare_digest to prevent timing attacks."""
    patched = dataclasses.replace(auth.CONFIG, cron_secret="correct-cron-secret")
    monkeypatch.setattr(auth, "CONFIG", patched)
    import hmac
    compare_calls = []

    original_compare = hmac.compare_digest
    def _spy(a, b):
        compare_calls.append((a, b))
        return original_compare(a, b)

    monkeypatch.setattr(hmac, "compare_digest", _spy)

    try:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_cron(x_cron_secret="wrong"))
    except HTTPException:
        pass

    # hmac.compare_digest was called
    assert any(call[1] == "correct-cron-secret" for call in compare_calls)


# --- require_revenuecat Dependency Tests ------------------------------------


def test_require_revenuecat_allows_authorized_request(monkeypatch):
    """require_revenuecat succeeds when billing.authorized returns True."""
    import billing

    monkeypatch.setattr(billing, "authorized", lambda _auth, _config: True)

    loop = asyncio.new_event_loop()
    loop.run_until_complete(auth.require_revenuecat(authorization="Bearer valid-token"))
    # No exception raised


def test_require_revenuecat_raises_403_on_unauthorized(monkeypatch):
    """require_revenuecat raises 403 when billing.authorized returns False."""
    import billing

    monkeypatch.setattr(billing, "authorized", lambda _auth, _config: False)

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_revenuecat(authorization="Bearer invalid-token"))

    assert exc_info.value.status_code == 403
    assert "Bad webhook secret" in exc_info.value.detail


def test_require_revenuecat_raises_403_on_missing_header(monkeypatch):
    """require_revenuecat raises 403 when the Authorization header is missing."""
    import billing

    monkeypatch.setattr(billing, "authorized", lambda _auth, _config: False)

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_revenuecat(authorization=None))

    assert exc_info.value.status_code == 403


def test_require_revenuecat_passes_authorization_and_config_to_billing(monkeypatch):
    """require_revenuecat passes the authorization header and CONFIG to billing.authorized."""
    import billing

    seen_args = []

    def _authorized(auth, config):
        seen_args.append((auth, config))
        return True

    monkeypatch.setattr(billing, "authorized", _authorized)

    loop = asyncio.new_event_loop()
    loop.run_until_complete(auth.require_revenuecat(authorization="Bearer test-secret"))

    assert len(seen_args) == 1
    assert seen_args[0][0] == "Bearer test-secret"
    assert seen_args[0][1] == CONFIG


# --- Integration Tests (Multi-Dependency Scenarios) -------------------------


def test_both_token_verification_and_permission_checks_are_enforced(monkeypatch):
    """Admin endpoints must both verify the token AND check the admin claim."""
    # Case 1: Invalid token → 401 (before admin check)
    def _raise(_token):
        raise firebase_auth.InvalidIdTokenError("invalid")
    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)
    creds = HTTPAuthorizationCredentials(scheme="Bearer", credentials="bad-token")

    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_admin(creds))
    assert exc_info.value.status_code == 401

    # Case 2: Valid token, no admin claim → 403
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "regular-user"}
    )
    with pytest.raises(HTTPException) as exc_info:
        loop = asyncio.new_event_loop()
        loop.run_until_complete(auth.require_admin(creds))
    assert exc_info.value.status_code == 403

    # Case 3: Valid token with admin claim → success
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "admin-user", "admin": True}
    )
    uid = loop.run_until_complete(auth.require_admin(creds))
    assert uid == "admin-user"


def test_secret_gate_functions_reject_empty_credentials(monkeypatch):
    """Functions guarding secrets (admin password, cron) reject empty/None credentials."""
    patched = dataclasses.replace(auth.CONFIG, admin_password="not-empty", cron_secret="not-empty")
    monkeypatch.setattr(auth, "CONFIG", patched)

    loop = asyncio.new_event_loop()

    # Empty string header
    with pytest.raises(HTTPException):
        loop.run_until_complete(auth.require_admin_password(x_admin_password=""))

    with pytest.raises(HTTPException):
        loop.run_until_complete(auth.require_cron(x_cron_secret=""))
