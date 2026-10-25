"""Tests for provider_spend.py and GET /admin/provider-spend: figures come
only from the provider sources (billing export rows, LiveKit Analytics),
everything unreachable is reported as unavailable with a reason."""

import dataclasses
from datetime import date

import auth
import main
import provider_spend
from config import CONFIG
from fastapi.testclient import TestClient

client = TestClient(main.app)
_PW = "hunter2-admin-pass"


def _pw(monkeypatch):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, admin_password=_PW)
    )


def _row(day, service, sku, cost, credits=0.0, usage=10.0, end="1792000000"):
    return {
        "day": day, "service": service, "sku": sku, "unit": "count",
        "usage_amount": str(usage), "cost": str(cost), "credits": str(credits),
        "data_through": end, "currency": "USD",
    }


def test_aggregate_google_sums_rows_by_service_day_and_sku():
    rows = [
        _row("2026-10-02", "Vertex AI", "Flash In", 1.5, -1.0, 100),
        _row("2026-10-02", "Vertex AI", "Flash Out", 2.0, -2.0, 50),
        _row("2026-10-03", "Vertex AI", "Flash In", 0.5, 0, 20),
        _row("2026-10-03", "Cloud Run", "CPU", 4.0, -1.0),
        _row("2026-09-30", "Vertex AI", "Flash In", 9.0),
    ]
    out = provider_spend.aggregate_google(rows, date(2026, 10, 25))
    mtd = {s["service"]: s for s in out["mtd_by_service"]}
    assert mtd["Vertex AI"]["cost"] == 4.0
    assert mtd["Vertex AI"]["credits"] == -3.0
    assert mtd["Vertex AI"]["net"] == 1.0
    assert out["mtd_total_cost"] == 8.0
    assert out["mtd_total_net"] == 4.0
    assert [d["day"] for d in out["ai_daily"]] == ["2026-09-30", "2026-10-02", "2026-10-03"]
    assert out["ai_daily"][1]["Vertex AI"] == 3.5
    sku = {k["sku"]: k for k in out["ai_skus_mtd"]}
    assert sku["Flash In"]["usage"] == 120.0 and sku["Flash In"]["cost"] == 2.0
    assert "Cloud Run" not in {k["service"] for k in out["ai_skus_mtd"]}
    assert out["data_through"].startswith("2026-")
    assert out["ai_services_seen"] == ["Vertex AI"]


def test_aggregate_livekit_starts_fresh_and_sums_directly():
    sessions = [
        {"sessionId": "a", "createdAt": "2026-10-24T23:00:00Z", "numParticipants": 9, "bandwidthIn": 1, "bandwidthOut": 1},
        {"sessionId": "b", "createdAt": "2026-10-25T01:00:00Z", "numParticipants": 2, "bandwidthIn": 10, "bandwidthOut": 20, "egress": 2},
        {"sessionId": "c", "createdAt": "2026-10-26T01:00:00Z", "numParticipants": 1, "bandwidthIn": 5, "bandwidthOut": 5, "egress": 0},
    ]
    out = provider_spend.aggregate_livekit(sessions, {"a": 99.0, "b": 3.5}, "2026-10-25")
    assert out["sessions"] == 2
    assert out["participants"] == 3
    assert out["participant_minutes"] == 3.5
    assert out["minutes_sessions_covered"] == 1
    assert out["bandwidth_in_bytes"] == 15 and out["bandwidth_out_bytes"] == 25
    assert out["egress_sessions"] == 1
    assert [d["day"] for d in out["daily"]] == ["2026-10-25", "2026-10-26"]


def test_livekit_unavailable_without_project_id(monkeypatch):
    monkeypatch.setenv("LIVEKIT_API_KEY", "k")
    monkeypatch.setenv("LIVEKIT_API_SECRET", "s")
    monkeypatch.delenv("LIVEKIT_PROJECT_ID", raising=False)
    out = provider_spend.livekit_usage()
    assert out["usage"]["available"] is False
    assert "LIVEKIT_PROJECT_ID" in out["usage"]["reason"]
    assert out["billing"]["available"] is False
    assert out["tracking_started_at"] == "2026-10-25"


def test_google_billing_unavailable_when_query_fails(monkeypatch):
    monkeypatch.setattr(provider_spend, "CONFIG", dataclasses.replace(CONFIG, project_id="p"))

    def boom():
        raise RuntimeError("denied")

    monkeypatch.setattr(provider_spend, "_authorized_session", boom)
    out = provider_spend.google_billing()
    assert out == {"available": False, "reason": "RuntimeError: denied"}


def test_snapshot_caches_successes_only(monkeypatch):
    provider_spend._cache.clear()
    calls = {"n": 0}

    def ok():
        calls["n"] += 1
        return {"available": True}

    monkeypatch.setattr(provider_spend, "google_billing", ok)
    monkeypatch.setattr(provider_spend, "livekit_usage", lambda: {"usage": {"available": False}})
    provider_spend.snapshot()
    provider_spend.snapshot()
    assert calls["n"] == 1
    provider_spend._cache.clear()


def test_endpoint_requires_password_and_returns_snapshot(monkeypatch):
    _pw(monkeypatch)
    assert client.get("/admin/provider-spend").status_code == 403
    monkeypatch.setattr(
        provider_spend, "snapshot",
        lambda: {"google": {"available": False, "reason": "x"}, "livekit": {}},
    )
    r = client.get("/admin/provider-spend", headers={"X-Admin-Password": _PW})
    assert r.status_code == 200
    assert r.json()["google"]["reason"] == "x"


def test_dashboard_page_uses_provider_endpoint_only():
    html = client.get("/admin").text
    assert "/admin/provider-spend" in html
    assert "finance-summary" not in html and "livekit-cost" not in html
