import dataclasses

import instagram
import main
import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def _cfg(**overrides):
    return dataclasses.replace(instagram.CONFIG, **overrides)


@pytest.fixture
def _configured(monkeypatch):
    monkeypatch.setattr(
        instagram, "CONFIG",
        _cfg(
            instagram_app_id="APPID",
            instagram_redirect_uri="https://ayma.example/ig/callback",
            instagram_media_limit=20,
        ),
    )
    monkeypatch.setenv("INSTAGRAM_APP_SECRET", "SEKRIT")


class _Col:
    def __init__(self, store, key):
        self._s, self._k = store, key

    def document(self, doc_id="_"):
        return _Doc(self._s, self._k + (doc_id,))

    def add(self, payload):
        self._s.setdefault("media", []).append(payload)


class _Doc:
    def __init__(self, store, key):
        self._s, self._k = store, key

    def set(self, payload, merge=False):
        self._s.setdefault("user", {}).update(payload)

    def collection(self, name):
        return _Col(self._s, self._k + (name,))


class _Db:
    def __init__(self):
        self.store = {}

    def collection(self, name):
        return _Col(self.store, (name,))


def test_auth_url_requires_configuration(monkeypatch):
    monkeypatch.setattr(instagram, "CONFIG", _cfg(instagram_app_id=""))
    monkeypatch.delenv("INSTAGRAM_APP_SECRET", raising=False)
    with pytest.raises(instagram.InstagramError):
        instagram.auth_url("state-me")


def test_auth_url_built_from_config(_configured):
    url = instagram.auth_url("state-me")
    assert url.startswith("https://api.instagram.com/oauth/authorize?")
    assert "client_id=APPID" in url
    assert "state=state-me" in url
    assert "scope=instagram_business_basic" in url


def test_connect_stores_token_imports_media_and_writes_raw_turns(
    monkeypatch, _configured
):
    monkeypatch.setattr(instagram, "_exchange_code", lambda code: "LONG-TOKEN")
    monkeypatch.setattr(
        instagram, "_fetch_media",
        lambda token, limit: [
            {"id": "111", "media_type": "IMAGE",
             "media_url": "https://cdn/111.jpg", "caption": "sunset run",
             "permalink": "https://insta/p/111"},
            {"id": "222", "media_type": "IMAGE",
             "media_url": "https://cdn/222.jpg", "caption": ""},
            {"id": "333", "media_type": "VIDEO",
             "media_url": "https://cdn/333.mp4"},
        ],
    )
    monkeypatch.setattr(instagram, "_fetch_username", lambda token: "amy.runs")
    monkeypatch.setattr(instagram, "_download", lambda url: b"JPEGDATA")

    uploaded = []

    class _Blob:
        def __init__(self, path):
            self.path = path

        def upload_from_string(self, data, content_type=None):
            uploaded.append((self.path, content_type))

    class _Bucket:
        def blob(self, path):
            return _Blob(path)

    monkeypatch.setattr(instagram.storage, "bucket", lambda name: _Bucket())

    persisted = []
    monkeypatch.setattr(
        instagram, "persist_raw_turns",
        lambda db, uid, sid, turns: persisted.append((uid, sid, turns[0].text)),
    )
    monkeypatch.setattr(instagram.firestore, "SERVER_TIMESTAMP", "TS")

    db = _Db()
    result = instagram.connect(db, "me", "the-code")

    assert result == {"ok": True, "imported": 2}  # video skipped
    assert db.store["user"]["instagram_access_token"] == "LONG-TOKEN"
    assert sorted(p for p, _ in uploaded) == [
        "uploads/me/ig_111.jpg", "uploads/me/ig_222.jpg"
    ]
    media_docs = db.store["media"]
    assert all(d["source"] == "instagram_import" for d in media_docs)
    assert all(d["moderation_status"] == "pending" for d in media_docs)
    text = persisted[0][2]
    assert "@amy.runs" in text and "sunset run" in text


def test_disconnect_deletes_the_token_field(monkeypatch, _configured):
    monkeypatch.setattr(instagram.firestore, "DELETE_FIELD", "DELETE")
    db = _Db()
    instagram.disconnect(db, "me")
    assert db.store["user"]["instagram_access_token"] == "DELETE"


def test_connect_endpoint_maps_config_error_to_503(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.get("/instagram/auth-url", headers=_auth(monkeypatch))
    assert resp.status_code == 503
