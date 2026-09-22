import asyncio
import base64
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
            google_gmail_body_limit=8,
            google_calendar_limit=100,
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
    assert "gmail.send" not in url
    assert "gmail.modify" not in url


def test_auth_url_no_longer_requests_photos_scope(_configured):
    # Google retired third-party read access to a user's existing Photos
    # library (2025-03-31) — the scope was dropped entirely (see module
    # docstring), not just left unused.
    url = google_account.auth_url("state-me")
    assert "photoslibrary" not in url


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


def test_schedule_sync_runs_with_no_running_event_loop(monkeypatch):
    """Real regression test for a real production bug (2026-09-20): the
    ``/google/connect`` endpoint always runs ``connect()`` — and therefore
    ``schedule_sync`` — via ``asyncio.to_thread``, a plain worker thread with
    no running event loop. The old implementation called
    ``asyncio.get_running_loop()`` directly and silently no-op'd (caught
    RuntimeError, returned False) in exactly that situation, so no sync ever
    ran for any real user. This test calls ``schedule_sync`` from a plain
    sync function — same as pytest's default (no running loop) — which is
    exactly the condition that broke in production."""
    import threading

    called = threading.Event()
    seen_uid = []

    async def fake_sync_user(db, uid):
        seen_uid.append(uid)
        called.set()

    monkeypatch.setattr(google_account, "sync_user", fake_sync_user)

    with pytest.raises(RuntimeError):
        asyncio.get_running_loop()  # confirms this test has no running loop

    result = google_account.schedule_sync(object(), "real-uid")
    assert result is True

    assert called.wait(timeout=2), "sync_user was never actually invoked"
    assert seen_uid == ["real-uid"]


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
        lambda db, token: ["Email subject: Flight confirmation (from delta.com)"],
    )
    monkeypatch.setattr(
        google_account, "_calendar_facts",
        lambda token: ["Calendar event: Sister's birthday dinner on 2026-09-20"],
    )

    import wiki_ingest

    calls = []

    async def _fake_ingest(
        db_, uid, session_id, turns, force_visibility=None, record_source=True,
    ):
        calls.append((uid, session_id, turns, force_visibility, record_source))
        return 2

    monkeypatch.setattr(wiki_ingest, "ingest", _fake_ingest)

    result = _run(google_account.sync_user(db, "me"))

    assert result == {"ok": True, "facts_pulled": 2, "pages_written": 2}
    assert len(calls) == 1
    uid, session_id, turns, force_visibility, record_source = calls[0]
    assert uid == "me"
    assert session_id == ""  # never persisted to raw_turns
    assert force_visibility == "private"
    # record_source=False (§ fact-source-of-truth, 2026-09-21): Gmail/
    # Calendar content must never end up verbatim in wiki_pages.source_log
    # either — same reason it's never persisted to raw_turns in the first
    # place (see google_account.py's module docstring).
    assert record_source is False
    text = turns[0].text
    assert "Flight confirmation" in text
    assert "Sister's birthday dinner" in text
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

    def _boom(db, token):
        raise RuntimeError("Gmail API disabled")

    monkeypatch.setattr(google_account, "_gmail_facts", _boom)
    monkeypatch.setattr(google_account, "_calendar_facts", lambda token: ["Calendar event: Dentist on 2026-09-18"])

    import wiki_ingest

    async def _fake_ingest(
        db_, uid, session_id, turns, force_visibility=None, record_source=True,
    ):
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


# --------------------------------------------------------------------- #
# Task 2 — Gmail body-reading: domain exclusion, body extraction/
# truncation, and the Firestore-config-with-fallback read path.
# --------------------------------------------------------------------- #


def _b64(text: str) -> str:
    return base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")


def test_domain_excluded_matches_exact_and_subdomain_case_insensitively():
    excluded = ["Chase.com", "paypal.com"]
    assert google_account._domain_excluded("chase.com", excluded) is True
    assert google_account._domain_excluded("CHASE.com", excluded) is True
    assert google_account._domain_excluded("secure.chase.com", excluded) is True
    assert google_account._domain_excluded("notchase.com", excluded) is False
    assert google_account._domain_excluded("paypal.com", excluded) is True
    assert google_account._domain_excluded("delta.com", excluded) is False
    assert google_account._domain_excluded("", excluded) is False


def test_extract_gmail_body_from_text_plain_part_among_multipart():
    msg = {
        "payload": {
            "mimeType": "multipart/alternative",
            "parts": [
                {"mimeType": "text/html", "body": {"data": _b64("<p>hi</p>")}},
                {"mimeType": "text/plain", "body": {"data": _b64("Hello there!")}},
            ],
        }
    }
    assert google_account._extract_gmail_body(msg) == "Hello there!"


def test_extract_gmail_body_falls_back_to_body_data_when_no_parts():
    msg = {"payload": {"mimeType": "text/plain", "body": {"data": _b64("Just text.")}}}
    assert google_account._extract_gmail_body(msg) == "Just text."


