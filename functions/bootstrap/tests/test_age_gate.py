"""The authoritative 18+ gate: age arithmetic, closing under-18 accounts, the
endpoint dependencies, and the non-recoverable close."""

from datetime import date, datetime, timedelta, timezone

import pytest
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import account_ops
import age_gate
from fake_firestore import DELETE_FIELD, SERVER_TIMESTAMP, FakeDb

# conftest patches age_gate.enforce to a no-op for every other test file.
REAL_ENFORCE = age_gate.enforce

client = TestClient(main.app)


@pytest.fixture(autouse=True)
def _real_gate(monkeypatch):
    monkeypatch.setattr(age_gate, "enforce", REAL_ENFORCE)
    for mod in (age_gate.firestore, account_ops.firestore):
        monkeypatch.setattr(mod, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
        monkeypatch.setattr(mod, "DELETE_FIELD", DELETE_FIELD)
    age_gate.clear_cache()
    yield
    age_gate.clear_cache()


def _years_ago(years, today=None, days=0):
    t = today or age_gate.today_utc()
    return date(t.year - years, t.month, t.day) - timedelta(days=days)


def _db(uid, birthdate="__none__"):
    db = FakeDb()
    db.docs[("users", uid)] = {"created_at": 1}
    prof = {"name": "Jo"}
    if birthdate != "__none__":
        prof["birthdate"] = birthdate
    db.docs[("users", uid, "profile", "main")] = prof
    return db


def test_age_boundaries():
    today = date(2026, 6, 15)
    assert age_gate.age_on(date(2008, 6, 15), today) == 18
    assert age_gate.age_on(date(2008, 6, 16), today) == 17
    assert age_gate.is_adult("2008-06-15", today)
    assert not age_gate.is_adult("2008-06-16", today)


def test_leap_day_birthday():
    bd = date(2008, 2, 29)
    assert age_gate.age_on(bd, date(2026, 2, 28)) == 17
    assert age_gate.age_on(bd, date(2026, 3, 1)) == 18
    assert age_gate.age_on(bd, date(2028, 2, 29)) == 20


def test_timestamps_read_as_their_utc_date():
    # 23:30 at UTC-5 on 2008-03-01 is already 2008-03-02 in UTC.
    ts = datetime.fromisoformat("2008-03-01T23:30:00-05:00")
    assert age_gate.to_date(ts) == date(2008, 3, 2)
    assert age_gate.to_date(datetime(2000, 1, 1)) == date(2000, 1, 1)
    assert age_gate.to_date("2000-01-01T00:00:00Z") == date(2000, 1, 1)


@pytest.mark.parametrize("bad", [None, "", "  ", "not a date", 12, {}, []])
def test_unparseable_is_not_adult(bad):
    assert age_gate.to_date(bad) is None
    assert not age_gate.is_adult(bad)
    assert age_gate.status({"birthdate": bad}) == age_gate.STATUS_MISSING


def test_future_birthdate_is_not_adult():
    future = (age_gate.today_utc() + timedelta(days=1)).isoformat()
    assert age_gate.status({"birthdate": future}) == age_gate.STATUS_UNDERAGE


def test_enforce_passes_adult_and_allows_missing_when_not_required():
    db = _db("a", datetime(1990, 1, 1, tzinfo=timezone.utc))
    REAL_ENFORCE(db, lambda: None, "a", require_birthdate=True)
    nb = _db("b")
    REAL_ENFORCE(nb, lambda: None, "b", require_birthdate=False)
    with pytest.raises(age_gate.AgeGateError) as e:
        REAL_ENFORCE(nb, lambda: None, "b", require_birthdate=True)
    assert e.value.code == "birthdate_required"


def test_enforce_closes_underage_and_blocks_afterwards(caplog):
    db = _db("m", _years_ago(17).isoformat())
    with caplog.at_level("WARNING", logger="ayma.age_gate"):
        with pytest.raises(age_gate.AgeGateError) as e:
            REAL_ENFORCE(db, lambda: None, "m", require_birthdate=False)
    assert e.value.code == "underage"
    assert "underage account closed uid=m" in caplog.text
    # live account quarantined, flagged unrecoverable
    assert ("users", "m") not in db.docs
    closed = db.docs[("deleted_accounts", "m")]
    assert closed["closed_reason"] == "underage"
    # even a freshly re-created adult-looking profile stays blocked
    db.docs[("users", "m", "profile", "main")] = {"birthdate": "1990-01-01"}
    with pytest.raises(age_gate.AgeGateError):
        REAL_ENFORCE(db, lambda: None, "m", require_birthdate=False)


def test_underage_by_one_day_is_closed_and_exactly_18_is_not():
    just_under = _db("u", _years_ago(18, days=-1).isoformat())
    with pytest.raises(age_gate.AgeGateError):
        REAL_ENFORCE(just_under, lambda: None, "u", require_birthdate=True)
    exactly = _db("v", _years_ago(18).isoformat())
    REAL_ENFORCE(exactly, lambda: None, "v", require_birthdate=True)


def test_recover_refuses_underage_closure():
    db = _db("m", _years_ago(16).isoformat())
    with pytest.raises(age_gate.AgeGateError):
        REAL_ENFORCE(db, lambda: None, "m", require_birthdate=True)
    out = account_ops.recover(db, None, "m")
    assert out == {"restored": False, "reason": "underage"}
    assert ("users", "m") not in db.docs


def _auth(monkeypatch, uid="u1"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def _wire(monkeypatch, db):
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main, "_bucket", lambda: None)


def test_explore_blocked_for_underage_and_for_missing_birthdate(monkeypatch):
    h = _auth(monkeypatch, "m")
    _wire(monkeypatch, _db("m", _years_ago(15).isoformat()))
    r = client.get("/explore", headers=h)
    assert r.status_code == 403
    assert r.json()["detail"]["code"] == "underage"

    _wire(monkeypatch, _db("m2"))
    h = _auth(monkeypatch, "m2")
    r = client.get("/explore", headers=h)
    assert r.status_code == 403
    assert r.json()["detail"]["code"] == "birthdate_required"


def test_run_matching_and_dm_blocked_for_underage(monkeypatch):
    h = _auth(monkeypatch, "m")
    _wire(monkeypatch, _db("m", _years_ago(15).isoformat()))
    assert client.post("/run-matching", headers=h).status_code == 403
    age_gate.clear_cache()
    assert client.post(
        "/dm/t1/messages", headers=h, json={"text": "hi"}
    ).status_code == 403


def test_chat_blocks_underage(monkeypatch):
    h = _auth(monkeypatch, "m")
    _wire(monkeypatch, _db("m", _years_ago(15).isoformat()))
    r = client.post("/chat", headers=h, json={"message": "hi"})
    assert r.status_code == 403
    assert r.json()["detail"]["code"] == "underage"


def test_bootstrap_reports_age_block(monkeypatch):
    h = _auth(monkeypatch, "m")
    _wire(monkeypatch, _db("m", _years_ago(15).isoformat()))
    r = client.post("/bootstrap", headers=h)
    assert r.status_code == 200
    assert r.json()["age_blocked"] is True
    assert r.json()["code"] == "underage"


def test_declare_under_18_closes_account(monkeypatch):
    h = _auth(monkeypatch, "m")
    db = _db("m")
    _wire(monkeypatch, db)
    r = client.post(
        "/age-gate/declare", headers=h,
        json={"birthdate": _years_ago(14).isoformat()},
    )
    assert r.status_code == 200 and r.json()["adult"] is False
    assert db.docs[("deleted_accounts", "m")]["closed_reason"] == "underage"


def test_declare_adult_is_a_no_op_and_bad_date_is_400(monkeypatch):
    h = _auth(monkeypatch, "m")
    db = _db("m")
    _wire(monkeypatch, db)
    r = client.post(
        "/age-gate/declare", headers=h,
        json={"birthdate": _years_ago(30).isoformat()},
    )
    assert r.json() == {"ok": True, "adult": True}
    assert ("users", "m") in db.docs
    assert client.post(
        "/age-gate/declare", headers=h, json={"birthdate": "soon"}
    ).status_code == 400


def test_account_recover_endpoint_403_for_underage(monkeypatch):
    h = _auth(monkeypatch, "m")
    db = _db("m", _years_ago(15).isoformat())
    with pytest.raises(age_gate.AgeGateError):
        REAL_ENFORCE(db, lambda: None, "m", require_birthdate=True)
    _wire(monkeypatch, db)
    monkeypatch.setattr(main, "_recovery_required", lambda _u: True)
    r = client.post("/account/recover", headers=h)
    assert r.status_code == 403
