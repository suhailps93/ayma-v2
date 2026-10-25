"""Per-vendor cost tracking for the admin dashboard (``GET /admin/vendors``,
``POST /admin/vendor-spend``).

Every paid vendor Ayma uses is listed in ``vendor_catalog.json`` (static
metadata: billing unit, scaling, "how to check" steps and billing link).
A vendor's value comes from one of two places, never from a guess:

* **API** - pulled live from the provider (Cloud Billing export, LiveKit
  Analytics) via ``provider_spend.snapshot()``.
* **Muse** - entries an LLM browser agent posts daily to
  ``POST /admin/vendor-spend`` after reading the vendor's billing page. They
  are stored in the Firestore ``vendor_spend`` collection, one document per
  ``(vendor, metric)``, always carrying ``source_url`` and ``fetched_at``.

A vendor with neither shows ``unavailable`` and the reason. Values older than
``STALE_AFTER_HOURS`` are flagged stale. Admin-only; users only ever see credits.
"""

from __future__ import annotations

import json
import logging
import math
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

logger = logging.getLogger("ayma.vendor_spend")

COLLECTION = "vendor_spend"
STALE_AFTER_HOURS = 36
CATALOG_PATH = Path(__file__).with_name("vendor_catalog.json")
COLLECTED_BY = ("api", "muse")
_FIELDS = {
    "vendor", "metric", "amount", "currency", "period",
    "source_url", "collected_by", "fetched_at", "note",
}
_REQUIRED = _FIELDS - {"note"}
_METRIC_RE = re.compile(r"^[a-z0-9_]{1,48}$")
_CURRENCY_RE = re.compile(r"^[A-Za-z]{3,12}$")
_URL_RE = re.compile(r"^https?://\S+$")
_FUTURE_SKEW = timedelta(minutes=5)


class ValidationError(ValueError):
    """Raised for a rejected ``vendor_spend`` submission."""


def load_catalog() -> list[dict]:
    with CATALOG_PATH.open(encoding="utf-8") as fh:
        return json.load(fh)["vendors"]


def _parse_ts(value: str) -> datetime:
    try:
        ts = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValidationError("fetched_at must be an ISO-8601 timestamp") from exc
    if ts.tzinfo is None:
        raise ValidationError("fetched_at must include a timezone offset")
    return ts.astimezone(timezone.utc)


def validate(payload: Any, now: datetime | None = None) -> dict:
    """Return the cleaned document for a submission or raise ``ValidationError``."""
    now = now or datetime.now(timezone.utc)
    if not isinstance(payload, dict):
        raise ValidationError("body must be a JSON object")
    unknown = set(payload) - _FIELDS
    if unknown:
        raise ValidationError(f"unknown fields: {sorted(unknown)}")
    missing = sorted(k for k in _REQUIRED if payload.get(k) in (None, ""))
    if missing:
        raise ValidationError(f"missing required fields: {missing}")
    for key in _FIELDS - {"amount"}:
        if payload.get(key) is not None and not isinstance(payload[key], str):
            raise ValidationError(f"{key} must be a string")
    if payload["vendor"] not in {v["id"] for v in load_catalog()}:
        raise ValidationError("unknown vendor id (see vendor_catalog.json)")
    if not _METRIC_RE.match(payload["metric"]):
        raise ValidationError("metric must match [a-z0-9_]{1,48}")
    amount = payload["amount"]
    if (
        isinstance(amount, bool)
        or not isinstance(amount, (int, float))
        or not math.isfinite(amount)
    ):
        raise ValidationError("amount must be a finite number")
    if not _CURRENCY_RE.match(payload["currency"]):
        raise ValidationError("currency must be a 3-12 letter code or unit (e.g. USD)")
    if len(payload["period"]) > 64:
        raise ValidationError("period must be at most 64 characters")
    if not _URL_RE.match(payload["source_url"]) or len(payload["source_url"]) > 1024:
        raise ValidationError("source_url must be an http(s) URL")
    if payload["collected_by"] not in COLLECTED_BY:
        raise ValidationError("collected_by must be 'api' or 'muse'")
    fetched = _parse_ts(payload["fetched_at"])
    if fetched > now + _FUTURE_SKEW:
        raise ValidationError("fetched_at is in the future")
    note = payload.get("note") or ""
    if len(note) > 500:
        raise ValidationError("note must be at most 500 characters")
    return {
        "vendor": payload["vendor"],
        "metric": payload["metric"],
        "amount": float(amount),
        "currency": payload["currency"].upper(),
        "period": payload["period"],
        "source_url": payload["source_url"],
        "collected_by": payload["collected_by"],
        "fetched_at": fetched.isoformat(timespec="seconds"),
        "note": note,
        "recorded_at": now.isoformat(timespec="seconds"),
    }


def record(db, payload: Any) -> dict:
    """Validate and upsert the latest value for ``(vendor, metric)``."""
    doc = validate(payload)
    db.collection(COLLECTION).document(f"{doc['vendor']}__{doc['metric']}").set(doc)
    return doc


def is_stale(fetched_at: str | None, now: datetime) -> bool:
    if not fetched_at:
        return True
    try:
        return now - _parse_ts(fetched_at) > timedelta(hours=STALE_AFTER_HOURS)
    except ValidationError:
        return True


