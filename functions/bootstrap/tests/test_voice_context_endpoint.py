"""``/voice/context`` mirror endpoint — the voice agent's ``current_screen``
tool reads what this writes."""

from __future__ import annotations

from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import main

_client = TestClient(main.app)


# --- minimal chainable fake Firestore ----------------------------------

class _Doc:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def collection(self, name):
        return _Col(self.store, (*self.key, name))

    def set(self, patch, merge=False):
        cur = self.store.get(self.key) if merge else None
        self.store[self.key] = {**(cur or {}), **patch}

    def delete(self):
        self.store.pop(self.key, None)


class _Col:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _Doc(self.store, (*self.key, doc_id))


class _Db:
    def __init__(self):
        self.store = {}

    def collection(self, name):
        return _Col(self.store, (name,))


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "me"}
    )
    return {"Authorization": "Bearer valid"}


def test_voice_context_endpoint_writes_and_clears(monkeypatch):
    db = _Db()
    monkeypatch.setattr(main, "get_db", lambda: db)

    r = _client.post(
        "/voice/context",
        headers=_auth(monkeypatch),
        json={"screen": "profile", "subject_name": "Jordan Lee"},
    )
    assert r.status_code == 200 and r.json() == {"ok": True}
    doc = db.store[("users", "me", "voice_context", "current")]
    assert doc["screen"] == "profile" and doc["subject_name"] == "Jordan Lee"
    assert "updated_at" in doc

    r = _client.post(
        "/voice/context", headers=_auth(monkeypatch), json={"screen": ""}
    )
    assert r.json() == {"ok": True, "cleared": True}
    assert ("users", "me", "voice_context", "current") not in db.store


def test_voice_context_delete_endpoint(monkeypatch):
    db = _Db()
    db.store[("users", "me", "voice_context", "current")] = {"screen": "explore"}
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = _client.request(
        "DELETE", "/voice/context", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200
    assert ("users", "me", "voice_context", "current") not in db.store


def test_voice_context_stores_the_screen_detail(monkeypatch):
    db = _Db()
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = _client.post(
        "/voice/context",
        headers=_auth(monkeypatch),
        json={"screen": "explore", "detail": "2 people: Ash, 29; Blake, 30"},
    )
    assert r.status_code == 200
    doc = db.store[("users", "me", "voice_context", "current")]
    assert doc["detail"] == "2 people: Ash, 29; Blake, 30"
    too_long = _client.post(
        "/voice/context",
        headers=_auth(monkeypatch),
        json={"screen": "explore", "detail": "x" * 1501},
    )
    assert too_long.status_code == 422


def test_profile_preferences_endpoint_saves_and_rejects(monkeypatch):
    db = _Db()
    monkeypatch.setattr(main, "get_db", lambda: db)
    ok = _client.put(
        "/profile/preferences",
        headers=_auth(monkeypatch),
        json={"partner_age_min": 25, "partner_age_max": 40,
              "distance_pref": "100"},
    )
    assert ok.status_code == 200 and len(ok.json()["recorded"]) == 4
    mirror = db.store[("users", "me", "profile", "main")]
    assert mirror["qz_partner_age_min"] == 25
    assert mirror["qz_partner_age_max"] == 40
    bad = _client.put(
        "/profile/preferences",
        headers=_auth(monkeypatch),
        json={"partner_age_min": 50, "partner_age_max": 30},
    )
    assert bad.status_code == 422
    under = _client.put(
        "/profile/preferences",
        headers=_auth(monkeypatch),
        json={"partner_age_min": 17, "partner_age_max": 30},
    )
    assert under.status_code == 422
