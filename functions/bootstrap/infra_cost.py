"""Real GCP infra costs + LiveKit cost, for the admin finance dashboard
(ARCHITECTURE.md §14.3).

This module exists because ``token_ledger.cost_usd`` (see ``admin.py``'s
``finance_summary``) is *only* Gemini token spend — real Ayma spend also
includes LiveKit Cloud (voice) and GCP infra (Cloud Run compute, Artifact
Registry image storage), neither of which was measured anywhere before this.
Founder request, 2026-09-19: be honest about what's real-measured vs.
estimated vs. hand-entered — never blend them into one misleading number.

Three sources, three different confidence levels:

1. **Gemini/AI tokens** (``gemini_tracking_info``) — real ``cost_usd``
   already computed in ``token_ledger.py``, just labeled with when tracking
   actually started (a code deploy, not a Firestore signal — see below).

2. **LiveKit Cloud** (``livekit_cost``) — LiveKit's project-usage Analytics
   API (``https://cloud-api.livekit.io/api/project/{id}/sessions``) is
   real and documented, authenticated with the *same*
   ``LIVEKIT_API_KEY``/``LIVEKIT_API_SECRET`` this app already uses to mint
   room-join tokens (``livekit_token.py``) — no new credentials invented.
   BUT: (a) it is documented as Scale-plan-or-higher only
   (https://docs.livekit.io/home/cloud/analytics-api/, checked 2026-09-19),
   and (b) it needs a LiveKit *project id* (not the same as the ``wss://``
   subdomain in ``LIVEKIT_URL`` — verified live: calling the endpoint with
   the subdomain as the project id returns ``401 invalid API key for
   project``) that isn't stored anywhere in this codebase. Real usage/dollar
   data is therefore NOT available via API on this project today. Rather
   than fabricate a number, this ships a Firestore-backed manual-entry field
   the founder fills in by hand from LiveKit's own dashboard
   (``admin_config/livekit_manual_cost``), clearly labeled as such. If a
   ``LIVEKIT_PROJECT_ID`` env var is ever set AND the plan is upgraded, the
   real path is already wired and takes over automatically.

3. **GCP compute + storage** (``cloud_run_estimate``,
   ``artifact_registry_estimate``) — there's no BigQuery billing export on
   this project (checked 2026-09-19: ``bq ls`` on ``ayma-ai`` returns
   nothing), so there's no API that hands back an exact dollar figure. This
   computes a labeled ESTIMATE from real Cloud Run service config (CPU/
   memory/min-instances, via the Cloud Run Admin API v2) and real Cloud
   Monitoring usage (``run.googleapis.com/container/billable_instance_time``,
   verified live against this project) against Cloud Run's published Tier 1
   per-vCPU-second / per-GiB-second rates, and real Artifact Registry
   repository sizes against its published per-GB-month storage rate.

All three live-API paths use the Cloud Run service's own runtime identity
(the Compute Engine default service account, which already holds
``roles/editor`` on this project per ``gcloud projects get-iam-policy`` —
covers ``monitoring.timeSeries.list``, Cloud Run Admin read, Artifact
Registry read) via ``google.auth.default()`` — no new IAM grant, no new
secret. ``requests`` and ``google-auth`` are already transitive
dependencies of ``firebase-admin``/``google-genai`` (see requirements.txt),
so no new pip dependency either.

Every function here is best-effort: a failed/denied/disabled API must not
break the admin dashboard. On failure it returns
``{"available": False, "error": "..."}`` rather than raising or guessing.
"""

from __future__ import annotations

import logging
import re
from datetime import datetime, timedelta, timezone

from config import CONFIG

logger = logging.getLogger("ayma.infra_cost")

# ---------------------------------------------------------------------------
# 1. Gemini/AI token cost — labeling only, no new computation. The real
#    number is token_ledger.cost_usd (admin.finance_summary already sums it).
# ---------------------------------------------------------------------------

