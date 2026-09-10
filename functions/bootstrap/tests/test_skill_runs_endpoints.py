import dataclasses
import datetime

import auth
import main
import skill_runs
from config import CONFIG
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)

_SECRET = "cron-secret-abcdefghijklmnop"


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def _with_secret(monkeypatch, value=_SECRET):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, cron_secret=value)
    )


# --- GET /skill-runs -----------------------------------------------------


def test_skill_runs_requires_auth():
    assert client.get("/skill-runs").status_code in (401, 403)


def test_skill_runs_returns_ledger_and_missing(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    ts = datetime.datetime(2026, 3, 4, 5, 6, 7)
    monkeypatch.setattr(
        skill_runs, "get_all",
        lambda db, uid: {
            "deep_dive": {
                "last_run_at": ts, "last_status": "ok",
                "source": "user", "detail": "self",
            },
        },
    )
    monkeypatch.setattr(
        skill_runs, "missing",
        lambda db, uid: ["face_report", "body_report", "physical_attributes"],
    )

    resp = client.get("/skill-runs", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 200
    body = resp.json()
    assert body["runs"]["deep_dive"] == {
        "last_run_at": "2026-03-04T05:06:07",
        "last_status": "ok",
        "source": "user",
    }
    assert body["missing"] == ["face_report", "body_report", "physical_attributes"]


# --- POST /cron/skill-backfill -----------------------------------------


def test_cron_skill_backfill_rejects_without_the_header(monkeypatch):
    _with_secret(monkeypatch)
    assert client.post("/cron/skill-backfill").status_code == 403


def test_cron_skill_backfill_rejects_a_wrong_secret(monkeypatch):
    _with_secret(monkeypatch)
    resp = client.post(
        "/cron/skill-backfill", headers={"X-Cron-Secret": "nope"}
    )
    assert resp.status_code == 403


def test_cron_skill_backfill_runs_with_the_right_secret(monkeypatch):
    _with_secret(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: object())
    seen = {}

    async def _fake_sweep(db, user_limit=200):
        seen["user_limit"] = user_limit
        return {"users": 4, "ran": {"physical_attributes": 3}, "skipped": {},
                "errors": 0}

    monkeypatch.setattr(main.skill_runs, "sweep", _fake_sweep)

    resp = client.post(
        "/cron/skill-backfill?user_limit=25", headers={"X-Cron-Secret": _SECRET}
    )
    assert resp.status_code == 200
    assert resp.json()["users"] == 4
    assert seen["user_limit"] == 25
