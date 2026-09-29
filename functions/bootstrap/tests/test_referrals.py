"""Referral codes + attribution (referrals.py, GET /referral,
POST /referral/redeem)."""

import re

import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import main
import referrals
from fake_firestore import SERVER_TIMESTAMP, FakeDb

client = TestClient(main.app)


@pytest.fixture(autouse=True)
def _sentinel_ts(monkeypatch):
    monkeypatch.setattr(
        referrals.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP
    )


# --- code generation --------------------------------------------------------


def test_code_is_stable_and_readable():
    db = FakeDb()
    code = referrals.code_for(db, "user-a")
    assert re.fullmatch(f"[{referrals.CODE_ALPHABET}]{{7}}", code)
    # Same code every subsequent call — never re-minted.
    assert referrals.code_for(db, "user-a") == code
    # Stored on the user doc + the global lookup points back at the user.
    assert db.docs[("users", "user-a")]["referral_code"] == code
    assert db.docs[("referral_codes", code)]["uid"] == "user-a"


def test_codes_differ_between_users():
    db = FakeDb()
    assert referrals.code_for(db, "user-a") != referrals.code_for(db, "user-b")


def test_collision_rehashes_instead_of_stealing():
    db = FakeDb()
    clash = referrals._candidate("user-a", 0)
    db.docs[("referral_codes", clash)] = {"uid": "someone-else"}
    code = referrals.code_for(db, "user-a")
    assert code != clash
    assert code == referrals._candidate("user-a", 1)
    assert db.docs[("referral_codes", clash)]["uid"] == "someone-else"


def test_partial_write_recovers_the_same_code():
    # Crash between claiming the lookup and mirroring onto users/{uid}: the
    # next call must finish with the already-claimed code, not mint another.
    db = FakeDb()
    claimed = referrals._candidate("user-a", 0)
    db.docs[("referral_codes", claimed)] = {"uid": "user-a"}
    assert referrals.code_for(db, "user-a") == claimed
    assert db.docs[("users", "user-a")]["referral_code"] == claimed


def test_link_carries_the_code():
    assert referrals.link_for("ABC2345").endswith("/r/ABC2345")


# --- redeem / attribution ---------------------------------------------------


def _seeded_db():
    db = FakeDb()
    code = referrals.code_for(db, "referrer-1")
    return db, code


def test_redeem_records_attribution_once():
    db, code = _seeded_db()
    assert referrals.redeem(db, "newbie", code) is True
    user = db.docs[("users", "newbie")]
    assert user["referred_by"] == "referrer-1"
    assert user["referred_code"] == code
    assert user["referred_at"] is SERVER_TIMESTAMP
    assert ("users", "referrer-1", "referrals", "newbie") in db.docs

    # Second redeem — same or another code — is a silent no-op.
    assert referrals.redeem(db, "newbie", code) is False
    other = referrals.code_for(db, "referrer-2")
    assert referrals.redeem(db, "newbie", other) is False
    assert db.docs[("users", "newbie")]["referred_by"] == "referrer-1"
    referral_rows = [
        k for k in db.docs if len(k) == 4 and k[2] == "referrals"
    ]
    assert referral_rows == [("users", "referrer-1", "referrals", "newbie")]


def test_redeem_rejects_self_referral():
    db, code = _seeded_db()
    assert referrals.redeem(db, "referrer-1", code) is False
    assert "referred_by" not in db.docs[("users", "referrer-1")]


def test_redeem_rejects_unknown_or_garbage_codes():
    db = FakeDb()
    assert referrals.redeem(db, "newbie", "ZZZZZZZ") is False
    assert referrals.redeem(db, "newbie", "") is False
    assert referrals.redeem(db, "newbie", "!!bad!!") is False
    assert ("users", "newbie") not in db.docs


def test_redeem_normalizes_pasted_links_and_case():
    db, code = _seeded_db()
    pasted = f"https://ayma-ai.web.app/r/{code.lower()}"
    assert referrals.redeem(db, "newbie", pasted) is True
    assert db.docs[("users", "newbie")]["referred_by"] == "referrer-1"


# --- endpoints --------------------------------------------------------------


def _auth(monkeypatch, uid="u-ref"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def test_referral_endpoints_require_auth():
    assert client.get("/referral").status_code in (401, 403)
    assert (
        client.post("/referral/redeem", json={"code": "ABC2345"}).status_code
        in (401, 403)
    )


def test_get_referral_returns_code_and_link(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    resp = client.get("/referral", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    body = resp.json()
    assert body["code"] == db.docs[("users", "u-ref")]["referral_code"]
    assert body["link"] == referrals.link_for(body["code"])

    # Stable across calls.
    again = client.get("/referral", headers=_auth(monkeypatch)).json()
    assert again == body


def test_post_redeem_applies_and_reports(monkeypatch):
    db = FakeDb()
    code = referrals.code_for(db, "referrer-9")
    monkeypatch.setattr(main, "get_db", lambda: db)
    headers = _auth(monkeypatch, uid="fresh-uid")

    resp = client.post("/referral/redeem", json={"code": code}, headers=headers)
    assert resp.status_code == 200
    assert resp.json() == {"applied": True}
    assert db.docs[("users", "fresh-uid")]["referred_by"] == "referrer-9"

    # Bad code: still 200, silently not applied.
    resp = client.post(
        "/referral/redeem", json={"code": "NOPE234"}, headers=headers
    )
    assert resp.status_code == 200
    assert resp.json() == {"applied": False}
