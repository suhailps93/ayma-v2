"""Provider usage and spend for the admin dashboard (``GET /admin/provider-spend``).

Founder rule (2026-10-25): every figure on this dashboard is pulled directly
from the provider that bills it. No manual entries, no estimates, no price
tables, no projections, and nothing from our own ``token_ledger`` (that stays
an internal credits system). Each panel is either numbers fetched from its
source, with the fetch time, or ``{"available": False, "reason": "..."}``.

Sources:

* **Google Cloud spend** — the Cloud Billing export to BigQuery
  (``billing_export`` dataset in this project; verified live 2026-10-25),
  queried over the BigQuery REST API with the service's own runtime identity
  (Application Default Credentials, ``roles/editor``). Costs, credits and
  usage amounts are summed straight from export rows. The export lags real
  time by hours; ``data_through`` reports the newest row's end time.
* **LiveKit Cloud usage** — the documented Analytics API
  (``cloud-api.livekit.io/api/project/{id}/sessions``, docs.livekit.io/deploy/
  admin/analytics-api). It needs the Cloud project id (``p_...``, from the
  dashboard URL; read from ``LIVEKIT_PROJECT_ID``), authenticates with a
  ``roomList`` token signed by the same ``LIVEKIT_API_KEY``/``SECRET`` used
  for room tokens, is Scale-plan-or-higher only, and only serves the last 7
  days. Series start fresh at ``LIVEKIT_TRACKING_STARTED_AT``.
* **LiveKit plan, credit balance/expiry, invoice, agent-session minutes and
  Inference spend** — LiveKit publishes no API for these (checked
  2026-10-25: the Analytics API is the only documented Cloud API, and
  ``lk cloud`` only has ``auth``; billing exists solely in the Cloud
  dashboard behind a login). They are reported as unavailable, never guessed.
"""

from __future__ import annotations

import logging
import os
import threading
import time
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone

from timefmt import utcnow
from config import CONFIG

logger = logging.getLogger("ayma.provider_spend")

LIVEKIT_TRACKING_STARTED_AT = "2026-10-25"
LIVEKIT_ANALYTICS_BASE = "https://cloud-api.livekit.io/api/project"
LIVEKIT_ANALYTICS_WINDOW_DAYS = 7
_LIVEKIT_PAGE_LIMIT = 100
_LIVEKIT_MAX_PAGES = 50
_LIVEKIT_DETAIL_CAP = 200
_LIVEKIT_DETAIL_WORKERS = 8
_HTTP_UA = "ayma-admin-dashboard/1"

BILLING_DATASET = "billing_export"
BILLING_TABLE_PREFIXES = (
    "gcp_billing_export_resource_v1_",
    "gcp_billing_export_v1_",
)
BILLING_WINDOW_DAYS = 31
# Billing-export service names for Google's model APIs. Vertex AI is what the
# backend uses; "Gemini API" / "Generative Language API" are where a Developer
# API key's spend would appear if that key's project shares this billing export.
AI_SERVICES = frozenset({"Vertex AI", "Gemini API", "Generative Language API"})

CACHE_TTL_SECONDS = 600
_cache_lock = threading.Lock()
_cache: dict[str, tuple[float, dict]] = {}


def _unavailable(reason: str) -> dict:
    return {"available": False, "reason": reason}



# ---------------------------------------------------------------------------
# Google Cloud Billing export (BigQuery)
# ---------------------------------------------------------------------------


def _authorized_session():
    import google.auth
    from google.auth.transport.requests import AuthorizedSession

    creds, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    return AuthorizedSession(creds)


def _find_billing_table(session, project: str) -> str | None:
    url = (
        f"https://bigquery.googleapis.com/bigquery/v2/projects/{project}"
        f"/datasets/{BILLING_DATASET}/tables"
    )
    resp = session.get(url, timeout=15)
    resp.raise_for_status()
    ids = [
        t["tableReference"]["tableId"] for t in resp.json().get("tables", [])
    ]
    for prefix in BILLING_TABLE_PREFIXES:
        for table_id in sorted(ids):
            if table_id.startswith(prefix):
                return table_id
    return None


def _billing_query(table: str, project: str) -> str:
    return (
        "SELECT DATE(usage_start_time) AS day, service.description AS service, "
        "sku.description AS sku, usage.pricing_unit AS unit, "
        "SUM(usage.amount_in_pricing_units) AS usage_amount, "
        "SUM(cost) AS cost, "
        "SUM((SELECT IFNULL(SUM(c.amount), 0) FROM UNNEST(credits) c)) AS credits, "
        "MAX(usage_end_time) AS data_through, ANY_VALUE(currency) AS currency "
        f"FROM `{project}.{BILLING_DATASET}.{table}` "
        "WHERE usage_start_time >= TIMESTAMP(@since) "
        "GROUP BY day, service, sku, unit"
    )


