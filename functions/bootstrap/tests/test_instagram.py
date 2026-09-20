import dataclasses
import urllib.parse

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

    import photo_pipeline

    pipeline_calls = []

    async def _pipeline(db, uid, path, source, **kw):
        pipeline_calls.append((uid, path, source))
        return {"media_id": "m", "published": True}

    monkeypatch.setattr(photo_pipeline, "process", _pipeline)

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
    assert sorted(pipeline_calls) == [
        ("me", "uploads/me/ig_111.jpg", "instagram_import"),
        ("me", "uploads/me/ig_222.jpg", "instagram_import"),
    ]
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


# ---------------------------------------------------------------------- #
# "Sign in with Instagram" — new, reachable before any Firebase auth exists.
# ---------------------------------------------------------------------- #

class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data else {}


class _SigninDoc:
    def __init__(self, store, key):
        self._s, self._k = store, key

    def get(self):
        return _Snap(self._s.get(self._k))

    def set(self, payload, merge=False):
        cur = dict(self._s.get(self._k) or {})
        cur.update(payload)
        self._s[self._k] = cur


class _SigninCol:
    def __init__(self, store, key):
        self._s, self._k = store, key

    def document(self, doc_id="_"):
        return _SigninDoc(self._s, self._k + (doc_id,))


class _SigninDb:
    def __init__(self):
        self.store: dict[tuple, dict] = {}

    def collection(self, name):
        return _SigninCol(self.store, (name,))


class _FirebaseUser:
    def __init__(self, uid):
        self.uid = uid


def test_signin_auth_url_requires_configuration(monkeypatch):
    monkeypatch.setattr(instagram, "CONFIG", _cfg(instagram_app_id=""))
    monkeypatch.delenv("INSTAGRAM_APP_SECRET", raising=False)
    with pytest.raises(instagram.InstagramError):
        instagram.signin_auth_url()


def test_signin_auth_url_uses_a_fresh_random_state_each_call(_configured):
    url1 = instagram.signin_auth_url()
    url2 = instagram.signin_auth_url()
    assert url1.startswith("https://api.instagram.com/oauth/authorize?")
    assert "client_id=APPID" in url1
    assert "scope=instagram_business_basic" in url1

    def _state(url):
        return urllib.parse.parse_qs(urllib.parse.urlparse(url).query)["state"][0]

    # A real random nonce, not a fixed placeholder and not a uid (none exists
    # yet at this point in the flow).
    assert _state(url1) != _state(url2)


def test_signin_auth_url_endpoint_requires_no_auth(_configured):
    resp = client.get("/instagram/signin-auth-url")
    assert resp.status_code == 200
    assert resp.json()["url"].startswith(
        "https://api.instagram.com/oauth/authorize?"
    )


def test_signin_first_time_creates_firebase_user_and_stores_mapping(
    monkeypatch, _configured
):
    monkeypatch.setattr(instagram, "_exchange_code", lambda code: "LONG-TOKEN")
    monkeypatch.setattr(
        instagram, "_fetch_profile",
        lambda token: {"id": "999", "username": "amy.runs"},
    )

    created = []

    def _create_user(**kwargs):
        created.append(kwargs)
        return _FirebaseUser("uid-abc")

    monkeypatch.setattr(instagram.firebase_auth, "create_user", _create_user)
    monkeypatch.setattr(
        instagram.firebase_auth, "create_custom_token",
        lambda uid: f"TOKEN-FOR-{uid}".encode(),
    )
    monkeypatch.setattr(instagram.firestore, "SERVER_TIMESTAMP", "TS")

    db = _SigninDb()
    result = instagram.signin(db, "the-code")

    assert result == {"customToken": "TOKEN-FOR-uid-abc", "isNewUser": True}
    assert created == [{"display_name": "amy.runs"}]  # username -> display_name
    stored = db.store[("instagram_identities", "999")]
    assert stored == {"uid": "uid-abc", "username": "amy.runs", "created_at": "TS"}


def test_signin_repeat_reuses_existing_uid_and_creates_no_duplicate(
    monkeypatch, _configured
):
    monkeypatch.setattr(instagram, "_exchange_code", lambda code: "LONG-TOKEN")
    monkeypatch.setattr(
        instagram, "_fetch_profile",
        lambda token: {"id": "999", "username": "amy.runs"},
    )

    db = _SigninDb()
    db.store[("instagram_identities", "999")] = {
        "uid": "uid-abc", "username": "amy.runs",
    }

    def _create_user(**kwargs):
        raise AssertionError("must not create a duplicate Firebase user")

    monkeypatch.setattr(instagram.firebase_auth, "create_user", _create_user)
    monkeypatch.setattr(
        instagram.firebase_auth, "create_custom_token",
        lambda uid: f"TOKEN-FOR-{uid}".encode(),
    )

    result = instagram.signin(db, "the-code")

    assert result == {"customToken": "TOKEN-FOR-uid-abc", "isNewUser": False}
    # No second identity doc was created; the original is untouched.
    assert len(db.store) == 1


def test_signin_requires_an_instagram_account_id(monkeypatch, _configured):
    monkeypatch.setattr(instagram, "_exchange_code", lambda code: "LONG-TOKEN")
    monkeypatch.setattr(
        instagram, "_fetch_profile", lambda token: {"username": "amy.runs"}
    )
    with pytest.raises(instagram.InstagramError):
        instagram.signin(_SigninDb(), "the-code")


def test_signin_endpoint_requires_no_auth_and_returns_custom_token(
    monkeypatch, _configured
):
    monkeypatch.setattr(main, "get_db", lambda: _SigninDb())
    monkeypatch.setattr(instagram, "_exchange_code", lambda code: "LONG-TOKEN")
    monkeypatch.setattr(
        instagram, "_fetch_profile",
        lambda token: {"id": "555", "username": "newbie"},
    )
    monkeypatch.setattr(
        instagram.firebase_auth, "create_user",
        lambda **kw: _FirebaseUser("uid-new"),
    )
    monkeypatch.setattr(
        instagram.firebase_auth, "create_custom_token",
        lambda uid: f"T-{uid}".encode(),
    )
    monkeypatch.setattr(instagram.firestore, "SERVER_TIMESTAMP", "TS")

    resp = client.post("/instagram/signin", json={"code": "the-code"})

    assert resp.status_code == 200
    assert resp.json() == {"customToken": "T-uid-new", "isNewUser": True}


def test_signin_endpoint_maps_instagram_error_to_502(monkeypatch, _configured):
    monkeypatch.setattr(main, "get_db", lambda: _SigninDb())
    monkeypatch.setattr(instagram, "_exchange_code", lambda code: "LONG-TOKEN")
    monkeypatch.setattr(
        instagram, "_fetch_profile", lambda token: {"username": "no-id"}
    )
    resp = client.post("/instagram/signin", json={"code": "the-code"})
    assert resp.status_code == 502
