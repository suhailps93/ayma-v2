import dataclasses

import auth
import main
from config import CONFIG
from fastapi.testclient import TestClient

client = TestClient(main.app)

_SECRET = "cron-secret-abcdefghijklmnop"


def _with_secret(monkeypatch, value=_SECRET):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, cron_secret=value)
    )


def test_cron_lint_rejects_without_the_header(monkeypatch):
    _with_secret(monkeypatch)
    assert client.post("/cron/lint").status_code == 403


def test_cron_lint_rejects_a_wrong_secret(monkeypatch):
    _with_secret(monkeypatch)
    resp = client.post("/cron/lint", headers={"X-Cron-Secret": "nope"})
    assert resp.status_code == 403


def test_cron_lint_fails_closed_when_secret_unset(monkeypatch):
    _with_secret(monkeypatch, value="")
    resp = client.post("/cron/lint", headers={"X-Cron-Secret": "anything"})
    assert resp.status_code == 403


def test_cron_lint_runs_with_the_right_secret(monkeypatch):
    _with_secret(monkeypatch)
    seen = {}

    async def _fake_lint_all(db, limit=None):
        seen["limit"] = limit
        return {"users_checked": 3, "pages_flagged": 1}

    monkeypatch.setattr(main, "lint_all", _fake_lint_all)

    resp = client.post(
        "/cron/lint?limit=5", headers={"X-Cron-Secret": _SECRET}
    )
    assert resp.status_code == 200
    assert resp.json() == {"users_checked": 3, "pages_flagged": 1}
    assert seen["limit"] == 5