def _run_query(session, project: str, sql: str, since: date) -> list[dict]:
    url = f"https://bigquery.googleapis.com/bigquery/v2/projects/{project}/queries"
    body = {
        "query": sql,
        "useLegacySql": False,
        "timeoutMs": 30000,
        "queryParameters": [
            {
                "name": "since",
                "parameterType": {"type": "STRING"},
                "parameterValue": {"value": since.isoformat()},
            }
        ],
    }
    resp = session.post(url, json=body, timeout=45)
    resp.raise_for_status()
    data = resp.json()
    if not data.get("jobComplete"):
        raise RuntimeError("BigQuery billing query did not complete in time")
    names = [f["name"] for f in data.get("schema", {}).get("fields", [])]
    rows = [
        {n: cell.get("v") for n, cell in zip(names, row["f"])}
        for row in data.get("rows", [])
    ]
    token = data.get("pageToken")
    job = data.get("jobReference", {})
    while token:
        page = session.get(
            f"{url}/{job['jobId']}",
            params={"pageToken": token, "location": job.get("location", "US")},
            timeout=45,
        )
        page.raise_for_status()
        pd = page.json()
        rows += [
            {n: cell.get("v") for n, cell in zip(names, row["f"])}
            for row in pd.get("rows", [])
        ]
        token = pd.get("pageToken")
    return rows


def _f(value) -> float:
    try:
        return float(value) if value is not None else 0.0
    except (TypeError, ValueError):
        return 0.0


def aggregate_google(rows: list[dict], today: date) -> dict:
    """Sum raw billing-export rows into the dashboard figures. Pure arithmetic
    over fetched rows: month-to-date and last-31-days cost per service, the
    daily series and SKU breakdown for Google's model APIs."""
    month_start = today.replace(day=1).isoformat()
    mtd_by_service: dict[str, dict[str, float]] = defaultdict(
        lambda: {"cost": 0.0, "credits": 0.0}
    )
    window_by_service: dict[str, dict[str, float]] = defaultdict(
        lambda: {"cost": 0.0, "credits": 0.0}
    )
    ai_daily: dict[str, dict[str, float]] = defaultdict(lambda: defaultdict(float))
    ai_skus: dict[tuple[str, str, str], dict[str, float]] = defaultdict(
        lambda: {"usage": 0.0, "cost": 0.0}
    )
    data_through = ""
    currency = ""
    for r in rows:
        service = r.get("service") or "Unknown"
        day = r.get("day") or ""
        cost, credits = _f(r.get("cost")), _f(r.get("credits"))
        window_by_service[service]["cost"] += cost
        window_by_service[service]["credits"] += credits
        if day >= month_start:
            mtd_by_service[service]["cost"] += cost
            mtd_by_service[service]["credits"] += credits
            if service in AI_SERVICES:
                key = (service, r.get("sku") or "", r.get("unit") or "")
                ai_skus[key]["usage"] += _f(r.get("usage_amount"))
                ai_skus[key]["cost"] += cost
        if service in AI_SERVICES:
            ai_daily[day][service] += cost
        currency = currency or (r.get("currency") or "")
        data_through = max(data_through, _bq_ts(r.get("data_through")))

    def _services(src):
        out = [
            {
                "service": s,
                "cost": round(v["cost"], 4),
                "credits": round(v["credits"], 4),
                "net": round(v["cost"] + v["credits"], 4),
            }
            for s, v in src.items()
        ]
        return sorted(out, key=lambda x: x["cost"], reverse=True)

    mtd = _services(mtd_by_service)
    window = _services(window_by_service)
    services = sorted(ai_daily_services(ai_daily))
    return {
        "currency": currency or "USD",
        "month_start": month_start,
        "mtd_by_service": mtd,
        "mtd_total_cost": round(sum(s["cost"] for s in mtd), 4),
        "mtd_total_credits": round(sum(s["credits"] for s in mtd), 4),
        "mtd_total_net": round(sum(s["net"] for s in mtd), 4),
        "window_days": BILLING_WINDOW_DAYS,
        "window_by_service": window,
        "ai_services_seen": sorted(
            {s for s in window_by_service if s in AI_SERVICES}
        ),
        "ai_daily": [
            {"day": d, **{s: round(ai_daily[d].get(s, 0.0), 4) for s in services}}
            for d in sorted(ai_daily)
        ],
        "ai_daily_services": services,
        "ai_skus_mtd": sorted(
            (
                {
                    "service": k[0],
                    "sku": k[1],
                    "unit": k[2],
                    "usage": round(v["usage"], 2),
                    "cost": round(v["cost"], 4),
                }
                for k, v in ai_skus.items()
            ),
            key=lambda x: x["cost"],
            reverse=True,
        ),
        "data_through": data_through or None,
    }