def _age_hours(fetched_at: str | None, now: datetime) -> float | None:
    if not fetched_at:
        return None
    try:
        return round((now - _parse_ts(fetched_at)).total_seconds() / 3600, 1)
    except ValidationError:
        return None


def stale_alerts(vendors: list[dict], catalog: list[dict], now: datetime) -> list[dict]:
    """Vendors needing attention: data older than the stale window, or no value
    for a reason other than "not used" / "no billing line"."""
    sources = {v["id"]: v["source"] for v in catalog}
    alerts = []
    for row in vendors:
        if row.get("status", "active") != "active" or sources[row["id"]].get("no_billing_line"):
            continue
        base = {
            "id": row["id"], "name": row["name"], "url": row["how_to_check"]["url"],
        }
        if not row["entries"]:
            alerts.append({
                **base, "kind": "unavailable", "age_hours": None,
                "reason": row.get("unavailable_reason", ""),
            })
            continue
        old = [e for e in row["entries"] if e["stale"]]
        if old:
            ages = [_age_hours(e["fetched_at"], now) for e in old]
            known = [a for a in ages if a is not None]
            alerts.append({
                **base, "kind": "stale",
                "age_hours": max(known) if known and len(known) == len(ages) else None,
                "reason": f"Data older than {STALE_AFTER_HOURS}h or with no fetch time.",
            })
    return alerts


def _entry(now, *, metric, amount, unit, period, method, fetched_at, source_url, note=""):
    return {
        "metric": metric, "amount": amount, "unit": unit, "period": period,
        "method": method, "fetched_at": fetched_at,
        "stale": is_stale(fetched_at, now), "source_url": source_url, "note": note,
    }


def _api_entries(vendor: dict, snap: dict, now: datetime) -> tuple[list[dict], str | None]:
    """Entries pulled live for this vendor, or ``([], reason)``."""
    source = vendor["source"]
    kind = source["type"]
    if kind == "billing_export":
        google = snap.get("google") or {}
        if not google.get("available"):
            return [], google.get("reason") or "Google Cloud billing export unavailable."
        names = set(source["services"])
        rows = [s for s in google.get("mtd_by_service", []) if s["service"] in names]
        cost = round(sum(r["cost"] for r in rows), 4)
        net = round(sum(r["net"] for r in rows), 4)
        common = dict(
            unit=google.get("currency", "USD"),
            period=f"{google['month_start']} to date",
            method="api",
            fetched_at=google.get("fetched_at") or snap.get("fetched_at"),
            source_url=vendor["how_to_check"]["url"],
            note="" if rows else "No billing lines for this service in the export this month.",
        )
        return [
            _entry(now, metric="mtd_cost", amount=cost, **common),
            _entry(now, metric="mtd_net_after_credits", amount=net, **common),
        ], None
    if kind == "livekit_api":
        lk = snap.get("livekit") or {}
        usage = lk.get("usage") or {}
        if not usage.get("available"):
            return [], usage.get("reason") or "LiveKit Analytics API unavailable."
        return [_entry(
            now, metric="participant_minutes", amount=usage["participant_minutes"],
            unit="minutes", period=f"{usage['window_start']} to date", method="api",
            fetched_at=lk.get("fetched_at") or snap.get("fetched_at"),
            source_url=vendor["how_to_check"]["url"], note=usage.get("note", ""),
        )], None
    return [], source.get("reason")


def build(db, snap: dict, now: datetime | None = None) -> dict:
    """Merge the static catalog, API figures and stored Muse entries."""
    now = now or datetime.now(timezone.utc)
    stored: dict[str, list[dict]] = {}
    for doc in db.collection(COLLECTION).stream():
        d = doc.to_dict() or {}
        stored.setdefault(d.get("vendor", ""), []).append(d)
    vendors = []
    catalog = load_catalog()
    for v in catalog:
        entries, api_reason = _api_entries(v, snap, now)
        api_metrics = {e["metric"] for e in entries}
        for d in sorted(stored.get(v["id"], []), key=lambda x: x.get("metric", "")):
            if d.get("metric") in api_metrics:
                continue
            entries.append(_entry(
                now, metric=d.get("metric"), amount=d.get("amount"),
                unit=d.get("currency"), period=d.get("period"),
                method="api" if d.get("collected_by") == "api" else "muse",
                fetched_at=d.get("fetched_at"), source_url=d.get("source_url"),
                note=d.get("note", ""),
            ))
        row = {k: v[k] for k in (
            "id", "name", "group", "billing_unit", "scales_with_users", "how_to_check",
        )}
        row["status"] = v.get("status", "active")
        row["status_note"] = v.get("status_note", "")
        row["entries"] = entries
        if not entries:
            row["unavailable_reason"] = v.get("status_note") or (
                api_reason
                if v["source"]["type"] != "none"
                else f"{v['source'].get('reason', '')} No value has been collected "
                "yet by the Muse daily routine."
            )
        vendors.append(row)
    return {
        "generated_at": now.isoformat(timespec="seconds"),
        "stale_after_hours": STALE_AFTER_HOURS,
        "stale": stale_alerts(vendors, catalog, now),
        "vendors": vendors,
    }