def test_extract_gmail_body_strips_quote_chain_and_boilerplate():
    raw = (
        "Sure, sounds good.\n"
        "On Mon, Jan 5, 2026 at 3:00 PM John Doe <john@example.com> wrote:\n"
        "> Are we still on for lunch?\n"
        "> Let me know.\n"
    )
    msg = {"payload": {"mimeType": "text/plain", "body": {"data": _b64(raw)}}}
    assert google_account._extract_gmail_body(msg) == "Sure, sounds good."


def test_extract_gmail_body_truncates_to_bound():
    long_text = "x" * 5000
    msg = {"payload": {"mimeType": "text/plain", "body": {"data": _b64(long_text)}}}
    result = google_account._extract_gmail_body(msg)
    assert len(result) == google_account._GMAIL_BODY_MAX_CHARS


def test_read_gmail_exclude_domains_uses_default_when_doc_missing(_configured):
    domains = google_account._read_gmail_exclude_domains(_Db())
    assert "chase.com" in domains
    assert "paypal.com" in domains


def test_read_gmail_exclude_domains_uses_firestore_doc_when_present(_configured):
    db = _Db()
    db.store[("admin_config", "gmail_exclude_domains")] = {
        "domains": ["MyBank.com", "custom.example"]
    }
    domains = google_account._read_gmail_exclude_domains(db)
    assert domains == ["mybank.com", "custom.example"]


def test_read_gmail_exclude_domains_falls_back_on_read_error(_configured):
    class _BoomDb(_Db):
        def collection(self, name):
            raise RuntimeError("Firestore down")

    domains = google_account._read_gmail_exclude_domains(_BoomDb())
    assert domains == list(google_account._DEFAULT_GMAIL_EXCLUDE_DOMAINS)


def test_gmail_facts_reads_bodies_for_a_small_excluded_filtered_subset(
    monkeypatch, _configured
):
    monkeypatch.setattr(
        google_account, "CONFIG",
        _cfg(google_sync_window_days=30, google_gmail_limit=100,
             google_gmail_body_limit=1),
    )
    db = _Db()
    db.store[("admin_config", "gmail_exclude_domains")] = {"domains": ["chase.com"]}

    listing = {"messages": [{"id": "m1"}, {"id": "m2"}]}
    metas = {
        "m1": {
            "payload": {
                "headers": [
                    {"name": "Subject", "value": "Statement ready"},
                    {"name": "From", "value": "alerts@chase.com"},
                ]
            }
        },
        "m2": {
            "payload": {
                "headers": [
                    {"name": "Subject", "value": "Lunch tomorrow?"},
                    {"name": "From", "value": "Jane <jane@example.com>"},
                ]
            }
        },
    }
    full = {
        "m2": {
            "payload": {
                "mimeType": "text/plain",
                "body": {"data": _b64("Yes! See you at noon.")},
            }
        }
    }

    def _fake_get(url, token):
        assert token == "AT"
        if "/messages?" in url:
            return listing
        for mid, resp in metas.items():
            if f"/messages/{mid}?" in url and "format=metadata" in url:
                return resp
        for mid, resp in full.items():
            if f"/messages/{mid}?" in url and "format=full" in url:
                return resp
        raise AssertionError(f"unexpected url {url}")

    monkeypatch.setattr(google_account, "_get_json_auth", _fake_get)

    lines = google_account._gmail_facts(db, "AT")

    # Every message still gets its cheap metadata line, chase.com included.
    assert any("Statement ready" in l and "chase.com" in l for l in lines)
    assert any("Lunch tomorrow" in l for l in lines)
    # chase.com is on the exclude list -> no body read for m1.
    body_lines = [l for l in lines if l.startswith("Email body")]
    assert len(body_lines) == 1
    assert "chase.com" not in body_lines[0]
    assert "Yes! See you at noon." in body_lines[0]


def test_gmail_facts_body_limit_bounds_the_number_of_body_reads(
    monkeypatch, _configured
):
    monkeypatch.setattr(
        google_account, "CONFIG",
        _cfg(google_sync_window_days=30, google_gmail_limit=100,
             google_gmail_body_limit=1),
    )
    db = _Db()
    listing = {"messages": [{"id": "m1"}, {"id": "m2"}]}

    def _meta(mid, subject):
        return {
            "payload": {
                "headers": [
                    {"name": "Subject", "value": subject},
                    {"name": "From", "value": f"person@example{mid}.com"},
                ]
            }
        }

    full_calls = []

    def _fake_get(url, token):
        if "/messages?" in url:
            return listing
        if "format=metadata" in url:
            mid = "1" if "/messages/m1?" in url else "2"
            return _meta(mid, f"Subject {mid}")
        if "format=full" in url:
            full_calls.append(url)
            return {
                "payload": {
                    "mimeType": "text/plain",
                    "body": {"data": _b64("Body content.")},
                }
            }
        raise AssertionError(f"unexpected url {url}")

    monkeypatch.setattr(google_account, "_get_json_auth", _fake_get)

    lines = google_account._gmail_facts(db, "AT")

    # Both messages get a metadata line, but only google_gmail_body_limit (1)
    # gets a body read.
    assert len(full_calls) == 1
    assert len([l for l in lines if l.startswith("Email body")]) == 1
