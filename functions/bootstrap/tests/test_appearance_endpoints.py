import dataclasses

import appearance
import auth
import main
import photo_attrs
from config import CONFIG
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)

_SECRET = "cron-secret-abcdefghijklmnop"


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


def _with_secret(monkeypatch, value=_SECRET):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, cron_secret=value)
    )


_REPORT = {
    "id": "a1", "created_at": None,
    "attributes": {"record": {}, "summary": "Physical profile — eyes: brown."},
    "face": {"usable": True, "overall_score": 7.0},
    "body": {"status": "needs_body_photo"},
    "photo_count": 3, "model": "gemini", "source": "endpoint",
}


# --- auth ---------------------------------------------------------------------


def test_endpoints_require_auth():
    assert client.post("/appearance/report").status_code in (401, 403)
    assert client.get("/appearance/report/current").status_code in (401, 403)
    assert client.get("/appearance/history").status_code in (401, 403)
    assert client.get("/appearance/coverage").status_code in (401, 403)


# --- POST /appearance/report -----------------------------------------------


def test_report_run_returns_report_and_id(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    seen = {}

    async def _run(db, uid, *, extra_images=None, want_face=True, want_body=True,
                   source="user"):
        seen.update(uid=uid, want_face=want_face, want_body=want_body,
                    source=source)
        return dict(_REPORT)

    monkeypatch.setattr(appearance, "run_appearance", _run)

    resp = client.post(
        "/appearance/report",
        json={"want_face": True, "want_body": False},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["report_id"] == "a1"
    assert body["report"]["face"]["overall_score"] == 7.0
    assert seen == {"uid": "u1", "want_face": True, "want_body": False,
                    "source": "endpoint"}


def test_report_run_400_without_a_photo(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)

    async def _none(*a, **k):
        return None

    monkeypatch.setattr(appearance, "run_appearance", _none)
    resp = client.post("/appearance/report", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 400


def test_report_run_reports_usage_capped(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    def _boom(uid):
        raise main.token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(main.token_ledger, "check", _boom)
    resp = client.post("/appearance/report", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 200 and resp.json() == {"usage_capped": True}


def test_report_run_rejects_a_foreign_attachment(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/appearance/report",
        json={"image_paths": ["uploads/someone-else/x.jpg"]},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 403


# --- GET /appearance/report/{id} -----------------------------------------


def test_report_get_by_id(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(
        appearance, "get_report", lambda db, uid, rid: dict(_REPORT, id=rid)
    )
    resp = client.get(
        "/appearance/report/a1", headers=_auth(monkeypatch, uid="u1")
    )
    assert resp.status_code == 200 and resp.json()["id"] == "a1"


def test_report_get_404(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: None)
    resp = client.get(
        "/appearance/report/nope", headers=_auth(monkeypatch, uid="u1")
    )
    assert resp.status_code == 404


# --- GET /appearance/history -------------------------------------------


def test_history_shape(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    rows = [
        {"id": "a1", "created_at": None, "has_face": True, "has_body": False,
         "summary": "x", "legacy": False, "kind": "appearance"},
        {"id": "f1", "created_at": None, "has_face": True, "has_body": False,
         "summary": "Average — 5/10", "legacy": True, "kind": "face"},
    ]
    monkeypatch.setattr(appearance, "history", lambda db, uid: rows)
    resp = client.get("/appearance/history", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 200
    assert resp.json()["reports"][1]["legacy"] is True


# --- GET /appearance/coverage -----------------------------------------


def test_coverage_shape(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(
        photo_attrs, "coverage",
        lambda db, uid: {"has_face_photo": True, "has_body_photo": False},
    )
    resp = client.get(
        "/appearance/coverage", headers=_auth(monkeypatch, uid="u1")
    )
    assert resp.status_code == 200
    assert resp.json() == {"has_face_photo": True, "has_body_photo": False}


# --- POST /cron/photo-tags-backfill ----------------------------------


def test_cron_photo_tags_backfill_rejects_without_header(monkeypatch):
    _with_secret(monkeypatch)
    assert client.post("/cron/photo-tags-backfill").status_code == 403


def test_cron_photo_tags_backfill_runs_with_secret(monkeypatch):
    _with_secret(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: object())
    seen = {}

    async def _fake(db, *, user_limit=200):
        seen["user_limit"] = user_limit
        return {"users": 2, "photos_tagged": 5}

    monkeypatch.setattr(main.photo_attrs, "backfill_missing_tags", _fake)
    resp = client.post(
        "/cron/photo-tags-backfill?user_limit=30",
        headers={"X-Cron-Secret": _SECRET},
    )
    assert resp.status_code == 200
    assert resp.json()["photos_tagged"] == 5 and seen["user_limit"] == 30


def test_cron_usable_for_body_resync_requires_secret():
    assert client.post("/cron/usable-for-body-resync").status_code == 403


# --- POST /appearance/finding/correct ---------------------------------------


def test_finding_correct_requires_auth():
    resp = client.post(
        "/appearance/finding/correct",
        json={"finding_id": "eye_color", "message": "it's blue"},
    )
    assert resp.status_code in (401, 403)


def test_finding_correct_returns_the_result(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    async def _correct(db, uid, finding_id, message):
        assert uid == "u1" and finding_id == "eye_color" and message == "it's blue"
        return {"ok": True, "reply": "Got it!", "finding_id": "eye_color", "value": "blue"}

    monkeypatch.setattr(appearance, "correct_finding", _correct)
    resp = client.post(
        "/appearance/finding/correct",
        json={"finding_id": "eye_color", "message": "it's blue"},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 200
    assert resp.json() == {
        "ok": True, "reply": "Got it!", "finding_id": "eye_color", "value": "blue",
    }


def test_finding_correct_404_for_unknown_finding(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    async def _correct(db, uid, finding_id, message):
        raise KeyError(finding_id)

    monkeypatch.setattr(appearance, "correct_finding", _correct)
    resp = client.post(
        "/appearance/finding/correct",
        json={"finding_id": "shoe_size", "message": "size 10"},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 404


def test_finding_correct_422_for_a_blank_message(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    async def _correct(db, uid, finding_id, message):
        raise ValueError("message is required")

    monkeypatch.setattr(appearance, "correct_finding", _correct)
    resp = client.post(
        "/appearance/finding/correct",
        json={"finding_id": "eye_color", "message": "x"},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 422


def test_cron_usable_for_body_resync_runs_with_secret(monkeypatch):
    _with_secret(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: object())
    seen = {}

    async def _fake(db, *, user_limit=500):
        seen["user_limit"] = user_limit
        return {"users": 3, "photos_fixed": 7}

    monkeypatch.setattr(main.photo_attrs, "resync_usable_for_body", _fake)
    resp = client.post(
        "/cron/usable-for-body-resync?user_limit=40",
        headers={"X-Cron-Secret": _SECRET},
    )
    assert resp.status_code == 200
    assert resp.json()["photos_fixed"] == 7 and seen["user_limit"] == 40
