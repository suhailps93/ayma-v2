"""dev_flags.py + GET/POST /dev/flags: password check, lockout, the dev_panel
write (and its app_config mirror), and that no other flag can be written."""

from __future__ import annotations

import dataclasses
import logging

import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import dev_flags
import feature_flags as ff
import main
from config import CONFIG

from fake_firestore import FakeDb

client = TestClient(main.app)
SECRET = "correct horse"


@pytest.fixture
def db(monkeypatch):
    store = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: store)
    monkeypatch.setattr(
        dev_flags, "CONFIG", dataclasses.replace(CONFIG, dev_panel_password=SECRET)
    )
    return store


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


def _flags(store) -> dict:
    return store.collection("config").document("feature_flags").get().to_dict() or {}


def test_dev_panel_defaults_on():
    assert ff.resolve("dev_panel") == (True, "default")


def test_correct_password_writes_flag_history_and_mirror(db, monkeypatch):
    r = client.post("/dev/flags", headers=_auth(monkeypatch),
                    json={"password": SECRET, "dev_panel": False})
    assert r.status_code == 200
    assert r.json() == {"dev_panel": False}
    doc = _flags(db)
    assert doc["dev_panel"] is False
    assert doc["_history"][-1]["by"] == "app:me"
    assert doc["_history"][-1]["changed"] == ["dev_panel"]
    mirror = db.collection("app_config").document("dev_panel").get().to_dict()
    assert mirror == {"enabled": False}


def test_wrong_password_is_refused_and_not_logged(db, monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    r = client.post("/dev/flags", headers=_auth(monkeypatch),
                    json={"password": "guess-123", "dev_panel": False})
    assert r.status_code == 403
    assert "dev_panel" not in _flags(db)
    assert "guess-123" not in caplog.text
    assert SECRET not in caplog.text


def test_lockout_after_repeated_failures_even_with_right_password(db, monkeypatch):
    h = _auth(monkeypatch)
    for _ in range(dev_flags.MAX_FAILURES_PER_UID):
        assert client.post("/dev/flags", headers=h,
                           json={"password": "nope", "dev_panel": True}).status_code == 403
    r = client.post("/dev/flags", headers=h, json={"password": SECRET, "dev_panel": True})
    assert r.status_code == 429
    assert int(r.headers["Retry-After"]) > 0
    assert "dev_panel" not in _flags(db)


def test_lockout_expires(db):
    for i in range(dev_flags.MAX_FAILURES_PER_UID):
        with pytest.raises(dev_flags.BadPassword):
            dev_flags.set_dev_panel(db, "u", "x", True, now=1000.0 + i)
    with pytest.raises(dev_flags.LockedOut):
        dev_flags.set_dev_panel(db, "u", SECRET, True, now=1010.0)
    later = 1010.0 + dev_flags.LOCKOUT_SECONDS
    assert dev_flags.set_dev_panel(db, "u", SECRET, True, now=later) is True


def test_global_lockout_across_accounts(db):
    for i in range(dev_flags.MAX_FAILURES_GLOBAL):
        with pytest.raises(dev_flags.BadPassword):
            dev_flags.set_dev_panel(db, f"u{i}", "x", True, now=1000.0)
    with pytest.raises(dev_flags.LockedOut):
        dev_flags.set_dev_panel(db, "fresh", SECRET, True, now=1001.0)


def test_unset_password_fails_closed(monkeypatch):
    store = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: store)
    monkeypatch.setattr(
        dev_flags, "CONFIG", dataclasses.replace(CONFIG, dev_panel_password="")
    )
    r = client.post("/dev/flags", headers=_auth(monkeypatch),
                    json={"password": "", "dev_panel": True})
    assert r.status_code == 422  # empty password rejected before the check
    r = client.post("/dev/flags", headers=_auth(monkeypatch),
                    json={"password": "anything", "dev_panel": True})
    assert r.status_code == 503
    assert _flags(store) == {}


def test_only_dev_panel_can_be_written(db, monkeypatch):
    r = client.post("/dev/flags", headers=_auth(monkeypatch),
                    json={"password": SECRET, "dev_panel": True, "sentry": False})
    assert r.status_code == 422
    r = client.post("/dev/flags", headers=_auth(monkeypatch),
                    json={"password": SECRET, "maps_grounding": False})
    assert r.status_code == 422
    assert _flags(db) == {}


def test_requires_sign_in(db):
    assert client.post("/dev/flags", json={"password": SECRET, "dev_panel": True}).status_code in (401, 403)
    assert client.get("/dev/flags").status_code in (401, 403)


def test_get_returns_the_effective_flag(monkeypatch):
    monkeypatch.setattr(ff, "_read_docs", lambda: {"dev_panel": False})
    ff.reset_cache()
    r = client.get("/dev/flags", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json() == {"dev_panel": False}
