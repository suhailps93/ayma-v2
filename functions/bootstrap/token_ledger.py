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
    return {
        "total": int(u.get("total", 0) or 0),
        "features": {k: int(v) for k, v in (u.get("features") or {}).items()},
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
    """The client-facing view: ``{total, cap, remaining, features}``."""
    u = _read(uid)
    cap = CONFIG.token_cap_per_user
    return {
        "total": u["total"],
        "cap": cap,
        "remaining": max(0, cap - u["total"]),
        "features": u["features"],
    }
