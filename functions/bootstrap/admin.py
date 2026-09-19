"""Admin console data (ARCHITECTURE.md §14.3).

Read-only inspection over the final data model, gated by ``require_admin_password``
(§14.3) and served through the Admin SDK so it sees every tier, including
``ai_only`` wiki pages and ``deleted_accounts`` (§9.2).
"""

from __future__ import annotations

import infra_cost
import schema
import token_ledger

_USER_SCAN_LIMIT = 400
_LIST_LIMIT = 50

# Founder request, 2026-09-19: display what a 10%-margin pricing model would
# charge — "credits priced at 1.10x real infra cost" — on top of the real
# Gemini/AI cost_usd figure (the tracked-since-278c562 one, never a
# backfilled guess). DISPLAY ONLY: nothing actually bills a user yet — see
# revenue_usd/revenue_note above, which stays genuinely $0. This constant is
# not read by token_ledger.py or any charging path; it only shapes what the
# admin dashboard shows.
PRICING_MARKUP_RATE = 0.10


def _with_markup(cost_usd: float) -> dict:
    """``{cost_usd, profit_usd, billable_usd}`` for one real cost figure under
    the display-only 10%-markup pricing model — ``billable_usd = cost_usd *
    (1 + PRICING_MARKUP_RATE)``. Kept as three explicit, separately-labeled
    fields (never one blended number) per the same real-vs-estimated
    discipline the rest of this dashboard already follows."""
    cost_usd = round(cost_usd, 6)
    profit_usd = round(cost_usd * PRICING_MARKUP_RATE, 6)
    return {
        "cost_usd": cost_usd,
        "profit_usd": profit_usd,
        "billable_usd": round(cost_usd + profit_usd, 6),
    }


def _profile(db, uid: str) -> dict:
    snap = schema.profile_doc(db, uid).get()
    return snap.to_dict() or {} if snap.exists else {}


def _summary(db, uid: str, account: dict, profile: dict) -> dict:
    return {
        "uid": uid,
        "name": profile.get(schema.PF_NAME, ""),
        "community": account.get(schema.FIELD_COMMUNITY, ""),
        "session_mode": account.get(schema.FIELD_SESSION_MODE, ""),
        "paused": profile.get(schema.PF_PAUSED, False) is True,
        "trust_flags": len(account.get(schema.FIELD_TRUST_FLAGS) or []),
    }


def search_users(db, query: str) -> list[dict]:
    """Exact-uid hit first, then a bounded case-insensitive name-substring scan."""
    query = query.strip()
    if not query:
        return []
    out: list[dict] = []
    seen: set[str] = set()

    exact = db.collection(schema.USERS).document(query).get()
    if exact.exists:
        acct = exact.to_dict() or {}
        out.append(_summary(db, query, acct, _profile(db, query)))
        seen.add(query)

    needle = query.lower()
    for snap in db.collection(schema.USERS).limit(_USER_SCAN_LIMIT).stream():
        if snap.id in seen or len(out) >= _LIST_LIMIT:
            break
        prof = _profile(db, snap.id)
        if needle in str(prof.get(schema.PF_NAME, "")).lower():
            out.append(_summary(db, snap.id, snap.to_dict() or {}, prof))
            seen.add(snap.id)
    return out


def user_detail(db, uid: str) -> dict:
    account_snap = db.collection(schema.USERS).document(uid).get()
    account = account_snap.to_dict() or {} if account_snap.exists else {}
    profile = _profile(db, uid)

    wiki = []
    for s in schema.user_subcollection(db, uid, schema.WIKI_PAGES).stream():
        d = s.to_dict() or {}
        wiki.append({
            "page_id": s.id,
            "page_type": d.get("page_type", ""),
            "visibility": d.get("visibility", ""),
            "ai_body": d.get("ai_body", ""),
            "user_edits": d.get("user_edits", ""),
            "user_hidden": d.get("user_hidden", False) is True,
            "lint_flags": d.get("lint_flags") or [],
        })

    matches = []
    for s in (
        db.collection(schema.MATCHES_COLLECTION)
        .where("uids", "array_contains", uid)
        .limit(_LIST_LIMIT)
        .stream()
    ):
        d = s.to_dict() or {}
        matches.append({
            "match_id": s.id,
            "uids": d.get("uids", []),
            "status": d.get("status", ""),
            "score": d.get("score"),
        })

    threads = []
    for s in (
        db.collection(schema.DM_THREADS_COLLECTION)
        .where("participants", "array_contains", uid)
        .limit(_LIST_LIMIT)
        .stream()
    ):
        d = s.to_dict() or {}
        threads.append({
            "thread_id": s.id,
            "participants": d.get("participants", []),
            "last_message_at": str(d.get("last_message_at", "")),
            "hidden_for": d.get("hidden_for", []),
        })

    deleted_snap = db.collection(schema.DELETED_ACCOUNTS).document(uid).get()

    return {
        "uid": uid,
        "exists": account_snap.exists,
        "account": {
            k: account.get(k)
            for k in (
                schema.FIELD_SESSION_MODE, schema.FIELD_COMMUNITY,
                "marketing_turn_count", "interview_turn_count",
                schema.FIELD_LAST_ACTIVE_AT, "admin",
            )
        },
        "profile": profile,
        "trust_flags": account.get(schema.FIELD_TRUST_FLAGS) or [],
        "wiki_pages": wiki,
        "matches": matches,
        "dm_threads": threads,
        "deleted_account": deleted_snap.to_dict() if deleted_snap.exists else None,
    }


