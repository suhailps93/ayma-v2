"""Tests for infra_cost.py — the LiveKit + GCP compute/storage cost figures
on the admin finance dashboard (§14.3), and the Gemini cost tracking-since
caveat. Mirrors this codebase's existing convention (see
test_notifications_dispatch.py) of monkeypatching the module's own
functions rather than mocking HTTP libraries directly.
"""

import dataclasses

import admin
import auth
import infra_cost
import main
from config import CONFIG
from fastapi.testclient import TestClient

client = TestClient(main.app)

_PW = "hunter2-admin-pass"


def _pw(monkeypatch, value=_PW):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, admin_password=value)
    )


# ---- a minimal fake Firestore, just for admin_config/* docs -----------------
class _FakeSnap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _FakeDoc:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def get(self):
        return _FakeSnap(self._store.get(self._key))

    def set(self, data, merge=False):
        cur = dict(self._store.get(self._key) or {}) if merge else {}
        cur.update(data)
        self._store[self._key] = cur


class _FakeCollection:
    def __init__(self, store, name):
        self._store = store
        self._name = name

    def document(self, doc_id):
        return _FakeDoc(self._store, (self._name, doc_id))


class _FakeDb:
    def __init__(self):
        self._store: dict = {}

    def collection(self, name):
        return _FakeCollection(self._store, name)


# ---- Gemini tracking caveat --------------------------------------------------

def test_gemini_tracking_info_names_a_real_date_and_commit():
    info = infra_cost.gemini_tracking_info()
    assert info["tracked_since"] == infra_cost.GEMINI_COST_TRACKED_SINCE
    assert info["tracked_since_commit"] == infra_cost.GEMINI_COST_TRACKED_SINCE_COMMIT
    assert "tracked since" in info["note"]
    assert infra_cost.GEMINI_COST_TRACKED_SINCE in info["note"]
    assert "not full account history" in info["note"] or "not backfilled" in info["note"]


def test_finance_summary_carries_the_gemini_tracking_caveat():
    from test_admin import _Db

    result = admin.finance_summary(_Db({}))
    assert result["gemini_cost_tracking"]["tracked_since"] == infra_cost.GEMINI_COST_TRACKED_SINCE


# ---- LiveKit: unavailable (no project id configured) -> manual-entry fallback

def test_livekit_cost_falls_back_to_manual_entry_when_api_unavailable(monkeypatch):
    monkeypatch.delenv("LIVEKIT_PROJECT_ID", raising=False)
    db = _FakeDb()
    result = infra_cost.livekit_cost(db)
    assert result["source"] == "manual_entry"
    assert result["label"] == "LiveKit (manually entered)"
    assert result["monthly_usd"] is None  # nothing entered yet
    assert result["unavailable_reason"]  # honest reason, not silence


def test_livekit_cost_reads_back_manual_entry_once_set():
    db = _FakeDb()
    written = infra_cost.set_livekit_manual_cost(db, 42.5, note="from LiveKit dashboard")
    assert written["monthly_usd"] == 42.5

    result = infra_cost.livekit_cost(db)
    assert result["source"] == "manual_entry"
    assert result["monthly_usd"] == 42.5
    assert result["note"] == "from LiveKit dashboard"


def test_livekit_cost_uses_real_api_when_reachable(monkeypatch):
    monkeypatch.setattr(
        infra_cost,
        "_livekit_analytics_attempt",
        lambda days: {"available": True, "connection_minutes": 123.0, "num_sessions": 4},
    )
    db = _FakeDb()
    result = infra_cost.livekit_cost(db)
    assert result["source"] == "livekit_api"
    assert result["label"] == "LiveKit (from their API, real)"
    assert result["connection_minutes"] == 123.0
    assert result["num_sessions"] == 4


def test_livekit_analytics_attempt_reports_missing_project_id_honestly(monkeypatch):
    monkeypatch.setenv("LIVEKIT_API_KEY", "k")
    monkeypatch.setenv("LIVEKIT_API_SECRET", "s")
    monkeypatch.delenv("LIVEKIT_PROJECT_ID", raising=False)
    result = infra_cost._livekit_analytics_attempt(30)
    assert result["available"] is False
    assert "LIVEKIT_PROJECT_ID" in result["reason"]


# ---- GCP compute estimate ----------------------------------------------------

