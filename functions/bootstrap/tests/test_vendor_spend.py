"""Tests for vendor_spend.py, GET /admin/vendors and POST /admin/vendor-spend."""

import dataclasses
from datetime import datetime, timedelta, timezone

import auth
import main
import provider_spend
import pytest
import vendor_spend
from config import CONFIG
from fastapi.testclient import TestClient

client = TestClient(main.app)
_PW = "hunter2-admin-pass"
NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)


class _Doc:
    def __init__(self, d):
        self._d = d

    def to_dict(self):
        return self._d


class _FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        assert name == vendor_spend.COLLECTION
        db = self

        class _Col:
            def document(self, doc_id):
                class _Ref:
                    def set(_, data):
                        db.docs[doc_id] = data

                return _Ref()

            def stream(self):
                return [_Doc(d) for d in db.docs.values()]

        return _Col()


def _payload(**over):
    p = {
        "vendor": "sentry", "metric": "monthly_invoice", "amount": 26.0,
        "currency": "USD", "period": "2026-10",
        "source_url": "https://sentry.io/settings/billing/",
        "collected_by": "muse", "fetched_at": "2026-10-25T11:00:00+00:00",
        "note": "plan fee",
    }
    p.update(over)
    return p


def _snap():
    return {
        "fetched_at": "2026-10-25T11:50:00+00:00",
        "google": {
            "available": True, "currency": "USD", "month_start": "2026-10-01",
            "fetched_at": "2026-10-25T11:50:00+00:00",
            "mtd_by_service": [
                {"service": "Cloud Run", "cost": 4.0, "credits": -1.0, "net": 3.0},
            ],
        },
        "livekit": {"usage": {"available": False, "reason": "no project id"}},
    }


def test_catalog_covers_every_vendor_with_how_to_check():
    ids = {v["id"] for v in vendor_spend.load_catalog()}
    for needed in ("cloud_run", "firestore", "vertex_ai", "gemini_developer_api",
                   "livekit_usage", "revenuecat", "sentry", "codemagic",
                   "apple_developer", "google_play", "domain_justabot",
                   "google_credits", "livekit_credits", "google_custom_search"):
        assert needed in ids
    for v in vendor_spend.load_catalog():
        assert v["how_to_check"]["steps"] and v["how_to_check"]["url"].startswith("https://")
        assert "EIN" not in str(v)


@pytest.mark.parametrize("field", ["vendor", "metric", "amount", "currency",
                                   "period", "source_url", "collected_by", "fetched_at"])
def test_missing_required_field_rejected(field):
    p = _payload()
    del p[field]
    with pytest.raises(vendor_spend.ValidationError):
        vendor_spend.validate(p, NOW)


@pytest.mark.parametrize("over", [
    {"vendor": "nope"}, {"amount": "26"}, {"amount": True}, {"amount": float("inf")},
    {"collected_by": "human"}, {"source_url": "ftp://x"}, {"fetched_at": "yesterday"},
    {"fetched_at": "2026-10-25T11:00:00"}, {"fetched_at": "2027-01-01T00:00:00+00:00"},
    {"metric": "Bad Metric"}, {"currency": "$"}, {"extra": 1},
])
def test_invalid_values_rejected(over):
    with pytest.raises(vendor_spend.ValidationError):
        vendor_spend.validate(_payload(**over), NOW)


def test_valid_payload_cleaned():
    doc = vendor_spend.validate(_payload(currency="usd"), NOW)
    assert doc["currency"] == "USD" and doc["amount"] == 26.0


def test_build_api_muse_stale_and_unavailable():
    db = _FakeDb()
    now = datetime.now(timezone.utc)
    vendor_spend.record(db, _payload(fetched_at=(now - timedelta(hours=1)).isoformat()))
    vendor_spend.record(db, _payload(
        vendor="codemagic", metric="plan",
        fetched_at=(now - timedelta(hours=40)).isoformat()))
    out = vendor_spend.build(db, _snap(), now)
    rows = {r["id"]: r for r in out["vendors"]}
    run = rows["cloud_run"]["entries"]
    assert [e["method"] for e in run] == ["api", "api"]
    assert run[0]["amount"] == 4.0 and run[1]["amount"] == 3.0
    assert rows["firestore"]["entries"][0]["amount"] == 0.0
    assert rows["sentry"]["entries"][0]["method"] == "muse"
    assert rows["sentry"]["entries"][0]["stale"] is False
    assert rows["codemagic"]["entries"][0]["stale"] is True
    assert rows["revenuecat"]["entries"] == []
    assert "unavailable_reason" in rows["revenuecat"]
    assert rows["livekit_usage"]["unavailable_reason"] == "no project id"
    assert "Configured, unused" in rows["google_custom_search"]["unavailable_reason"]


