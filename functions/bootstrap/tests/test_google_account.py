import asyncio
import dataclasses

import google_account
import main
import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _run(coro):
    return asyncio.run(coro)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def _cfg(**overrides):
    return dataclasses.replace(google_account.CONFIG, **overrides)


@pytest.fixture
def _configured(monkeypatch):
    monkeypatch.setattr(
        google_account, "CONFIG",
        _cfg(
            google_import_client_id="CLIENTID",
            google_import_redirect_uri="https://ayma.example/google/callback",
            google_sync_window_days=30,
            google_gmail_limit=100,
            google_calendar_limit=100,
            google_photos_limit=100,
            google_sync_min_interval_hours=20,
        ),
    )
    monkeypatch.setenv("GOOGLE_IMPORT_CLIENT_SECRET", "SEKRIT")


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data else {}


class _Ref:
    def __init__(self, store, key):
        self._s, self.key = store, key

    @property
    def parent(self):
        return _Ref(self._s, self.key[:-1])

    @property
    def id(self):
        return self.key[-1] if self.key else None


class _Doc:
    def __init__(self, store, key):
        self._s, self._k = store, key
        self.reference = _Ref(store, key)

    def get(self):
        return _Snap(self._s.get(self._k))

    def set(self, payload, merge=False):
        cur = dict(self._s.get(self._k) or {})
        cur.update(payload)
        self._s[self._k] = cur

    def delete(self):
        self._s.pop(self._k, None)

    def collection(self, name):
        return _Col(self._s, self._k + (name,))


class _Col:
    def __init__(self, store, key):
        self._s, self._k = store, key

    def document(self, doc_id="_"):
        return _Doc(self._s, self._k + (doc_id,))


class _Db:
    def __init__(self):
        self.store: dict[tuple, dict] = {}

    def collection(self, name):
        return _Col(self.store, (name,))


def test_auth_url_requires_configuration(monkeypatch):
    monkeypatch.setattr(google_account, "CONFIG", _cfg(google_import_client_id=""))
    monkeypatch.delenv("GOOGLE_IMPORT_CLIENT_SECRET", raising=False)
    with pytest.raises(google_account.GoogleAccountError):
        google_account.auth_url("state-me")


def test_auth_url_built_from_config_with_minimum_scopes(_configured):
    url = google_account.auth_url("state-me")
    assert url.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
    assert "client_id=CLIENTID" in url
    assert "state=state-me" in url
    assert "access_type=offline" in url
    assert "prompt=consent" in url
    # Minimum-necessary, read-only scopes only.
    assert "gmail.readonly" in url
    assert "calendar.events.readonly" in url
    assert "photoslibrary.readonly" in url
    assert "gmail.send" not in url
    assert "gmail.modify" not in url


def test_connect_requires_refresh_token(monkeypatch, _configured):
    monkeypatch.setattr(
        google_account, "_exchange_code",
        lambda code: {"access_token": "AT", "scope": "x"},
    )
    with pytest.raises(google_account.GoogleAccountError):
        google_account.connect(_Db(), "me", "the-code")


def test_connect_stores_refresh_token_and_schedules_sync(monkeypatch, _configured):
    monkeypatch.setattr(
        google_account, "_exchange_code",
        lambda code: {
            "access_token": "AT", "refresh_token": "RT", "scope": "gmail.readonly",
        },
    )
    monkeypatch.setattr(google_account, "_fetch_email", lambda token: "me@gmail.com")
    scheduled = []
    monkeypatch.setattr(
        google_account, "schedule_sync",
        lambda db, uid: scheduled.append(uid) or False,
    )

    db = _Db()
    result = google_account.connect(db, "me", "the-code")

    assert result == {"ok": True, "email": "me@gmail.com"}
    stored = db.store[("users", "me", "oauth_tokens", "google")]
    assert stored["refresh_token"] == "RT"
    assert stored["email"] == "me@gmail.com"
    assert scheduled == ["me"]


def test_disconnect_revokes_and_deletes_token_doc(monkeypatch, _configured):
    db = _Db()
    db.store[("users", "me", "oauth_tokens", "google")] = {
        "refresh_token": "RT", "email": "me@gmail.com",
    }
    revoked = []
    monkeypatch.setattr(google_account, "_revoke", lambda token: revoked.append(token))

    google_account.disconnect(db, "me")

    assert revoked == ["RT"]
    assert ("users", "me", "oauth_tokens", "google") not in db.store


def test_disconnect_is_a_noop_when_never_connected(monkeypatch, _configured):
    revoked = []
    monkeypatch.setattr(google_account, "_revoke", lambda token: revoked.append(token))
    google_account.disconnect(_Db(), "me")
    assert revoked == []