def ai_daily_services(ai_daily) -> set[str]:
    return {s for d in ai_daily.values() for s in d}


def _bq_ts(value) -> str:
    """BigQuery REST returns TIMESTAMP as epoch seconds (string float)."""
    if not value:
        return ""
    try:
        return (
            datetime.fromtimestamp(float(value), tz=timezone.utc)
            .isoformat(timespec="seconds")
        )
    except (TypeError, ValueError):
        return str(value)


def google_billing() -> dict:
    project = CONFIG.project_id
    if not project:
        return _unavailable("GOOGLE_CLOUD_PROJECT is not set.")
    try:
        session = _authorized_session()
        table = _find_billing_table(session, project)
        if not table:
            return _unavailable(
                f"No Cloud Billing export table found in {project}:{BILLING_DATASET}. "
                "Enable the detailed usage cost export to BigQuery in the Billing console."
            )
        today = utcnow().date()
        since = today - timedelta(days=BILLING_WINDOW_DAYS - 1)
        rows = _run_query(session, project, _billing_query(table, project), since)
        data = aggregate_google(rows, today)
        data["available"] = True
        data["source"] = f"Google Cloud Billing export (BigQuery {project}.{BILLING_DATASET}.{table})"
        if not data["ai_services_seen"]:
            data["ai_note"] = (
                "No Vertex AI or Gemini API lines in this billing export for the window."
            )
        elif "Gemini API" not in data["ai_services_seen"] and (
            "Generative Language API" not in data["ai_services_seen"]
        ):
            data["ai_note"] = (
                "No Gemini Developer API spend appears in this export; if that API key "
                "belongs to a different Google project, its spend is in that project's "
                "billing, not here."
            )
        return data
    except Exception as exc:  # noqa: BLE001 - dashboard must not break
        logger.exception("billing export query failed")
        return _unavailable(f"{type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# LiveKit Cloud Analytics API
# ---------------------------------------------------------------------------

LIVEKIT_BILLING_UNAVAILABLE = (
    "LiveKit publishes no API for plan, credit balance/expiry, invoices, "
    "agent-session minutes or Inference spend; they exist only in the Cloud "
    "dashboard (Settings > Billing)."
)


def _livekit_token(api_key: str, api_secret: str) -> str:
    from livekit import api as lk_api

    return (
        lk_api.AccessToken(api_key, api_secret)
        .with_identity("admin-usage")
        .with_grants(lk_api.VideoGrants(room_list=True))
        .to_jwt()
    )


def _lk_get(session, project_id: str, token: str, path: str, params=None):
    resp = session.get(
        f"{LIVEKIT_ANALYTICS_BASE}/{project_id}{path}",
        headers={"Authorization": f"Bearer {token}", "User-Agent": _HTTP_UA},
        params=params,
        timeout=20,
    )
    if resp.status_code != 200:
        raise RuntimeError(
            f"LiveKit Analytics API {path} returned {resp.status_code}: {resp.text[:200]}"
        )
    return resp.json()


def aggregate_livekit(
    sessions: list[dict], details: dict[str, float], started_at: str
) -> dict:
    """Sum LiveKit Analytics sessions created on/after ``started_at``.
    ``details`` maps sessionId -> connectionMinutes for the sessions whose
    detail record was fetched; ``participant_minutes`` is the direct sum of
    those and ``minutes_sessions_covered`` says how many sessions that is."""
    kept = [s for s in sessions if (s.get("createdAt") or "")[:10] >= started_at]
    daily: dict[str, dict[str, float]] = defaultdict(
        lambda: {"sessions": 0, "participants": 0, "bandwidth_bytes": 0.0, "minutes": 0.0}
    )
    minutes = 0.0
    covered = 0
    for s in kept:
        day = (s.get("createdAt") or "")[:10]
        d = daily[day]
        d["sessions"] += 1
        d["participants"] += int(s.get("numParticipants") or 0)
        d["bandwidth_bytes"] += _f(s.get("bandwidthIn")) + _f(s.get("bandwidthOut"))
        sid = s.get("sessionId")
        if sid in details:
            d["minutes"] += details[sid]
            minutes += details[sid]
            covered += 1
    return {
        "sessions": len(kept),
        "participants": sum(int(s.get("numParticipants") or 0) for s in kept),
        "bandwidth_in_bytes": sum(_f(s.get("bandwidthIn")) for s in kept),
        "bandwidth_out_bytes": sum(_f(s.get("bandwidthOut")) for s in kept),
        "egress_sessions": sum(1 for s in kept if s.get("egress") in (1, 2)),
        "participant_minutes": round(minutes, 2),
        "minutes_sessions_covered": covered,
        "daily": [{"day": d, **{k: round(v, 2) for k, v in daily[d].items()}} for d in sorted(daily)],
    }


def livekit_usage() -> dict:
    out = {
        "tracking_started_at": LIVEKIT_TRACKING_STARTED_AT,
        "billing": _unavailable(LIVEKIT_BILLING_UNAVAILABLE),
    }
    api_key = os.getenv("LIVEKIT_API_KEY")
    api_secret = os.getenv("LIVEKIT_API_SECRET")
    project_id = os.getenv("LIVEKIT_PROJECT_ID")
    if not api_key or not api_secret:
        out["usage"] = _unavailable("LIVEKIT_API_KEY/LIVEKIT_API_SECRET not set.")
        return out
    if not project_id:
        out["usage"] = _unavailable(
            "LIVEKIT_PROJECT_ID (the p_... id in the LiveKit Cloud dashboard URL) is not "
            "configured; the Analytics API cannot be called without it."
        )
        return out
    try:
        import requests

        token = _livekit_token(api_key, api_secret)
        http = requests.Session()
        today = utcnow().date()
        window_start = max(
            today - timedelta(days=LIVEKIT_ANALYTICS_WINDOW_DAYS - 1),
            date.fromisoformat(LIVEKIT_TRACKING_STARTED_AT),
        )
        sessions: list[dict] = []
        for page in range(_LIVEKIT_MAX_PAGES):
            batch = _lk_get(
                http, project_id, token, "/sessions",
                {
                    "limit": _LIVEKIT_PAGE_LIMIT,
                    "page": page,
                    "start": window_start.isoformat(),
                    "end": (today + timedelta(days=1)).isoformat(),
                },
            )
            items = batch.get("sessions", []) if isinstance(batch, dict) else batch
            sessions += items
            if len(items) < _LIVEKIT_PAGE_LIMIT:
                break
        ids = [s["sessionId"] for s in sessions if s.get("sessionId")][:_LIVEKIT_DETAIL_CAP]

        def _minutes(sid: str) -> tuple[str, float | None]:
            try:
                d = _lk_get(http, project_id, token, f"/sessions/{sid}")
                return sid, _f(d.get("connectionMinutes"))
            except Exception:  # noqa: BLE001 - partial coverage is reported
                logger.warning("livekit session detail failed for %s", sid)
                return sid, None

        with ThreadPoolExecutor(max_workers=_LIVEKIT_DETAIL_WORKERS) as pool:
            details = {sid: m for sid, m in pool.map(_minutes, ids) if m is not None}
        usage = aggregate_livekit(sessions, details, LIVEKIT_TRACKING_STARTED_AT)
        usage["available"] = True
        usage["source"] = "LiveKit Cloud Analytics API"
        usage["window_start"] = window_start.isoformat()
        usage["note"] = (
            "Analytics API serves only the last 7 days and is Scale-plan-or-higher."
        )
        out["usage"] = usage
    except Exception as exc:  # noqa: BLE001 - dashboard must not break
        logger.exception("livekit analytics fetch failed")
        out["usage"] = _unavailable(f"{type(exc).__name__}: {exc}")
    return out


# ---------------------------------------------------------------------------
# Snapshot with a short cache
# ---------------------------------------------------------------------------


def _cached(key: str, fn) -> dict:
    with _cache_lock:
        hit = _cache.get(key)
        if hit and time.monotonic() - hit[0] < CACHE_TTL_SECONDS:
            return hit[1]
    value = fn()
    value["fetched_at"] = utcnow().isoformat(timespec="seconds")
    ok = value.get("available") is True or value.get("usage", {}).get("available") is True
    if ok:
        with _cache_lock:
            _cache[key] = (time.monotonic(), value)
    return value


def snapshot() -> dict:
    return {
        "fetched_at": utcnow().isoformat(timespec="seconds"),
        "cache_ttl_seconds": CACHE_TTL_SECONDS,
        "google": _cached("google", google_billing),
        "livekit": _cached("livekit", livekit_usage),
    }
