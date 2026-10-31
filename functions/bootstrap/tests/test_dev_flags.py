"""dev_flags.py + POST /dev/verify: password check and the per-account /
per-address / global lockout that guards the Developer-panel unlock."""

from __future__ import annotations

import dataclasses
import logging

import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import dev_flags
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


def test_lockout_expires(db):
    for i in range(dev_flags.MAX_FAILURES_PER_UID):
        with pytest.raises(dev_flags.BadPassword):
            dev_flags.verify(db, "u", "x", now=1000.0 + i)
    with pytest.raises(dev_flags.LockedOut):
        dev_flags.verify(db, "u", SECRET, now=1010.0)
    later = 1010.0 + dev_flags.LOCKOUT_SECONDS
    assert dev_flags.verify(db, "u", SECRET, now=later) is True


def test_one_account_lockout_does_not_lock_others(db):
    for i in range(dev_flags.MAX_FAILURES_PER_UID):
        with pytest.raises(dev_flags.BadPassword):
            dev_flags.verify(db, "attacker", "x", ip="1.1.1.1", now=1000.0 + i)
    with pytest.raises(dev_flags.LockedOut):
        dev_flags.verify(db, "attacker", SECRET, ip="9.9.9.9", now=1010.0)
    assert dev_flags.verify(db, "other", SECRET, ip="2.2.2.2", now=1011.0) is True


def test_ip_lockout_across_accounts_spares_other_ips(db):
    for i in range(dev_flags.MAX_FAILURES_PER_IP):
        with pytest.raises(dev_flags.BadPassword):
            dev_flags.verify(db, f"u{i}", "x", ip="1.1.1.1", now=1000.0)
    with pytest.raises(dev_flags.LockedOut) as exc:
        dev_flags.verify(db, "fresh", SECRET, ip="1.1.1.1", now=1001.0)
    assert exc.value.retry_after > 0
    assert dev_flags.verify(db, "fresh", SECRET, ip="3.3.3.3", now=1001.0) is True
    later = 1001.0 + dev_flags.LOCKOUT_SECONDS
    assert dev_flags.verify(db, "fresh", SECRET, ip="1.1.1.1", now=later) is True


def test_ip_is_hashed_not_stored(db):
    with pytest.raises(dev_flags.BadPassword):
        dev_flags.verify(db, "u", "x", ip="203.0.113.7", now=1000.0)
    ids = [k[1] for k in db.docs if k[0] == dev_flags.ATTEMPTS_COLLECTION]
    assert not any("203.0.113.7" in i for i in ids)
    assert any(i.startswith("ip_") for i in ids)


def test_a_few_clients_cannot_trip_the_global_limit(db):
    # 5 clients, each fully exhausting its own account and IP budgets
    for c in range(5):
        for i in range(dev_flags.MAX_FAILURES_PER_IP):
            with pytest.raises((dev_flags.BadPassword, dev_flags.LockedOut)):
                dev_flags.verify(
                    db, f"c{c}u{i}", "x", ip=f"10.0.0.{c}", now=1000.0
                )
    assert dev_flags.verify(db, "innocent", SECRET, ip="8.8.8.8", now=1001.0) is True


def test_global_ceiling_stops_a_distributed_run_then_expires(db):
    for i in range(dev_flags.MAX_FAILURES_GLOBAL):
        with pytest.raises(dev_flags.BadPassword):
            dev_flags.verify(db, f"u{i}", "x", ip=f"10.1.{i // 250}.{i % 250}", now=1000.0)
    with pytest.raises(dev_flags.LockedOut):
        dev_flags.verify(db, "fresh", SECRET, ip="8.8.8.8", now=1001.0)
    later = 1000.0 + dev_flags.LOCKOUT_SECONDS + 1
    assert dev_flags.verify(db, "fresh", SECRET, ip="8.8.8.8", now=later) is True


def test_global_window_resets_between_windows(db):
    for i in range(dev_flags.MAX_FAILURES_GLOBAL - 1):
        with pytest.raises(dev_flags.BadPassword):
            dev_flags.verify(db, f"u{i}", "x", ip=f"10.1.{i // 250}.{i % 250}", now=1000.0)
    later = 1000.0 + dev_flags.LOCKOUT_SECONDS + 5
    with pytest.raises(dev_flags.BadPassword):
        dev_flags.verify(db, "late", "x", ip="7.7.7.7", now=later)
    assert dev_flags.verify(db, "fresh", SECRET, ip="8.8.8.8", now=later + 1) is True


def test_endpoint_uses_the_rightmost_forwarded_address(db, monkeypatch):
    h = {**_auth(monkeypatch), "X-Forwarded-For": "6.6.6.6, 1.2.3.4"}
    uids = iter(range(99))
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": f"u{next(uids)}"}
    )
    for _ in range(dev_flags.MAX_FAILURES_PER_IP):
        client.post("/dev/verify", headers=h, json={"password": "x"})
    spoofed = {**h, "X-Forwarded-For": "5.5.5.5, 1.2.3.4"}
    r = client.post("/dev/verify", headers=spoofed, json={"password": SECRET})
    assert r.status_code == 429


def test_verify_correct_password_ok_and_writes_no_flag(db, monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    r = client.post("/dev/verify", headers=_auth(monkeypatch),
                    json={"password": SECRET})
    assert r.status_code == 200
    assert r.json() == {"ok": True}
    # Unlock never touches any feature flag.
    assert _flags(db) == {}
    assert SECRET not in caplog.text


def test_verify_wrong_password_is_refused_and_not_logged(db, monkeypatch, caplog):
    caplog.set_level(logging.DEBUG)
    r = client.post("/dev/verify", headers=_auth(monkeypatch),
                    json={"password": "guess-123"})
    assert r.status_code == 403
    assert _flags(db) == {}
    assert "guess-123" not in caplog.text
    assert SECRET not in caplog.text


def test_verify_locks_out_after_repeated_failures(db, monkeypatch):
    h = _auth(monkeypatch)
    for _ in range(dev_flags.MAX_FAILURES_PER_UID):
        assert client.post("/dev/verify", headers=h,
                           json={"password": "nope"}).status_code == 403
    r = client.post("/dev/verify", headers=h, json={"password": SECRET})
    assert r.status_code == 429
    assert int(r.headers["Retry-After"]) > 0


def test_verify_unset_password_fails_closed(monkeypatch):
    store = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: store)
    monkeypatch.setattr(
        dev_flags, "CONFIG", dataclasses.replace(CONFIG, dev_panel_password="")
    )
    r = client.post("/dev/verify", headers=_auth(monkeypatch),
                    json={"password": "anything"})
    assert r.status_code == 503


def test_verify_empty_password_rejected_before_check(monkeypatch):
    r = client.post("/dev/verify", headers=_auth(monkeypatch), json={"password": ""})
    assert r.status_code == 422


def test_verify_requires_sign_in(db):
    assert client.post("/dev/verify", json={"password": SECRET}).status_code in (401, 403)
