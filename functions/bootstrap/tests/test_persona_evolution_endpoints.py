import dataclasses

import auth
import main
import persona_evolution
from config import CONFIG
from fastapi.testclient import TestClient

client = TestClient(main.app)

_CRON_SECRET = "cron-secret-abcdefghijklmnop"
_ADMIN_PW = "hunter2-admin-pass"


def _with_cron_secret(monkeypatch, value=_CRON_SECRET):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, cron_secret=value)
    )


def _with_admin_pw(monkeypatch, value=_ADMIN_PW):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, admin_password=value)
    )


# ---------------------------------------------------------------- cron -----

def test_cron_persona_evolution_rejects_without_the_header(monkeypatch):
    _with_cron_secret(monkeypatch)
    assert client.post("/cron/persona-evolution").status_code == 403


def test_cron_persona_evolution_rejects_a_wrong_secret(monkeypatch):
    _with_cron_secret(monkeypatch)
    resp = client.post(
        "/cron/persona-evolution", headers={"X-Cron-Secret": "nope"}
    )
    assert resp.status_code == 403


def test_cron_persona_evolution_fails_closed_when_secret_unset(monkeypatch):
    _with_cron_secret(monkeypatch, value="")
    resp = client.post(
        "/cron/persona-evolution", headers={"X-Cron-Secret": "anything"}
    )
    assert resp.status_code == 403


def test_cron_persona_evolution_runs_with_the_right_secret(monkeypatch):
    _with_cron_secret(monkeypatch)
    seen = {}

    async def _fake_run(db, window_days=7):
        seen["window_days"] = window_days
        return {"ran": True, "action": "no_feedback", "based_on_feedback_count": 0}

    monkeypatch.setattr(main.persona_evolution, "run", _fake_run)
    monkeypatch.setattr(main, "get_db", lambda: object())

    resp = client.post(
        "/cron/persona-evolution", headers={"X-Cron-Secret": _CRON_SECRET}
    )
    assert resp.status_code == 200
    assert resp.json()["action"] == "no_feedback"
    assert seen["window_days"] == persona_evolution.WINDOW_DAYS


def test_cron_persona_evolution_accepts_a_window_days_override(monkeypatch):
    _with_cron_secret(monkeypatch)
    seen = {}

    async def _fake_run(db, window_days=7):
        seen["window_days"] = window_days
        return {"ran": True, "action": "no_feedback", "based_on_feedback_count": 0}

    monkeypatch.setattr(main.persona_evolution, "run", _fake_run)
    monkeypatch.setattr(main, "get_db", lambda: object())

    resp = client.post(
        "/cron/persona-evolution?window_days=14",
        headers={"X-Cron-Secret": _CRON_SECRET},
    )
    assert resp.status_code == 200
    assert seen["window_days"] == 14


# ---------------------------------------------------------------- admin ----

def test_admin_persona_changes_requires_the_password(monkeypatch):
    _with_admin_pw(monkeypatch)
    assert client.get("/admin/persona-changes").status_code == 403
    assert client.post("/admin/persona-changes/p1/approve").status_code == 403
    assert client.post("/admin/persona-changes/p1/reject").status_code == 403


def test_admin_persona_changes_fails_closed_when_unset(monkeypatch):
    _with_admin_pw(monkeypatch, value="")
    resp = client.get(
        "/admin/persona-changes", headers={"X-Admin-Password": "anything"}
    )
    assert resp.status_code == 403


def test_admin_persona_changes_lists_pending(monkeypatch):
    _with_admin_pw(monkeypatch)
    monkeypatch.setattr(
        main.persona_evolution, "list_pending",
        lambda db: [{"id": "p1", "status": "pending"}],
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.get(
        "/admin/persona-changes", headers={"X-Admin-Password": _ADMIN_PW}
    )
    assert resp.status_code == 200
    assert resp.json() == {"proposals": [{"id": "p1", "status": "pending"}]}


def test_admin_persona_change_approve_flow(monkeypatch):
    _with_admin_pw(monkeypatch)
    seen = {}

    def _fake_approve(db, proposal_id):
        seen["proposal_id"] = proposal_id
        return True

    monkeypatch.setattr(main.persona_evolution, "approve", _fake_approve)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/admin/persona-changes/p1/approve",
        headers={"X-Admin-Password": _ADMIN_PW},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert seen["proposal_id"] == "p1"


def test_admin_persona_change_approve_404_when_missing(monkeypatch):
    _with_admin_pw(monkeypatch)
    monkeypatch.setattr(main.persona_evolution, "approve", lambda db, pid: False)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/admin/persona-changes/nope/approve",
        headers={"X-Admin-Password": _ADMIN_PW},
    )
    assert resp.status_code == 404


def test_admin_persona_change_reject_flow_with_reason(monkeypatch):
    _with_admin_pw(monkeypatch)
    seen = {}

    def _fake_reject(db, proposal_id, reason=""):
        seen["proposal_id"] = proposal_id
        seen["reason"] = reason
        return True

    monkeypatch.setattr(main.persona_evolution, "reject", _fake_reject)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/admin/persona-changes/p1/reject?reason=not+needed",
        headers={"X-Admin-Password": _ADMIN_PW},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert seen == {"proposal_id": "p1", "reason": "not needed"}


def test_admin_persona_change_reject_404_when_missing(monkeypatch):
    _with_admin_pw(monkeypatch)
    monkeypatch.setattr(main.persona_evolution, "reject", lambda db, pid, reason="": False)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/admin/persona-changes/nope/reject",
        headers={"X-Admin-Password": _ADMIN_PW},
    )
    assert resp.status_code == 404
