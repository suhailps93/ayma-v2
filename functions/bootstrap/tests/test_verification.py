"""§ face verification: POST /verification/selfie + GET /verification/status.

A verification selfie is moderated exactly like any other upload (a
rejection here is no exception), then embedded and stored on
`users/{uid}.face_verification` — never a `user_media` doc, never enumerated
as a photo anywhere in the app.
"""

import auto_analysis
import main
import media_embed
import photo_attrs
import photo_moderation
import schema
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

_client = TestClient(main.app)


class _DocRef:
    def __init__(self, store, key):
        self._store, self._key = store, key

    def get(self):
        return _Snap(self._store.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._store.get(self._key, {})) if merge else {}
        cur.update(payload)
        self._store[self._key] = cur

    def collection(self, name):
        return _CollRef(self._store, self._key + (name,))


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _CollRef:
    def __init__(self, store, key):
        self._store, self._key = store, key

    def document(self, name):
        return _DocRef(self._store, self._key + (name,))


class FakeDb:
    def __init__(self):
        self.store = {}

    def collection(self, name):
        return _CollRef(self.store, (name,))


def _auth(monkeypatch, uid="u1"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def _ok_moderation(monkeypatch):
    async def _mod(b, m, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_moderation, "moderate", _mod)


def _stub_media(monkeypatch):
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda p: (b"IMGBYTES", "image/jpeg")
    )

    async def _attrs(b, m, **_kw):
        return {"shot_type": "face", "usable_for_face": True,
                "usable_for_body": False}

    monkeypatch.setattr(photo_attrs, "extract_attributes", _attrs)


def test_verification_requires_a_token():
    resp = _client.post(
        "/verification/selfie",
        json={"storage_path": "verification/u1/selfie.jpg"},
    )
    assert resp.status_code in (401, 403)


def test_verification_rejects_a_path_outside_the_callers_tree(monkeypatch):
    resp = _client.post(
        "/verification/selfie",
        headers=_auth(monkeypatch),
        json={"storage_path": "verification/someone-else/selfie.jpg"},
    )
    assert resp.status_code == 403


def test_verification_selfie_rejects_on_failed_moderation_like_any_photo(
    monkeypatch,
):
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    _stub_media(monkeypatch)

    async def _mod(b, m, **_kw):
        return {"allowed": False, "reason": "nudity", "categories": ["nudity"]}

    monkeypatch.setattr(photo_moderation, "moderate", _mod)

    seen = []
    monkeypatch.setattr(
        auto_analysis, "analyse_photo",
        lambda *a, **k: seen.append((a, k)),
    )

    resp = _client.post(
        "/verification/selfie",
        headers=_auth(monkeypatch),
        json={"storage_path": "verification/u1/selfie.jpg"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["verified"] is False
    assert body["moderation_status"] == schema.MEDIA_STATUS_FLAGGED
    assert body["reason"] == "nudity"
    # No reference stored, and no analysis scheduled, for a rejected selfie.
    assert ("users", "u1") not in db.store
    assert seen == []


def test_verification_selfie_success_stores_the_reference_and_seeds_analysis(
    monkeypatch,
):
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    _stub_media(monkeypatch)
    _ok_moderation(monkeypatch)

    seen = []

    async def _spy(_db, uid, storage_path, **kw):
        seen.append((uid, storage_path, kw))

    monkeypatch.setattr(main.auto_analysis, "analyse_photo", _spy)

    resp = _client.post(
        "/verification/selfie",
        headers=_auth(monkeypatch),
        json={"storage_path": "verification/u1/selfie.jpg"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["verified"] is True
    assert body["moderation_status"] == schema.MEDIA_STATUS_APPROVED

    stored = db.store[("users", "u1")]
    fv = stored[schema.FIELD_FACE_VERIFICATION]
    assert schema.FACE_VERIFICATION_EMBEDDING not in fv
    assert fv[schema.FACE_VERIFICATION_STORAGE_PATH] == "verification/u1/selfie.jpg"
    assert fv["verified"] is True
    assert schema.FACE_VERIFICATION_VERIFIED_AT in fv

    # TestClient drains the background task after the response.
    assert len(seen) == 1
    uid, storage_path, kw = seen[0]
    assert (uid, storage_path) == ("u1", "verification/u1/selfie.jpg")
    assert kw["attributes"]["shot_type"] == "face"


def test_verification_status_false_when_unverified(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    resp = _client.get("/verification/status", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json() == {"verified": False}


def test_verification_status_true_once_verified(monkeypatch):
    db = FakeDb()
    db.store[("users", "u1")] = {
        schema.FIELD_FACE_VERIFICATION: {
            schema.FACE_VERIFICATION_STORAGE_PATH: "verification/u1/selfie.jpg",
            "verified": True,
        }
    }
    monkeypatch.setattr(main, "get_db", lambda: db)
    resp = _client.get("/verification/status", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json() == {"verified": True}
