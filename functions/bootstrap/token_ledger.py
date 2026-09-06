"""Per-user Gemini token accounting + cap.

Every Gemini call the user's activity drives — text chat with Ayma, icebreaker
generation, the matching skill, wiki ingest, and the Gemini Live voice session
(recorded by the agent worker) — adds its token count to
``users/{uid}.token_usage``:

    token_usage: {
      total: <int>,
      features: { chat: <int>, voice: <int>, icebreakers: <int>,
                  matching: <int>, wiki: <int>, ... },
      updated_at: <server ts>
    }

At/above ``CONFIG.token_cap_per_user`` (default 100_000) further metered calls
raise :class:`TokenCapExceeded`; callers turn that into a friendly message.
Recording is best-effort and never raises.

The client shows spend as **credits**, a pure display layer over ``total``:
``credits_used = ceil(total / CONFIG.tokens_per_credit)`` and
``credits_remaining = grant - credits_used``, where ``grant`` is
``users/{uid}.credit_grant`` if set (paid tiers) else
``CONFIG.credits_free_grant``. Nothing is stored per credit — see
:func:`credits` / :func:`usage`.
"""

from __future__ import annotations

import logging

from config import CONFIG
from db import get_db

logger = logging.getLogger("ayma.tokens")

_FIELD = "token_usage"

# Feature labels — keep stable, they surface in the client breakdown.
FEATURE_CHAT = "chat"
FEATURE_VOICE = "voice"
FEATURE_ICEBREAKERS = "icebreakers"
FEATURE_MATCHING = "matching"
FEATURE_WIKI = "wiki"


class TokenCapExceeded(RuntimeError):
    """Raised before a metered Gemini call when the user is at their cap."""


def _usage_from_response(response) -> int:
    """Total tokens for one ``google-genai`` response (0 if unavailable)."""
    meta = getattr(response, "usage_metadata", None)
    if meta is None:
        return 0
    total = getattr(meta, "total_token_count", None)
    if total is not None:
        return int(total)
    got = getattr(meta, "prompt_token_count", 0) or 0
    got += getattr(meta, "candidates_token_count", 0) or 0
    return int(got)


def add(uid: str, feature: str, tokens: int) -> None:
    """Add ``tokens`` to the user's total and the per-feature bucket."""
    if not uid or tokens <= 0:
        return
    try:
        from firebase_admin import firestore

        get_db().collection("users").document(uid).set(
            {
                _FIELD: {
                    "total": firestore.Increment(tokens),
                    "features": {feature: firestore.Increment(tokens)},
                    "updated_at": firestore.SERVER_TIMESTAMP,
                }
            },
            merge=True,
        )
    except Exception:  # noqa: BLE001 - metering must never break a request
        logger.exception("token add failed for %s/%s", uid, feature)


def record(uid: str | None, feature: str, response) -> None:
    """Extract the token count from a ``google-genai`` response and add it."""
    if not uid:
        return
    add(uid, feature, _usage_from_response(response))


def _read(uid: str) -> dict:
    snap = get_db().collection("users").document(uid).get()
    data = (snap.to_dict() or {}) if snap.exists else {}
    u = data.get(_FIELD) or {}
    grant = data.get("credit_grant")
    return {
        "total": int(u.get("total", 0) or 0),
        "features": {k: int(v) for k, v in (u.get("features") or {}).items()},
        # Per-user credit grant override (paid tiers); None -> the free grant.
        "grant": int(grant) if grant is not None else None,
    }


def _ceil_div(n: int, d: int) -> int:
    return -(-n // d) if d > 0 else 0


def credit_costs() -> dict:
    """Shown per-action credit estimates for token-intensive buttons. Only
    actions that spend Gemini tokens are listed — Pass-1 pool matching is
    heuristic-only and free, so it isn't here. Tunable via ``CREDIT_COST_*``
    env vars; the true spend still lands in the ledger."""
    return {
        "match_score": CONFIG.credit_cost_match_score,
    }


def credits(uid: str) -> dict:
    """The user-facing credit view derived from token usage:
    ``{grant, used, remaining}``. Free plan unless the user doc carries a
    ``credit_grant`` override."""
    u = _read(uid)
    ratio = max(1, CONFIG.tokens_per_credit)
    grant = u["grant"] if u["grant"] is not None else CONFIG.credits_free_grant
    used = _ceil_div(u["total"], ratio)
    return {
        "grant": grant,
        "used": used,
        "remaining": max(0, grant - used),
    }


def check(uid: str | None) -> None:
    """Raise :class:`TokenCapExceeded` if the user is at/over their cap."""
    if not uid:
        return
    try:
        total = _read(uid)["total"]
    except Exception:  # noqa: BLE001
        logger.exception("token check read failed for %s", uid)
        return
    if total >= CONFIG.token_cap_per_user:
        raise TokenCapExceeded(
            f"token cap reached ({total}/{CONFIG.token_cap_per_user})"
        )


def usage(uid: str) -> dict:
    """The client-facing view: raw token accounting plus the derived credit
    balance and the per-action credit costs.

    ``{total, cap, remaining, features, credits: {grant, used, remaining},
       tokens_per_credit, costs: {match_score, run_matching}}``
    """
    u = _read(uid)
    cap = CONFIG.token_cap_per_user
    ratio = max(1, CONFIG.tokens_per_credit)
    grant = u["grant"] if u["grant"] is not None else CONFIG.credits_free_grant
    used = _ceil_div(u["total"], ratio)
    return {
        "total": u["total"],
        "cap": cap,
        "remaining": max(0, cap - u["total"]),
        "features": u["features"],
        "credits": {
            "grant": grant,
            "used": used,
            "remaining": max(0, grant - used),
        },
        "tokens_per_credit": ratio,
        "costs": credit_costs(),
    }