def finance_summary(db) -> dict:
    """Real infra-$ cost + token usage aggregate across users (§14.3 finance
    dashboard) — a bounded scan over ``users/{uid}`` (same ``_USER_SCAN_LIMIT``
    discipline as :func:`search_users`, so this never unbounded-reads the
    whole collection as the user base grows). Totals are summed over the
    scanned page; ``user_count``/``scanned_limit`` tell the caller whether the
    scan covered every user or was cut off.

    ``revenue_usd`` is genuinely ``0`` — the app is free during beta and no
    payments have been processed; it is never fabricated or estimated.

    ``cost_usd``/``total_cost_usd`` here are Gemini/AI token spend ONLY —
    see ``gemini_cost_tracking`` in the return value for the honest caveat
    (real $, but only since tracking began) and ``infra_cost.py`` /
    ``GET /admin/infra-costs`` for the separate LiveKit + GCP infra figures
    (founder request, 2026-09-19: never blend real/estimated/manual numbers
    into one misleading total).

    Each row and the total also carry a display-only 10%-markup pricing
    breakdown (``profit_usd``/``billable_usd`` alongside ``cost_usd`` — see
    :func:`_with_markup`/``PRICING_MARKUP_RATE``, founder request
    2026-09-19). Nothing actually charges this yet; ``revenue_usd`` stays
    genuinely ``0``.
    """
    rows: list[dict] = []
    total_cost = 0.0
    total_tokens = 0
    user_count = 0

    for snap in db.collection(schema.USERS).limit(_USER_SCAN_LIMIT).stream():
        data = snap.to_dict() or {}
        row = token_ledger.summary_from_doc(snap.id, data)
        total_cost += row["cost_usd"]
        total_tokens += row["total_tokens"]
        user_count += 1
        rows.append(row)

    rows.sort(key=lambda r: r["cost_usd"], reverse=True)
    top = rows[:_LIST_LIMIT]
    for row in top:
        row["name"] = _profile(db, row["uid"]).get(schema.PF_NAME, "")
        row.update(_with_markup(row["cost_usd"]))

    total_markup = _with_markup(total_cost)
    return {
        "total_cost_usd": total_markup["cost_usd"],
        "total_profit_usd": total_markup["profit_usd"],
        "total_billable_usd": total_markup["billable_usd"],
        "total_tokens": total_tokens,
        "user_count": user_count,
        "scanned_limit": _USER_SCAN_LIMIT,
        "users": top,
        "revenue_usd": 0,
        "revenue_note": "Free during beta — no payments processed yet.",
        "gemini_cost_tracking": infra_cost.gemini_tracking_info(),
        "pricing_markup_rate": PRICING_MARKUP_RATE,
        "pricing_markup_note": (
            "Display-only 10% margin model — billable_usd = cost_usd * 1.10. "
            "Nothing actually charges this yet."
        ),
    }


def infra_costs(db) -> dict:
    """LiveKit + GCP infra cost figures (§14.3 finance dashboard, founder
    request 2026-09-19) — deliberately separate from :func:`finance_summary`
    (a bounded per-user Firestore scan) since this calls out to LiveKit /
    Cloud Monitoring / Cloud Run / Artifact Registry APIs instead. Each
    figure is labeled by source/confidence (real API, estimated from real
    config + published pricing, or hand-entered) — see ``infra_cost.py``."""
    return {
        "gemini": infra_cost.gemini_tracking_info(),
        "livekit": infra_cost.livekit_cost(db),
        "gcp_compute": infra_cost.cloud_run_estimate(),
        "artifact_registry": infra_cost.artifact_registry_estimate(),
    }