# token_ledger.cost_usd only exists from this commit onward (see its module
# docstring: "usage docs written before the input/output split existed ...
# contribute $0 here rather than an estimate"). Hardcoded rather than derived
# from a Firestore scan because it's a code-deploy event, not a per-user
# signal — no account's `updated_at` can honestly stand in for "when the app
# started tracking $" the way the deploy date can.
GEMINI_COST_TRACKED_SINCE = "2026-09-16"
GEMINI_COST_TRACKED_SINCE_COMMIT = "278c562"


def gemini_tracking_info() -> dict:
    """Labeling for the existing ``token_ledger.cost_usd`` figure — the caveat
    the founder asked for: this is real $, but only since tracking began."""
    return {
        "tracked_since": GEMINI_COST_TRACKED_SINCE,
        "tracked_since_commit": GEMINI_COST_TRACKED_SINCE_COMMIT,
        "note": (
            f"Real $ cost, tracked since {GEMINI_COST_TRACKED_SINCE} "
            f"(commit {GEMINI_COST_TRACKED_SINCE_COMMIT}) — not full account "
            "history. Earlier Gemini usage was not priced and is not "
            "backfilled or estimated here."
        ),
    }


# ---------------------------------------------------------------------------
# Shared: an authorized session using the service's own runtime identity.
# ---------------------------------------------------------------------------


def _authorized_session():
    """A ``requests``-compatible session signed with this Cloud Run service's
    own identity (Application Default Credentials — the same mechanism
    ``firebase_admin.initialize_app()`` already relies on). Raises on failure;
    every caller catches and degrades to ``available: False``."""
    import google.auth
    from google.auth.transport.requests import AuthorizedSession

    creds, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    return AuthorizedSession(creds)


# ---------------------------------------------------------------------------
# 2. LiveKit Cloud — real-API attempt, honest fallback to manual entry.
# ---------------------------------------------------------------------------


def _livekit_analytics_attempt(days: int) -> dict:
    """Try LiveKit Cloud's real Analytics API. Returns
    ``{"available": True, "connection_minutes": ..., "num_sessions": ...}``
    on success, ``{"available": False, "reason": "..."}`` otherwise — never
    raises, never guesses a dollar figure from this path unless it actually
    got real session data back."""
    import os

    api_key = os.getenv("LIVEKIT_API_KEY")
    api_secret = os.getenv("LIVEKIT_API_SECRET")
    project_id = os.getenv("LIVEKIT_PROJECT_ID")  # not set today — see module docstring
    if not api_key or not api_secret:
        return {"available": False, "reason": "LIVEKIT_API_KEY/SECRET not set."}
    if not project_id:
        return {
            "available": False,
            "reason": (
                "No LIVEKIT_PROJECT_ID configured — LiveKit's Analytics API "
                "needs the Cloud project id (not the wss:// subdomain; "
                "verified live that the subdomain is rejected as an invalid "
                "project id), and it's Scale-plan-or-higher only "
                "(docs.livekit.io/home/cloud/analytics-api). Not available "
                "on this project today."
            ),
        }

    try:
        from livekit import api as lk_api
        import requests

        grants = lk_api.VideoGrants(room_list=True)
        token = (
            lk_api.AccessToken(api_key, api_secret)
            .with_identity("admin-usage-check")
            .with_grants(grants)
            .to_jwt()
        )
        resp = requests.get(
            f"https://cloud-api.livekit.io/api/project/{project_id}/sessions",
            headers={"Authorization": f"Bearer {token}"},
            params={
                "start": (
                    datetime.now(timezone.utc) - timedelta(days=days)
                ).isoformat()
            },
            timeout=10,
        )
        if resp.status_code != 200:
            return {
                "available": False,
                "reason": f"LiveKit Analytics API returned {resp.status_code}: {resp.text[:200]}",
            }
        sessions = resp.json() if resp.content else []
        minutes = sum(float(s.get("connectionMinutes", 0) or 0) for s in sessions)
        return {
            "available": True,
            "connection_minutes": minutes,
            "num_sessions": len(sessions),
        }
    except Exception as exc:  # noqa: BLE001 - must never break the dashboard
        logger.exception("LiveKit analytics probe failed")
        return {"available": False, "reason": f"{type(exc).__name__}: {exc}"}


