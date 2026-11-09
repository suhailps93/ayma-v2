"""Start-grant eligibility (start_grant.py): verified contact + selfie."""

import start_grant

# The real lookup, captured before conftest's autouse fixture stubs it.
_real_contact_verified = start_grant.contact_verified
_real_grant_status = start_grant.grant_status


def test_contact_verified_rules(monkeypatch):
    from types import SimpleNamespace as NS

    from firebase_admin import auth as firebase_auth

    cases = [
        (NS(phone_number="+15551234567", email=None, email_verified=False), True),
        (NS(phone_number=None, email="a@b.c", email_verified=True), True),
        (NS(phone_number=None, email="a@b.c", email_verified=False), False),
        (NS(phone_number=None, email=None, email_verified=False), False),
    ]
    for user, expect in cases:
        monkeypatch.setattr(firebase_auth, "get_user", lambda uid, u=user: u)
        assert _real_contact_verified("x") is expect

    def boom(uid):
        raise RuntimeError("down")

    monkeypatch.setattr(firebase_auth, "get_user", boom)
    assert _real_contact_verified("x") is False


_SELFIE = {"face_verification": {"storage_path": "verification/s1/selfie.jpg", "verified": True}}


def _status(monkeypatch, data, contact=True, uid="s1"):
    start_grant._pending_until.clear()
    monkeypatch.setattr(start_grant, "contact_verified", lambda u: contact)
    monkeypatch.setattr(start_grant, "get_db", lambda: object())
    return _real_grant_status(uid, data)


def test_grant_status_needs_selfie_and_contact(monkeypatch):
    assert _status(monkeypatch, _SELFIE) == start_grant.GRANT_OK
    assert _status(monkeypatch, {}) == start_grant.GRANT_PENDING  # no selfie
    assert _status(monkeypatch, _SELFIE, contact=False) == start_grant.GRANT_PENDING
