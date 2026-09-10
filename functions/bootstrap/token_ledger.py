"""Per-user Gemini token accounting + a credit balance.

Every Gemini call the user's activity drives — text chat with Ayma, icebreaker
generation, the matching skill, wiki ingest, natural-language Explore parsing,
Ayma's background check-in, and the Gemini Live voice session (recorded by the
agent worker) — adds its token count to ``users/{uid}.token_usage``:

    token_usage: {
      total: <int>,
      features: { chat: <int>, voice: <int>, matching: <int>, wiki: <int>,
                  explore: <int>, reengage: <int>, ... },
      updated_at: <server ts>
    }

Spend is shown to the user as **credits**:
``used = ceil(total / CONFIG.tokens_per_credit)``,
``remaining = grant + added - used``, where ``grant`` is
``users/{uid}.credit_grant`` if set (paid tiers) else ``CONFIG.credits_free_grant``
and ``added`` is ``users/{uid}.credits_added`` (the running sum of top-ups —
free reloads for now, see :func:`topup`).

:func:`check` raises :class:`TokenCapExceeded` once ``remaining`` hits 0; a
top-up clears it. Recording is best-effort and never raises.
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
FEATURE_EXPLORE = "explore"  # natural-language Explore search parsing
FEATURE_REENGAGE = "reengage"  # Ayma's background check-in message
FEATURE_DEEPDIVE = "deepdive"  # web deep-dive research on a named person
FEATURE_FACE_REPORT = "face_report"  # honest facial-beauty analysis of a photo
FEATURE_BODY_REPORT = "body_report"  # honest physique analysis of a photo
FEATURE_PHYSICAL_ATTRS = "physical_attrs"  # structured physical-profile extraction
FEATURE_COMPLETENESS = "completeness"  # profile-completeness narrative coverage pass

_CREDITS_ADDED_FIELD = "credits_added"  # top-of-doc int, bumped by top-ups


class TokenCapExceeded(RuntimeError):
    """Raised before a metered Gemini call when the user is out of credits."""


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
        # Credits added by top-ups (free reloads for now).
        "added": int(data.get(_CREDITS_ADDED_FIELD, 0) or 0),
    }


def _ceil_div(n: int, d: int) -> int:
    return -(-n // d) if d > 0 else 0


def _credit_view(u: dict) -> dict:
    """`{grant, added, used, remaining}` from a :func:`_read` result — the one
    place the credit sum is computed. ``remaining = grant + added - used``."""
    ratio = max(1, CONFIG.tokens_per_credit)
    grant = u["grant"] if u["grant"] is not None else CONFIG.credits_free_grant
    added = int(u.get("added", 0) or 0)
    used = _ceil_div(u["total"], ratio)
    return {
        "grant": grant,
        "added": added,
        "used": used,
        "remaining": max(0, grant + added - used),
    }


def topup(uid: str, amount: int) -> dict:
    """Reload the balance so the user has **at least ``amount`` usable credits**
    afterwards. A heavy user can be far past their grant (``used`` >> ``grant``
    + ``added``); a plain ``+amount`` would leave ``remaining`` stuck at 0, so a
    reload first forgives that overspend, then adds ``amount``:

        new_added = max(added + amount, used - grant + amount)

    -> ``remaining`` becomes exactly ``amount`` for a broke user, and ``+amount``
    for anyone still in the black. Best-effort; returns the fresh credit view.
    """
    if not uid or amount <= 0:
        return credits(uid) if uid else {}
    try:
        from firebase_admin import firestore

        u = _read(uid)
        view = _credit_view(u)
        new_added = max(view["added"] + amount, view["used"] - view["grant"] + amount)
        get_db().collection("users").document(uid).set(
            {
                _CREDITS_ADDED_FIELD: int(new_added),
                "credits_updated_at": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
    except Exception:  # noqa: BLE001 - a failed top-up must not 500 the request
        logger.exception("credit top-up failed for %s (+%s)", uid, amount)
    return credits(uid)


def credit_costs() -> dict:
    """Shown per-action credit estimates for token-intensive buttons. Only
    actions that spend Gemini tokens are listed — Pass-1 pool matching is
    heuristic-only and free, so it isn't here. Tunable via ``CREDIT_COST_*``
    env vars; the true spend still lands in the ledger."""
    return {
        "match_score": CONFIG.credit_cost_match_score,
    }


def credits(uid: str) -> dict:
    """The user-facing credit view: ``{grant, added, used, remaining}``. Free
    plan unless the user doc carries a ``credit_grant`` override; ``added`` is
    the sum of top-ups."""
    return _credit_view(_read(uid))


def check(uid: str | None) -> None:
    """Raise :class:`TokenCapExceeded` when the user has no credits left
    (``grant + added - used <= 0``). Topping up clears it."""
    if not uid:
        return
    try:
        remaining = _credit_view(_read(uid))["remaining"]
    except Exception:  # noqa: BLE001
        logger.exception("credit check read failed for %s", uid)
        return
    if remaining <= 0:
        raise TokenCapExceeded(f"out of credits (uid={uid})")


def usage(uid: str) -> dict:
    """The client-facing view: raw lifetime token accounting (total + a
    per-feature breakdown across chat / voice / matching / wiki / explore /
    reengage) plus the derived credit balance and per-action credit costs.
    """
    u = _read(uid)
    cred = _credit_view(u)
    return {
        "total": u["total"],
        "cap": CONFIG.token_cap_per_user,
        "remaining": max(0, CONFIG.token_cap_per_user - u["total"]),
        "features": u["features"],
        "credits": cred,
        "tokens_per_credit": max(1, CONFIG.tokens_per_credit),
        "costs": credit_costs(),
    }