def livekit_cost(db, days: int = 30) -> dict:
    """LiveKit Cloud cost for the dashboard: a real figure if the Analytics
    API is genuinely reachable, else the founder's manually-entered monthly
    spend from ``admin_config/livekit_manual_cost`` (Firestore), clearly
    labeled either way. Never fabricates a number."""
    probe = _livekit_analytics_attempt(days)
    if probe.get("available"):
        return {
            "source": "livekit_api",
            "label": "LiveKit (from their API, real)",
            "connection_minutes": probe["connection_minutes"],
            "num_sessions": probe["num_sessions"],
            "period_days": days,
            # Real usage, but turning it into $ needs the caller's actual
            # plan/tier rate, which isn't knowable from the API response —
            # left for the founder to apply, rather than guessed here.
            "estimated_usd": None,
            "note": "Real usage from LiveKit's Analytics API. Apply your plan's per-minute rate to price it.",
        }

    manual = _read_livekit_manual(db)
    return {
        "source": "manual_entry",
        "label": "LiveKit (manually entered)",
        "monthly_usd": manual.get("monthly_usd"),
        "note": manual.get("note", ""),
        "updated_at": manual.get("updated_at_str"),
        "unavailable_reason": probe.get("reason"),
    }


def _read_livekit_manual(db) -> dict:
    import schema

    snap = (
        db.collection(schema.ADMIN_CONFIG_COLLECTION)
        .document(schema.LIVEKIT_MANUAL_COST_DOC)
        .get()
    )
    data = snap.to_dict() if snap.exists else None
    data = data or {}
    updated_at = data.get("updated_at")
    return {
        "monthly_usd": data.get("monthly_usd"),
        "note": data.get("note", ""),
        "updated_at_str": str(updated_at) if updated_at else None,
    }


def set_livekit_manual_cost(db, monthly_usd: float, note: str = "") -> dict:
    """Admin-editable "LiveKit spend this month: $___" (§ task 2) — the
    founder updates this by hand from LiveKit Cloud's own dashboard."""
    import schema
    from firebase_admin import firestore

    db.collection(schema.ADMIN_CONFIG_COLLECTION).document(
        schema.LIVEKIT_MANUAL_COST_DOC
    ).set(
        {
            "monthly_usd": float(monthly_usd),
            "note": note,
            "updated_at": firestore.SERVER_TIMESTAMP,
        },
        merge=True,
    )
    return _read_livekit_manual(db)


# ---------------------------------------------------------------------------
# 3. GCP compute + storage — real config/usage, published pricing, labeled
#    estimate.
# ---------------------------------------------------------------------------

# Cloud Run Tier 1 published rates (US regions). Source:
# https://cloud.google.com/run/pricing (checked 2026-09-19), cross-checked
# against https://www.nops.io/blog/cloud-run-functions-pricing/ the same
# day. Both ayma-api and ayma-agent deploy with cpu-throttling=false (CPU
# always allocated), so billable_instance_time already reflects the full
# reserved uptime this pricing applies to.
CLOUD_RUN_VCPU_SEC_USD = 0.000024
CLOUD_RUN_GIB_SEC_USD = 0.0000025
CLOUD_RUN_PRICING_SOURCE = "https://cloud.google.com/run/pricing (Tier 1, US regions; checked 2026-09-19)"

# Artifact Registry published storage rate. Source:
# https://cloud.google.com/artifact-registry/pricing (checked 2026-09-19):
# first 0.5 GB/month free, then $0.10/GB/month, flat across regions.
ARTIFACT_REGISTRY_FREE_GB = 0.5
ARTIFACT_REGISTRY_GB_MONTH_USD = 0.10
ARTIFACT_REGISTRY_PRICING_SOURCE = "https://cloud.google.com/artifact-registry/pricing (checked 2026-09-19)"

# The currently-live Cloud Run services (ayma-bootstrap was deleted — do not
# add it back; see the task that added this module).
CLOUD_RUN_SERVICES = ("ayma-api", "ayma-agent")