def test_cloud_run_estimate_computes_from_real_config_and_usage(monkeypatch):
    monkeypatch.setattr(infra_cost, "CONFIG", dataclasses.replace(CONFIG, project_id="ayma-ai"))
    monkeypatch.setattr(infra_cost, "_authorized_session", lambda: object())
    monkeypatch.setattr(
        infra_cost,
        "_service_config",
        lambda session, project, region, service: {
            "cpu": 1.0, "memory_gib": 0.5, "min_instances": 0, "max_instances": 4,
        },
    )
    monkeypatch.setattr(
        infra_cost, "_billable_instance_seconds",
        lambda session, project, service, days: 100_000.0,
    )

    result = infra_cost.cloud_run_estimate(days=30)
    assert result["available"] is True
    assert len(result["services"]) == len(infra_cost.CLOUD_RUN_SERVICES)
    expected_per_service = 100_000.0 * (
        1.0 * infra_cost.CLOUD_RUN_VCPU_SEC_USD + 0.5 * infra_cost.CLOUD_RUN_GIB_SEC_USD
    )
    for svc in result["services"]:
        assert svc["available"] is True
        assert svc["estimated_usd"] == round(expected_per_service, 4)
    assert result["total_estimated_usd"] == round(
        expected_per_service * len(infra_cost.CLOUD_RUN_SERVICES), 4
    )
    assert result["pricing_source"]


def test_cloud_run_estimate_unavailable_without_project_id(monkeypatch):
    monkeypatch.setattr(infra_cost, "CONFIG", dataclasses.replace(CONFIG, project_id=""))
    result = infra_cost.cloud_run_estimate()
    assert result["available"] is False
    assert result["services"] == []


def test_cloud_run_estimate_degrades_per_service_on_api_failure(monkeypatch):
    monkeypatch.setattr(infra_cost, "CONFIG", dataclasses.replace(CONFIG, project_id="ayma-ai"))
    monkeypatch.setattr(infra_cost, "_authorized_session", lambda: object())

    def _boom(*a, **k):
        raise RuntimeError("monitoring API disabled")

    monkeypatch.setattr(infra_cost, "_service_config", _boom)
    result = infra_cost.cloud_run_estimate()
    assert result["available"] is True  # the whole endpoint doesn't die
    assert all(not s["available"] for s in result["services"])
    assert all("monitoring API disabled" in s["error"] for s in result["services"])


# ---- Artifact Registry estimate ---------------------------------------------

def test_artifact_registry_estimate_computes_from_real_sizes(monkeypatch):
    monkeypatch.setattr(infra_cost, "CONFIG", dataclasses.replace(CONFIG, project_id="ayma-ai"))

    class _Resp:
        def __init__(self, size_bytes):
            self._size_bytes = size_bytes

        def raise_for_status(self):
            pass

        def json(self):
            return {"sizeBytes": str(self._size_bytes)}

    class _Session:
        def get(self, url, timeout=None):
            return _Resp(1_000_000_000)  # 1 GB per repo

    monkeypatch.setattr(infra_cost, "_authorized_session", lambda: _Session())
    result = infra_cost.artifact_registry_estimate()
    assert result["available"] is True
    n = len(infra_cost.ARTIFACT_REGISTRY_REPOS)
    assert result["total_size_gb"] == n * 1.0
    billable = max(0.0, n * 1.0 - infra_cost.ARTIFACT_REGISTRY_FREE_GB)
    assert result["estimated_usd_per_month"] == round(
        billable * infra_cost.ARTIFACT_REGISTRY_GB_MONTH_USD, 4
    )


# ---- endpoints ----------------------------------------------------------------

def test_infra_costs_endpoint_requires_the_password(monkeypatch):
    _pw(monkeypatch)
    assert client.get("/admin/infra-costs").status_code == 403
    assert client.get(
        "/admin/infra-costs", headers={"X-Admin-Password": "wrong"}
    ).status_code == 403


def test_infra_costs_endpoint_returns_all_labeled_sources(monkeypatch):
    _pw(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: _FakeDb())
    r = client.get("/admin/infra-costs", headers={"X-Admin-Password": _PW})
    assert r.status_code == 200
    body = r.json()
    assert set(body.keys()) == {"gemini", "livekit", "gcp_compute", "artifact_registry"}
    assert body["gemini"]["tracked_since"] == infra_cost.GEMINI_COST_TRACKED_SINCE
    assert body["livekit"]["source"] in {"livekit_api", "manual_entry"}


def test_livekit_cost_endpoint_requires_the_password(monkeypatch):
    _pw(monkeypatch)
    assert client.post(
        "/admin/livekit-cost", json={"monthly_usd": 10}
    ).status_code == 403


def test_livekit_cost_endpoint_writes_and_is_reflected(monkeypatch):
    _pw(monkeypatch)
    db = _FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = client.post(
        "/admin/livekit-cost",
        headers={"X-Admin-Password": _PW},
        json={"monthly_usd": 17.25, "note": "manual, from dashboard"},
    )
    assert r.status_code == 200
    assert r.json()["monthly_usd"] == 17.25

    r2 = client.get("/admin/infra-costs", headers={"X-Admin-Password": _PW})
    assert r2.json()["livekit"]["monthly_usd"] == 17.25
