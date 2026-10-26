"""Plans, pools and the RevenueCat webhook (founder-approved monetization).

All balances are tracked internally in **USD of real token cost**
(``users/{uid}.token_usage.cost_usd`` is the one meter); clients only ever see
**credits** (``CONFIG.credits_per_usd``, 1 credit = $0.01). Nothing here is
surfaced to a client in dollars.

State lives in ``users/{uid}.billing``::

    initialized: bool
    plan: "free" | "plus" | "pro" | "max"
    init_cost_usd: meter value when billing was initialised (spend before it
                   is forgiven — this is what makes grandfathering safe)
    legacy_bonus_usd: grandfathered balance of the pre-USD credit system
    paid_spent_closed_usd: spend attributed to already-closed paid periods
    period_start_cost_usd / period_end / pool_usd / product_id: open paid period
    cancel_at_period_end / billing_issue: informational flags
    is_trial: the open paid period is a store free trial (period_end is the
                   trial end); trial_used: a trial was ever granted (kept
                   forever — one trial per account)
    daily_day / daily_base_free_usd: free-plan daily-allowance marker
    start_grant_unlocked: the one-time start grant is only usable once the
                   account has a verified phone/email AND a completed
                   verification selfie (anti-abuse); until then only the daily
                   allowance applies. Absent on accounts initialised before
                   this gate == unlocked.
    credits_updated_at: when credits were last added to the account (initial
                   start grant, selfie unlock, daily-allowance rollover, plan
                   grant/renewal, expiry back to free) — the "since last
                   credit update" period start. Top-ups/admin credits stamp
                   the top-level ``credits_updated_at`` instead.
    start_grant_blocked: the selfie matched another grant-holding account
                   (duplicate); the grant stays withheld permanently.

Meter arithmetic (no per-call write beyond the existing ``cost_usd``
Increment): free-plan spend ``F = cost_usd - init_cost - paid_closed - open
paid segment``. Free pool = start grant + legacy bonus + top-up bonus, drawn
first; then the daily allowance, ``daily_used = F - max(pool, F at the start
of today)`` (UTC day, no rollover — the base resets every day). A paid user
has no daily allowance, only ``pool_usd - (cost_usd - period_start_cost)``.
When a paid period ends without renewal (``period_end`` + grace passed, or an
EXPIRATION webhook) the open segment is closed into ``paid_closed`` and the
account is free again; the start grant is NOT re-granted because ``F`` keeps
counting from ``init_cost`` forever.

Known limit: ``cost_usd`` only counts priced calls (image *output* tokens are
unpriced, see ``token_ledger._MODEL_PRICING``), so those are free to the user.
"""

from __future__ import annotations

import hmac
import logging
import math
from datetime import datetime, timedelta, timezone

from config import PLAN_FREE, PLAN_TIERS, PRODUCT_TO_PLAN, Config

logger = logging.getLogger("ayma.billing")

# The pre-USD free grant (credits). Used ONLY to grandfather existing
# accounts that never had a per-user ``credit_grant`` override.
_LEGACY_FREE_GRANT_CREDITS = 100

_EVENTS_COLLECTION = "billing_events"


def _cost(data: dict) -> float:
    return float((data.get("token_usage") or {}).get("cost_usd", 0) or 0)