# Known Artifact Registry repositories for this project + the (repo, region)
# pairs actually in use (verified live via the Artifact Registry API,
# 2026-09-19) — gcr.io is a legacy multi-region repo under "us", the other
# two are regional under "us-central1".
ARTIFACT_REGISTRY_REPOS = (
    ("ayma-repo", "us-central1"),
    ("cloud-run-source-deploy", "us-central1"),
    ("gcr.io", "us"),
)

_MEM_UNITS = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "K": 1e3, "M": 1e6, "G": 1e9}


def _parse_memory_gib(mem: str) -> float:
    """``"512Mi"`` / ``"2Gi"`` -> GiB float. Cloud Run Admin API v2's
    ``resources.limits.memory`` format."""
    m = re.match(r"^(\d+(?:\.\d+)?)([A-Za-z]*)$", (mem or "").strip())
    if not m:
        return 0.0
    value, unit = float(m.group(1)), m.group(2)
    bytes_ = value * _MEM_UNITS.get(unit, 1)
    return bytes_ / (2**30)


def _parse_cpu(cpu: str) -> float:
    """``"1"`` / ``"1000m"`` -> vCPU float. Cloud Run Admin API v2's
    ``resources.limits.cpu`` format."""
    cpu = (cpu or "").strip()
    if cpu.endswith("m"):
        try:
            return float(cpu[:-1]) / 1000.0
        except ValueError:
            return 0.0
    try:
        return float(cpu)
    except ValueError:
        return 0.0


def _service_config(session, project: str, region: str, service: str) -> dict:
    """Real CPU/memory/min-instances for one Cloud Run service, via the
    Cloud Run Admin API v2 (the REST equivalent of
    ``gcloud run services describe``)."""
    url = (
        f"https://run.googleapis.com/v2/projects/{project}/locations/"
        f"{region}/services/{service}"
    )
    resp = session.get(url, timeout=10)
    resp.raise_for_status()
    data = resp.json()
    container = (data.get("template", {}).get("containers") or [{}])[0]
    limits = container.get("resources", {}).get("limits", {})
    scaling = data.get("template", {}).get("scaling", {})
    return {
        "cpu": _parse_cpu(limits.get("cpu", "1")),
        "memory_gib": _parse_memory_gib(limits.get("memory", "512Mi")),
        "min_instances": int(scaling.get("minInstanceCount", 0) or 0),
        "max_instances": int(scaling.get("maxInstanceCount", 0) or 0),
    }


def _billable_instance_seconds(
    session, project: str, service: str, days: int
) -> float:
    """Real usage: sum of
    ``run.googleapis.com/container/billable_instance_time`` (seconds) across
    every revision of ``service`` over the last ``days`` days — the exact
    metric Cloud Run's own compute billing is based on. Verified live
    against this project (2026-09-19)."""
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=days)
    url = f"https://monitoring.googleapis.com/v3/projects/{project}/timeSeries"
    params = {
        "filter": (
            'metric.type="run.googleapis.com/container/billable_instance_time"'
            f' AND resource.labels.service_name="{service}"'
        ),
        "interval.startTime": start.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "interval.endTime": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "aggregation.alignmentPeriod": f"{days * 86400}s",
        "aggregation.perSeriesAligner": "ALIGN_SUM",
        "aggregation.crossSeriesReducer": "REDUCE_SUM",
        "aggregation.groupByFields": "resource.label.service_name",
    }
    resp = session.get(url, params=params, timeout=15)
    resp.raise_for_status()
    data = resp.json()
    total = 0.0
    for series in data.get("timeSeries", []):
        for point in series.get("points", []):
            total += float(point.get("value", {}).get("doubleValue", 0) or 0)
    return total