def test_status_never_returns_the_token(_configured):
    db = _Db()
    db.store[("users", "me", "oauth_tokens", "google")] = {
        "refresh_token": "RT", "email": "me@gmail.com",
    }
    result = google_account.status(db, "me")
    assert result["connected"] is True
    assert result["email"] == "me@gmail.com"
    assert "refresh_token" not in result
    assert "RT" not in str(result)


def test_status_when_not_connected(_configured):
    assert google_account.status(_Db(), "me") == {"connected": False}


def test_sync_user_pulls_bounded_facts_and_forces_private_visibility(
    monkeypatch, _configured
):
    db = _Db()
    db.store[("users", "me", "oauth_tokens", "google")] = {"refresh_token": "RT"}
    monkeypatch.setattr(google_account, "_refresh_access_token", lambda rt: "AT")
    monkeypatch.setattr(
        google_account, "_gmail_facts",
        lambda token: ["Email subject: Flight confirmation (from delta.com)"],
    )
    monkeypatch.setattr(
        google_account, "_calendar_facts",
        lambda token: ["Calendar event: Sister's birthday dinner on 2026-09-20"],
    )
    monkeypatch.setattr(
        google_account, "_photos_facts",
        lambda token: ["Google Photos: 12 item(s) added in the last 30 days (10 photo(s), 2 video(s))."],
    )

    import wiki_ingest

    calls = []

    async def _fake_ingest(db_, uid, session_id, turns, force_visibility=None):
        calls.append((uid, session_id, turns, force_visibility))
        return 2

    monkeypatch.setattr(wiki_ingest, "ingest", _fake_ingest)

    result = _run(google_account.sync_user(db, "me"))

    assert result == {"ok": True, "facts_pulled": 3, "pages_written": 2}
    assert len(calls) == 1
    uid, session_id, turns, force_visibility = calls[0]
    assert uid == "me"
    assert session_id == ""  # never persisted to raw_turns
    assert force_visibility == "private"
    text = turns[0].text
    assert "Flight confirmation" in text
    assert "Sister's birthday dinner" in text
    assert "Google Photos" in text
    assert db.store[("users", "me", "oauth_tokens", "google")].get("last_synced_at")


def test_sync_user_when_not_connected(_configured):
    result = _run(google_account.sync_user(_Db(), "me"))
    assert result == {"ok": False, "reason": "not_connected"}


def test_sync_user_one_source_failing_does_not_block_others(
    monkeypatch, _configured
):
    db = _Db()
    db.store[("users", "me", "oauth_tokens", "google")] = {"refresh_token": "RT"}
    monkeypatch.setattr(google_account, "_refresh_access_token", lambda rt: "AT")

    def _boom(token):
        raise RuntimeError("Gmail API disabled")

    monkeypatch.setattr(google_account, "_gmail_facts", _boom)
    monkeypatch.setattr(google_account, "_calendar_facts", lambda token: ["Calendar event: Dentist on 2026-09-18"])
    monkeypatch.setattr(google_account, "_photos_facts", lambda token: [])

    import wiki_ingest

    async def _fake_ingest(db_, uid, session_id, turns, force_visibility=None):
        return 1

    monkeypatch.setattr(wiki_ingest, "ingest", _fake_ingest)

    result = _run(google_account.sync_user(db, "me"))
    assert result["ok"] is True
    assert result["facts_pulled"] == 1


def test_sweep_skips_recently_synced_users(monkeypatch, _configured):
    from datetime import datetime, timezone

    class _QueryDoc:
        def __init__(self, key, data):
            self.id = key[-1]
            self._data = data
            self.reference = _Ref({}, key)

        def to_dict(self):
            return self._data

    class _Query:
        def __init__(self, docs):
            self._docs = docs

        def limit(self, n):
            return self

        def stream(self):
            return list(self._docs)

    docs = [
        _QueryDoc(("users", "fresh", "oauth_tokens", "google"),
                  {"last_synced_at": datetime.now(timezone.utc)}),
        _QueryDoc(("users", "stale", "oauth_tokens", "google"), {}),
    ]

    class _SweepDb(_Db):
        def collection_group(self, name):
            assert name == "oauth_tokens"
            return _Query(docs)

    synced = []

    async def _fake_sync(db_, uid):
        synced.append(uid)
        return {"ok": True}

    monkeypatch.setattr(google_account, "sync_user", _fake_sync)

    result = _run(google_account.sweep(_SweepDb(), user_limit=10))
    assert synced == ["stale"]
    assert result == {"users": 2, "synced": 1}


def test_google_auth_url_endpoint_maps_config_error_to_503(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.get("/google/auth-url", headers=_auth(monkeypatch))
    assert resp.status_code == 503