def test_build_google_unavailable_gives_reason_not_zero():
    snap = _snap()
    snap["google"] = {"available": False, "reason": "no export table"}
    out = vendor_spend.build(_FakeDb(), snap, NOW)
    row = next(r for r in out["vendors"] if r["id"] == "cloud_run")
    assert row["entries"] == [] and row["unavailable_reason"] == "no export table"


def test_endpoints_require_password(monkeypatch):
    monkeypatch.setattr(auth, "CONFIG", dataclasses.replace(CONFIG, admin_password=_PW))
    assert client.get("/admin/vendors").status_code == 403
    assert client.post("/admin/vendor-spend", json=_payload()).status_code == 403


def test_post_records_and_rejects(monkeypatch):
    monkeypatch.setattr(auth, "CONFIG", dataclasses.replace(CONFIG, admin_password=_PW))
    db = _FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    h = {"X-Admin-Password": _PW}
    fresh = datetime.now(timezone.utc).isoformat()
    ok = client.post("/admin/vendor-spend", json=_payload(fetched_at=fresh), headers=h)
    assert ok.status_code == 200 and "sentry__monthly_invoice" in db.docs
    bad = _payload()
    del bad["source_url"]
    assert client.post("/admin/vendor-spend", json=bad, headers=h).status_code == 422
    assert client.post("/admin/vendor-spend", content=b"nope", headers=h).status_code == 422


def test_get_vendors_returns_rows(monkeypatch):
    monkeypatch.setattr(auth, "CONFIG", dataclasses.replace(CONFIG, admin_password=_PW))
    monkeypatch.setattr(main, "get_db", lambda: _FakeDb())
    monkeypatch.setattr(provider_spend, "snapshot", _snap)
    r = client.get("/admin/vendors", headers={"X-Admin-Password": _PW})
    assert r.status_code == 200
    assert len(r.json()["vendors"]) == len(vendor_spend.load_catalog())


def test_stale_list_flags_stale_and_unavailable_only():
    db = _FakeDb()
    now = datetime.now(timezone.utc)
    vendor_spend.record(db, _payload(fetched_at=(now - timedelta(hours=1)).isoformat()))
    vendor_spend.record(db, _payload(
        vendor="codemagic", metric="plan",
        fetched_at=(now - timedelta(hours=40)).isoformat()))
    out = vendor_spend.build(db, _snap(), now)
    by_id = {a["id"]: a for a in out["stale"]}
    assert by_id["codemagic"]["kind"] == "stale"
    assert by_id["codemagic"]["age_hours"] == 40.0
    assert by_id["codemagic"]["url"].startswith("https://")
    assert by_id["revenuecat"]["kind"] == "unavailable"
    assert by_id["livekit_usage"]["reason"] == "no project id"
    for quiet in ("sentry", "cloud_run", "fcm", "crashlytics", "google_maps",
                  "google_custom_search"):
        assert quiet not in by_id


def test_stale_list_empty_when_everything_fresh():
    db = _FakeDb()
    now = datetime.now(timezone.utc)
    snap = _snap()
    snap["livekit"] = {"fetched_at": now.isoformat(), "usage": {
        "available": True, "participant_minutes": 1, "window_start": "2026-10-01"}}
    snap["google"]["fetched_at"] = now.isoformat()
    for v in vendor_spend.load_catalog():
        if (v["source"]["type"] == "none" and v.get("status", "active") == "active"
                and not v["source"].get("no_billing_line")):
            vendor_spend.record(db, _payload(vendor=v["id"], fetched_at=now.isoformat()))
    assert vendor_spend.build(db, snap, now)["stale"] == []


def test_get_vendors_exposes_stale(monkeypatch):
    monkeypatch.setattr(auth, "CONFIG", dataclasses.replace(CONFIG, admin_password=_PW))
    monkeypatch.setattr(main, "get_db", lambda: _FakeDb())
    monkeypatch.setattr(provider_spend, "snapshot", _snap)
    body = client.get("/admin/vendors", headers={"X-Admin-Password": _PW}).json()
    assert isinstance(body["stale"], list) and body["stale"]


def test_dashboard_html_has_stale_banner():
    html = client.get("/admin").text
    assert 'id="staleAlert"' in html and "renderStaleAlert" in html