def cloud_run_estimate(days: int = 30) -> dict:
    """Per-service estimated Cloud Run compute cost for the last ``days``
    days: real CPU/memory config + real billable-instance-time usage,
    against Cloud Run's published Tier 1 rate. Request-count billing (also
    real, also published, but a separate small line item with its own
    monthly free tier) is intentionally excluded to keep this to the
    dominant compute cost rather than overclaim precision.

    Best-effort per service: one service's API failure doesn't blank the
    other's real numbers.
    """
    project = CONFIG.project_id
    region = "us-central1"
    services: list[dict] = []
    total_usd = 0.0
    if not project:
        return {
            "available": False,
            "error": "No GOOGLE_CLOUD_PROJECT configured.",
            "services": [],
            "period_days": days,
        }

    try:
        session = _authorized_session()
    except Exception as exc:  # noqa: BLE001
        logger.exception("Cloud Run cost estimate: auth failed")
        return {
            "available": False,
            "error": f"{type(exc).__name__}: {exc}",
            "services": [],
            "period_days": days,
        }

    for service in CLOUD_RUN_SERVICES:
        try:
            cfg = _service_config(session, project, region, service)
            seconds = _billable_instance_seconds(session, project, service, days)
            usd = seconds * (
                cfg["cpu"] * CLOUD_RUN_VCPU_SEC_USD
                + cfg["memory_gib"] * CLOUD_RUN_GIB_SEC_USD
            )
            total_usd += usd
            services.append(
                {
                    "service": service,
                    "available": True,
                    "cpu": cfg["cpu"],
                    "memory_gib": cfg["memory_gib"],
                    "min_instances": cfg["min_instances"],
                    "billable_instance_seconds": round(seconds, 1),
                    "estimated_usd": round(usd, 4),
                }
            )
        except Exception as exc:  # noqa: BLE001
            logger.exception("Cloud Run cost estimate failed for %s", service)
            services.append(
                {"service": service, "available": False, "error": f"{type(exc).__name__}: {exc}"}
            )

    return {
        "available": True,
        "services": services,
        "total_estimated_usd": round(total_usd, 4),
        "period_days": days,
        "pricing_source": CLOUD_RUN_PRICING_SOURCE,
        "note": (
            "Estimated from real CPU/memory config (Cloud Run Admin API) and "
            "real billable-instance-time usage (Cloud Monitoring) against "
            "Cloud Run's published Tier 1 rate. Compute only — Cloud Run "
            "request-count billing not included."
        ),
    }


def artifact_registry_estimate() -> dict:
    """Estimated Artifact Registry storage cost: real per-repository size
    (bytes) via the Artifact Registry API, against the published
    per-GB-month storage rate. Best-effort per repo."""
    project = CONFIG.project_id
    if not project:
        return {"available": False, "error": "No GOOGLE_CLOUD_PROJECT configured.", "repos": []}

    try:
        session = _authorized_session()
    except Exception as exc:  # noqa: BLE001
        logger.exception("Artifact Registry cost estimate: auth failed")
        return {"available": False, "error": f"{type(exc).__name__}: {exc}", "repos": []}

    repos: list[dict] = []
    total_gb = 0.0
    for name, location in ARTIFACT_REGISTRY_REPOS:
        url = (
            f"https://artifactregistry.googleapis.com/v1/projects/{project}"
            f"/locations/{location}/repositories/{name}"
        )
        try:
            resp = session.get(url, timeout=10)
            resp.raise_for_status()
            size_bytes = float(resp.json().get("sizeBytes", 0) or 0)
            gb = size_bytes / (1000**3)  # GCP bills decimal GB for storage
            total_gb += gb
            repos.append(
                {"repo": name, "location": location, "available": True, "size_gb": round(gb, 4)}
            )
        except Exception as exc:  # noqa: BLE001
            logger.exception("Artifact Registry size fetch failed for %s", name)
            repos.append(
                {"repo": name, "location": location, "available": False, "error": f"{type(exc).__name__}: {exc}"}
            )

    billable_gb = max(0.0, total_gb - ARTIFACT_REGISTRY_FREE_GB)
    estimated_usd = billable_gb * ARTIFACT_REGISTRY_GB_MONTH_USD
    return {
        "available": True,
        "repos": repos,
        "total_size_gb": round(total_gb, 4),
        "estimated_usd_per_month": round(estimated_usd, 4),
        "pricing_source": ARTIFACT_REGISTRY_PRICING_SOURCE,
        "note": (
            f"First {ARTIFACT_REGISTRY_FREE_GB} GB/month free, then "
            f"${ARTIFACT_REGISTRY_GB_MONTH_USD}/GB/month, applied to real "
            "repository sizes."
        ),
    }