def _legacy_bonus_usd(data: dict, cfg: Config) -> float:
    """USD value of an existing account's remaining pre-USD credits, keeping
    credit *face value* (1 old credit == 1 new credit). Brand-new accounts
    (no usage, no overrides) get 0 — the start grant covers them."""
    u = data.get("token_usage") or {}
    grant = data.get("credit_grant")
    added = int(data.get("credits_added", 0) or 0)
    total = int(u.get("total", 0) or 0)
    if not (total or grant is not None or added):
        return 0.0
    old_grant = int(grant) if grant is not None else _LEGACY_FREE_GRANT_CREDITS
    ratio = max(1, cfg.tokens_per_credit)
    used = -(-total // ratio)
    remaining = max(0, old_grant + added - used)
    return remaining / max(1, cfg.credits_per_usd)


def _settle(b: dict, cost: float) -> None:
    """Close the open paid period into ``paid_spent_closed_usd`` and fall back
    to the free plan (in place)."""
    open_spent = max(0.0, cost - float(b.get("period_start_cost_usd") or 0.0))
    b["paid_spent_closed_usd"] = float(b.get("paid_spent_closed_usd") or 0.0) + open_spent
    b["plan"] = PLAN_FREE
    for k in (
        "period_start_cost_usd", "period_end", "pool_usd", "product_id",
        "cancel_at_period_end", "billing_issue", "is_trial",
    ):
        b[k] = None
    b["daily_day"] = None


def free_spend(b: dict, cost: float) -> float:
    """Spend charged to the free plan so far (USD)."""
    open_spent = 0.0
    if b.get("plan") != PLAN_FREE:
        open_spent = max(0.0, cost - float(b.get("period_start_cost_usd") or 0.0))
    return max(
        0.0,
        cost
        - float(b.get("init_cost_usd") or 0.0)
        - float(b.get("paid_spent_closed_usd") or 0.0)
        - open_spent,
    )


def needs_verification(data: dict) -> bool:
    """True while the start grant is (or will be, on lazy init) locked, i.e.
    the caller should look up whether the account is verified."""
    b = data.get("billing") or {}
    if b.get("start_grant_blocked"):
        return False
    return not b.get("initialized") or b.get("start_grant_unlocked") is False


def normalize(
    data: dict, now: datetime, cfg: Config, verified: bool = True
) -> tuple[dict, bool]:
    """``(billing, changed)`` — the user's billing map with lazy initialisation
    (grandfathering), paid-period expiry and the daily-allowance day rollover
    applied. ``verified`` says whether the account has a verified phone or
    email; it unlocks the start grant (once unlocked it stays unlocked).
    Pure; the caller persists it when ``changed``."""
    cost = _cost(data)
    b = dict(data.get("billing") or {})
    changed = False
    if not b.get("initialized"):
        b.update(
            initialized=True, plan=PLAN_FREE, init_cost_usd=cost,
            legacy_bonus_usd=_legacy_bonus_usd(data, cfg),
            paid_spent_closed_usd=0.0, start_grant_unlocked=bool(verified),
            credits_updated_at=now,
        )
        changed = True
    elif (
        verified
        and b.get("start_grant_unlocked") is False
        and not b.get("start_grant_blocked")
    ):
        b["start_grant_unlocked"] = True
        b["credits_updated_at"] = now
        changed = True
    if b.get("plan") != PLAN_FREE:
        end = b.get("period_end")
        grace = timedelta(seconds=cfg.billing_expiry_grace_seconds)
        if end is None or now >= end + grace:
            _settle(b, cost)
            changed = True
    if b.get("plan") == PLAN_FREE:
        today = now.astimezone(timezone.utc).strftime("%Y-%m-%d")
        if b.get("daily_day") != today:
            b["daily_day"] = today
            b["daily_base_free_usd"] = free_spend(b, cost)
            b["credits_updated_at"] = now
            changed = True
    return b, changed


def balance(data: dict, b: dict, cfg: Config) -> dict:
    """Internal USD balance for an already-normalised ``b``:
    ``{plan, remaining_usd, daily_remaining_usd, plan_pool_usd, bonus_usd}``."""
    cost = _cost(data)
    if b.get("plan") != PLAN_FREE:
        pool = float(b.get("pool_usd") or 0.0)
        spent = max(0.0, cost - float(b.get("period_start_cost_usd") or 0.0))
        return {
            "plan": b["plan"], "remaining_usd": max(0.0, pool - spent),
            "daily_remaining_usd": 0.0, "plan_pool_usd": pool, "bonus_usd": 0.0,
        }
    credits_added = int(data.get("credits_added", 0) or 0)
    bonus = credits_added / max(1, cfg.credits_per_usd)
    grant = cfg.free_start_grant_usd if b.get("start_grant_unlocked", True) else 0.0
    base_pool = grant + float(b.get("legacy_bonus_usd") or 0.0)
    pool = base_pool + bonus
    f = free_spend(b, cost)
    start_remaining = max(0.0, pool - f)
    base = float(b.get("daily_base_free_usd") or 0.0)
    daily_used = max(0.0, f - max(pool, base))
    daily_remaining = max(0.0, cfg.free_daily_allowance_usd - daily_used)
    return {
        # The allowance only comes into play once the start grant is spent.
        "plan": PLAN_FREE,
        "remaining_usd": start_remaining if start_remaining > 0 else daily_remaining,
        "daily_remaining_usd": daily_remaining, "plan_pool_usd": base_pool,
        "bonus_usd": bonus, "start_remaining_usd": start_remaining,
        "free_spend_usd": f, "pool_usd": pool,
    }


# --- RevenueCat webhook ------------------------------------------------------

_GRANT_EVENTS = {"INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "PRODUCT_CHANGE"}


def authorized(header: str | None, cfg: Config) -> bool:
    """Constant-time check of the webhook ``Authorization`` header against the
    shared secret (raw value or ``Bearer <value>``). Fails closed when the
    secret isn't provisioned."""
    expected = cfg.revenuecat_webhook_secret
    if not expected or not header:
        return False
    token = header.strip()
    if token.lower().startswith("bearer "):
        token = token[7:].strip()
    return hmac.compare_digest(token, expected)


def _ms(value) -> datetime | None:
    try:
        return datetime.fromtimestamp(int(value) / 1000, tz=timezone.utc)
    except (TypeError, ValueError, OverflowError, OSError):
        return None


def _plan_for(product_id: str | None) -> str | None:
    if not product_id:
        return None
    return PRODUCT_TO_PLAN.get(str(product_id).split(":", 1)[0])


class UnknownUser(Exception):
    """The event's ``app_user_id`` has no ``users/{uid}`` doc (yet)."""


def _apply(db, uid: str, ev: dict, cfg: Config, now: datetime) -> str:
    etype = ev.get("type")
    ref = db.collection("users").document(uid)
    snap = ref.get()
    if not snap.exists:
        raise UnknownUser(uid)
    data = snap.to_dict() or {}
    b, _ = normalize(data, now, cfg)
    cost = _cost(data)
    expires = _ms(ev.get("expiration_at_ms"))

    if etype in _GRANT_EVENTS:
        plan = _plan_for(ev.get("new_product_id") if etype == "PRODUCT_CHANGE" else None) \
            or _plan_for(ev.get("product_id"))
        if plan is None or expires is None:
            return "ignored_unknown_product"
        tier = PLAN_TIERS[plan]
        current_end = b.get("period_end")
        if b.get("plan") != PLAN_FREE and current_end is not None:
            if expires < current_end:
                return "ignored_stale"
            if etype == "PRODUCT_CHANGE" and tier.pool_usd <= float(b.get("pool_usd") or 0):
                b["pending_plan"] = plan  # downgrade: applies at the next RENEWAL
                ref.set({"billing": b}, merge=True)
                return "downgrade_deferred"
            if etype == "UNCANCELLATION" and plan == b.get("plan") and expires == current_end:
                b["cancel_at_period_end"] = False
                ref.set({"billing": b}, merge=True)
                return "uncancelled"
        if b.get("plan") != PLAN_FREE:
            b["paid_spent_closed_usd"] = float(b.get("paid_spent_closed_usd") or 0.0) + max(
                0.0, cost - float(b.get("period_start_cost_usd") or 0.0)
            )
        is_trial = str(ev.get("period_type") or "").upper() == "TRIAL"
        pool = float(tier.pool_usd)
        if is_trial and etype == "INITIAL_PURCHASE":
            if b.get("trial_used"):
                return "ignored_trial_repeat"  # one trial per uid, ever
            b["trial_used"] = True
            if plan == "pro":
                pool = cfg.pro_trial_credits / max(1, cfg.credits_per_usd)
        b.update(
            plan=plan, product_id=tier.product_id, pool_usd=pool,
            period_start_cost_usd=cost, period_end=expires, is_trial=is_trial,
            cancel_at_period_end=False, billing_issue=False, pending_plan=None,
            credits_updated_at=now,
        )
        ref.set({"billing": b}, merge=True)
        return f"granted_{plan}_trial" if is_trial else f"granted_{plan}"

    if etype == "CANCELLATION":
        if b.get("plan") != PLAN_FREE:
            b["cancel_at_period_end"] = True  # runs to period end, no revoke
            ref.set({"billing": b}, merge=True)
        return "cancel_noted"

    if etype == "BILLING_ISSUE":
        if b.get("plan") != PLAN_FREE:
            b["billing_issue"] = True  # access continues until period end
            ref.set({"billing": b}, merge=True)
        return "billing_issue_noted"

    if etype == "EXPIRATION":
        current_end = b.get("period_end")
        if b.get("plan") == PLAN_FREE:
            return "already_free"
        if expires is not None and current_end is not None and expires < current_end:
            return "ignored_stale"
        _settle(b, cost)
        b["daily_day"] = now.astimezone(timezone.utc).strftime("%Y-%m-%d")
        b["daily_base_free_usd"] = free_spend(b, cost)
        b["credits_updated_at"] = now
        ref.set({"billing": b}, merge=True)
        return "expired_to_free"

    return "ignored_type"


def handle_event(db, payload: dict, cfg: Config, now: datetime | None = None) -> str:
    """Apply one RevenueCat webhook payload; returns a short status string.
    Idempotent on ``event.id`` (a ``billing_events/{id}`` marker is created
    first; a retry of a failed apply removes it so RevenueCat's redelivery is
    processed). ``app_user_id`` is the Firebase uid. Raises
    :class:`UnknownUser` (-> non-2xx so RevenueCat retries) when the user doc
    doesn't exist."""
    from google.api_core.exceptions import AlreadyExists

    now = now or datetime.now(timezone.utc)
    ev = (payload or {}).get("event") or {}
    event_id = str(ev.get("id") or "")
    uid = str(ev.get("app_user_id") or "")
    if not event_id or not uid:
        return "ignored_malformed"
    if uid.startswith("$RCAnonymousID"):
        return "ignored_anonymous"
    marker = db.collection(_EVENTS_COLLECTION).document(event_id)
    try:
        marker.create({"uid": uid, "type": ev.get("type"), "received_at": now})
    except AlreadyExists:
        return "duplicate"
    try:
        status = _apply(db, uid, ev, cfg, now)
    except Exception:
        try:
            marker.delete()
        except Exception:  # noqa: BLE001
            logger.exception("could not clear webhook marker %s", event_id)
        raise
    logger.info("revenuecat event %s type=%s uid=%s -> %s",
                event_id, ev.get("type"), uid, status)
    return status


def credits_for(usd: float, cfg: Config) -> int:
    """USD (internal) -> whole client-facing credits, rounded up so a positive
    balance never displays as 0."""
    return max(0, math.ceil(usd * max(1, cfg.credits_per_usd) - 1e-6))
