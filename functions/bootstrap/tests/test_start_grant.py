"""Start-grant eligibility (start_grant.py): verified contact + selfie,
same-face dedupe, fail-closed lookups."""

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


_SELFIE = {"face_verification": {"embedding": [1.0, 0.0, 0.0]}}


def _status(monkeypatch, data, contact=True, duplicate=False, uid="s1"):
    start_grant._pending_until.clear()
    monkeypatch.setattr(start_grant, "contact_verified", lambda u: contact)
    monkeypatch.setattr(
        start_grant, "is_duplicate_face", lambda db, u, e: duplicate
    )
    monkeypatch.setattr(start_grant, "get_db", lambda: object())
    return _real_grant_status(uid, data)


def test_grant_status_needs_selfie_contact_and_no_duplicate(monkeypatch):
    assert _status(monkeypatch, _SELFIE) == start_grant.GRANT_OK
    assert _status(monkeypatch, {}) == start_grant.GRANT_PENDING  # no selfie
    assert _status(monkeypatch, _SELFIE, contact=False) == start_grant.GRANT_PENDING
    assert _status(monkeypatch, _SELFIE, duplicate=True) == start_grant.GRANT_DUPLICATE


def test_grant_status_fails_closed_on_lookup_error(monkeypatch):
    def boom(db, u, e):
        raise RuntimeError("no vector index")

    start_grant._pending_until.clear()
    monkeypatch.setattr(start_grant, "contact_verified", lambda u: True)
    monkeypatch.setattr(start_grant, "is_duplicate_face", boom)
    monkeypatch.setattr(start_grant, "get_db", lambda: object())
    assert _real_grant_status("s1", _SELFIE) == start_grant.GRANT_PENDING


class _NearSnap:
    def __init__(self, uid, emb, unlocked=True):
        self.id = uid
        self._d = {
            "face_verification": {"embedding": emb},
            "billing": {"start_grant_unlocked": unlocked},
        }

    def to_dict(self):
        return self._d


class _NearDb:
    def __init__(self, snaps):
        self._snaps = snaps

    def collection(self, name):
        return self

    def find_nearest(self, **kw):
        assert kw["vector_field"] == "face_verification.embedding"
        return self

    def stream(self):
        return iter(self._snaps)


def test_duplicate_face_uses_the_deep_dive_threshold():
    import deep_dive_images

    me = [1.0, 0.0]
    same = [1.0, 0.0]
    other = [0.0, 1.0]
    assert deep_dive_images._cosine(me, other) < deep_dive_images._VERIFY_THRESHOLD
    f = start_grant.is_duplicate_face
    assert f(_NearDb([_NearSnap("a", same)]), "me", me) is True
    assert f(_NearDb([_NearSnap("a", other)]), "me", me) is False
    assert f(_NearDb([_NearSnap("me", same)]), "me", me) is False  # itself
    # a match that never got the grant is not "the original"
    assert f(_NearDb([_NearSnap("a", same, unlocked=False)]), "me", me) is False
