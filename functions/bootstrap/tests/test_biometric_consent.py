"""Mandatory biometric (face-matching) consent: the record + its validation,
the app-wide endpoint gate, the consent endpoints, withdrawal (face data then
account), and the face-processing gates for a user without consent."""

import asyncio

import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import biometric_consent
import deep_dive_images
import face_match
import main
import media_embed
import reverse_image_search
from fake_firestore import DELETE_FIELD, SERVER_TIMESTAMP, FakeDb

client = TestClient(main.app)
V = biometric_consent.CONSENT_VERSION


@pytest.fixture(autouse=True)
def _fresh_cache(monkeypatch):
    monkeypatch.setattr(biometric_consent, "_ok_until", {})
    monkeypatch.setattr(biometric_consent.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
    monkeypatch.setattr(biometric_consent.firestore, "DELETE_FIELD", DELETE_FIELD)


def _auth(monkeypatch, uid="u-1"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer t"}


def _user(db, uid="u-1"):
    return db.docs.get(("users", uid), {})


# --- record / has_consent -----------------------------------------------------


@pytest.mark.real_biometric_consent
def test_no_record_means_no_consent():
    assert biometric_consent.has_consent(FakeDb(), "u-1") is False
    assert biometric_consent.has_consent(FakeDb(), "") is False


@pytest.mark.real_biometric_consent
def test_record_then_has_consent():
    db = FakeDb()
    biometric_consent.record(db, "u-1", agreed=True, version=V, region="us")
    rec = _user(db)["biometric_consent"]
    assert rec["consent_version"] == V
    assert rec["region"] == "US"
    assert rec["source"] == "app"
    assert rec["consented_at"] is SERVER_TIMESTAMP
    assert biometric_consent.has_consent(db, "u-1") is True


@pytest.mark.parametrize(
    "kwargs",
    [
        {"agreed": False, "version": V},
        {"agreed": True, "version": "1999-01-01"},
        {"agreed": True, "version": V, "region": "California"},
        {"agreed": True, "version": V, "source": "client"},
    ],
)
def test_record_rejects_invalid_requests(kwargs):
    db = FakeDb()
    with pytest.raises(biometric_consent.ConsentError):
        biometric_consent.record(db, "u-1", **kwargs)
    assert "biometric_consent" not in _user(db)


@pytest.mark.real_biometric_consent
def test_stale_version_or_withdrawn_record_is_not_consent():
    db = FakeDb({("users", "u-1"): {"biometric_consent": {
        "consented_at": 1, "consent_version": "2000-01-01"}}})
    assert biometric_consent.has_consent(db, "u-1") is False
    db.docs[("users", "u-2")] = {"biometric_consent": {
        "consented_at": 1, "consent_version": V, "withdrawn_at": 2}}
    assert biometric_consent.has_consent(db, "u-2") is False


@pytest.mark.real_biometric_consent
def test_read_failure_fails_closed():
    class _Boom:
        def collection(self, _n):
            raise RuntimeError("down")

    assert biometric_consent.has_consent(_Boom(), "u-1") is False


@pytest.mark.real_biometric_consent
def test_fresh_consent_clears_an_old_withdrawal():
    db = FakeDb({("users", "u-1"): {"biometric_consent": {
        "consent_version": V, "withdrawn_at": 2}}})
    biometric_consent.record(db, "u-1", agreed=True, version=V)
    assert "withdrawn_at" not in _user(db)["biometric_consent"]
    assert biometric_consent.has_consent(db, "u-1") is True


# --- delete_face_data / withdraw ---------------------------------------------


class _Bucket:
    def __init__(self):
        self.deleted = []

    def blob(self, path):
        bucket = self

        class _Blob:
            def delete(self):
                bucket.deleted.append(path)

        return _Blob()


def _seed_face_data(db, uid="u-1"):
    db.docs[("users", uid)] = {
        "biometric_consent": {"consented_at": 1, "consent_version": V},
        "face_verification": {
            "embedding": [0.1], "storage_path": f"verification/{uid}/s.jpg"},
    }
    db.docs[("users", uid, "user_media", "m1")] = {
        "storage_path": "uploads/x.jpg", "embedding": [0.1], "dim": 1}
    db.docs[("users", uid, "photo_notes", "p1")] = {
        "url": "u", "embedding": [0.2], "is_user": "self", "context": "c"}
    db.docs[("users", uid, "web_photo_candidates", "c1")] = {"image_url": "x"}


def test_delete_face_data_removes_every_face_artifact():
    db, bucket = FakeDb(), _Bucket()
    _seed_face_data(db)
    out = biometric_consent.delete_face_data(db, bucket, "u-1")
    assert "face_verification" not in _user(db)
    assert bucket.deleted == ["verification/u-1/s.jpg"]
    assert db.docs[("users", "u-1", "user_media", "m1")] == {
        "storage_path": "uploads/x.jpg"}
    assert db.docs[("users", "u-1", "photo_notes", "p1")] == {
        "url": "u", "context": "c"}
    assert ("users", "u-1", "web_photo_candidates", "c1") not in db.docs
    assert out["media_embeddings_deleted"] == 1
    assert out["web_photo_candidates_deleted"] == 1


@pytest.mark.real_biometric_consent
def test_withdraw_deletes_face_data_then_the_account(monkeypatch):
    db, bucket = FakeDb(), _Bucket()
    _seed_face_data(db)
    seen = {}

    def _soft_delete(d, b, uid):
        seen["user_at_delete"] = dict(d.docs[("users", uid)])
        d.docs.pop(("users", uid))
        return {"deleted": True}

    monkeypatch.setattr(biometric_consent.account_ops, "soft_delete", _soft_delete)
    out = biometric_consent.withdraw(db, bucket, "u-1")
    assert out["withdrawn"] is True and out["account"] == {"deleted": True}
    user_at_delete = seen["user_at_delete"]
    assert "face_verification" not in user_at_delete
    assert user_at_delete["biometric_consent"]["withdrawn_at"] is SERVER_TIMESTAMP
    assert biometric_consent.has_consent(db, "u-1") is False


# --- app-wide endpoint gate ---------------------------------------------------


def test_feature_endpoint_refuses_without_consent(monkeypatch):
    monkeypatch.setattr(biometric_consent, "has_consent", lambda _db, _uid: False)
    resp = client.get("/verification/status", headers=_auth(monkeypatch))
    assert resp.status_code == 403
    assert resp.json()["detail"]["code"] == "biometric_consent_required"
    assert resp.headers["x-ayma-consent-required"] == "1"


def test_feature_endpoint_routes_a_soft_deleted_account_to_recovery(monkeypatch):
    # B9 PART-1 repro: a soft-deleted account has no consent record, so the gate
    # used to answer "consent required" — stranding the app on the consent
    # screen, which then refuses to record consent (409), a dead end. It must
    # answer "recovery required" so the client routes to the recovery screen.
    monkeypatch.setattr(biometric_consent, "has_consent", lambda _db, _uid: False)
    monkeypatch.setattr(main, "_recovery_required", lambda _uid: True)
    resp = client.get("/verification/status", headers=_auth(monkeypatch))
    assert resp.status_code == 403
    assert resp.json()["detail"]["code"] == "recovery_required"
    assert resp.headers["x-ayma-recovery-required"] == "1"
    assert "x-ayma-consent-required" not in resp.headers


def test_feature_endpoint_allowed_with_consent(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: FakeDb())
    resp = client.get("/verification/status", headers=_auth(monkeypatch))
    assert resp.status_code == 200


def test_gate_leaves_unauthenticated_calls_to_the_route():
    assert client.get("/verification/status").status_code in (401, 403)
    assert client.get("/health").status_code == 200


def test_bootstrap_reports_consent_required(monkeypatch):
    monkeypatch.setattr(biometric_consent, "has_consent", lambda _db, _uid: False)
    monkeypatch.setattr(main, "_session_mode", lambda _c: "interview")
    resp = client.post("/bootstrap", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json() == {
        "biometric_consent_required": True,
        "session_mode": "interview",
        "uid": "u-1",
    }


def test_exempt_routes_work_without_consent(monkeypatch):
    monkeypatch.setattr(biometric_consent, "has_consent", lambda _db, _uid: False)
    monkeypatch.setattr(main, "get_db", lambda: FakeDb())
    resp = client.get("/biometric-consent", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json()["consented"] is False
    assert resp.json()["current_version"] == V
    resp = client.post(
        "/age-gate/declare", json={"birthdate": "1990-01-01"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200


# --- consent endpoints -------------------------------------------------------


def test_consent_endpoint_records_a_valid_agreement(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    resp = client.post(
        "/biometric-consent",
        json={"agreed": True, "consent_version": V, "region": "gb"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    assert resp.json()["consented"] is True
    assert _user(db)["biometric_consent"]["region"] == "GB"


@pytest.mark.parametrize(
    "body",
    [
        {"agreed": False, "consent_version": V},
        {"agreed": True, "consent_version": "old"},
        {"agreed": True, "consent_version": V, "region": "1"},
    ],
)
def test_consent_endpoint_rejects_invalid(monkeypatch, body):
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    resp = client.post("/biometric-consent", json=body, headers=_auth(monkeypatch))
    assert resp.status_code == 400
    assert "biometric_consent" not in _user(db)


def test_consent_endpoint_refuses_a_soft_deleted_account(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main, "_recovery_required", lambda _uid: True)
    resp = client.post(
        "/biometric-consent",
        json={"agreed": True, "consent_version": V},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 409
    assert ("users", "u-1") not in db.docs
    # The 409 carries the recovery header so the client's HTTP layer routes to
    # the recovery screen instead of showing a misleading connection error (B9).
    assert resp.headers["x-ayma-recovery-required"] == "1"


def test_consent_endpoint_rejects_missing_fields(monkeypatch):
    resp = client.post(
        "/biometric-consent", json={"agreed": True}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 422


def test_withdraw_endpoint(monkeypatch):
    seen = {}

    def _withdraw(db, bucket, uid):
        seen["uid"] = uid
        return {"withdrawn": True}

    monkeypatch.setattr(biometric_consent, "withdraw", _withdraw)
    monkeypatch.setattr(main, "_bucket", lambda: object())
    resp = client.post("/biometric-consent/withdraw", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json() == {"ok": True, "withdrawn": True}
    assert seen["uid"] == "u-1"


def test_selfie_refused_without_consent(monkeypatch):
    calls = []
    monkeypatch.setattr(biometric_consent, "has_consent", lambda _db, _uid: False)
    monkeypatch.setattr(main, "_CONSENT_EXEMPT_PATHS",
                        main._CONSENT_EXEMPT_PATHS | {"/verification/selfie"})
    monkeypatch.setattr(media_embed, "download_bytes", lambda p: calls.append(p))
    resp = client.post(
        "/verification/selfie",
        json={"storage_path": "verification/u-1/s.jpg"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 403
    assert resp.json()["detail"]["code"] == "biometric_consent_required"
    assert calls == []


# --- face-processing gates ---------------------------------------------------


def test_no_reference_embeddings_without_consent(monkeypatch):
    monkeypatch.setattr(biometric_consent, "has_consent_fresh", lambda _db, _uid: False)
    db = FakeDb({("users", "u-1"): {"face_verification": {"verified": True, "storage_path": "users/u-1/selfie.jpg"}}})
    assert face_match.get_reference_photos(db, "u-1") == []


def test_web_images_skip_a_target_without_consent(monkeypatch):
    monkeypatch.setattr(biometric_consent, "has_consent_fresh", lambda _db, _uid: False)

    def _never(*_a, **_k):
        raise AssertionError("must not search or check face")

    monkeypatch.setattr(deep_dive_images, "_search_image_urls", _never)
    monkeypatch.setattr(face_match, "check_same_person", _never)
    out = asyncio.run(
        deep_dive_images.find_web_images(FakeDb(), "u-2", "Dana Reyes")
    )
    assert out == []


def test_web_images_need_an_ayma_target():
    out = asyncio.run(deep_dive_images.find_web_images(FakeDb(), "", "Dana"))
    assert out == []


def test_auto_scan_waits_for_consent(monkeypatch):
    monkeypatch.setattr(biometric_consent, "has_consent_fresh", lambda _db, _uid: False)

    async def _never(*_a, **_k):
        raise AssertionError("must not scan")

    monkeypatch.setattr(reverse_image_search, "scan", _never)
    db = FakeDb()
    asyncio.run(reverse_image_search.auto_scan(db, "u-1"))
    assert "web_photo_scan_done" not in _user(db)


# --- withdrawal is immediately effective across instances ---------------------


@pytest.mark.real_biometric_consent
def test_fresh_check_sees_a_withdrawal_the_cache_has_not():
    db = FakeDb()
    biometric_consent.record(db, "u-1", agreed=True, version=V)
    assert biometric_consent.has_consent(db, "u-1") is True  # cached positive
    # Another instance withdraws: only the user doc changes.
    db.docs[("users", "u-1")]["biometric_consent"]["withdrawn_at"] = 5
    assert biometric_consent.has_consent(db, "u-1") is True  # stale cache
    assert biometric_consent.has_consent_fresh(db, "u-1") is False
    assert biometric_consent.has_consent(db, "u-1") is False  # cache dropped


@pytest.mark.real_biometric_consent
def test_fresh_check_fails_closed_and_ignores_cache(monkeypatch):
    db = FakeDb()
    biometric_consent.record(db, "u-1", agreed=True, version=V)
    assert biometric_consent.has_consent(db, "u-1") is True

    class _Boom:
        def collection(self, _n):
            raise RuntimeError("down")

    assert biometric_consent.has_consent_fresh(_Boom(), "u-1") is False
    assert biometric_consent.has_consent_fresh(db, "") is False
    assert biometric_consent.has_consent_fresh(None, "u-1") is False


def test_positive_cache_is_short():
    assert biometric_consent._OK_TTL_SECONDS <= 30.0


def test_web_images_stop_when_consent_is_withdrawn_mid_job(monkeypatch):
    answers = iter([True, False])
    monkeypatch.setattr(
        biometric_consent, "has_consent_fresh", lambda _db, _uid: next(answers)
    )
    monkeypatch.setattr(
        deep_dive_images, "_search_image_urls",
        lambda q, n: [{"url": "https://img.example/a.jpg"}],
    )

    def _never(*_a, **_k):
        raise AssertionError("must not fetch or check face after withdrawal")

    monkeypatch.setattr(deep_dive_images, "_fetch_image", _never)
    monkeypatch.setattr(face_match, "check_same_person", _never)
    out = asyncio.run(
        deep_dive_images.find_web_images(FakeDb(), "u-2", "Dana Reyes")
    )
    assert out == []
