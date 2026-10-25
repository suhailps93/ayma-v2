"""Runtime provider routing: Google (Vertex / Developer API) vs LiveKit Inference.

Four feature groups — ``json`` (text JSON jobs), ``vision`` (JSON jobs with
images), ``chat`` and ``voice`` — each resolve to ``"vertex"`` or
``"inference"`` per call (per session for voice).

Source of truth, highest priority first:

1. The Firestore doc ``config/llm_routing`` (cached ``llm_routing_cache_seconds``,
   default 60 s), so a flip needs no redeploy::

       {"json":   {"provider": "inference", "percent": 25},
        "chat":   "vertex",
        "voice":  {"provider": "inference", "percent": 10},
        "fallback": true}

   A bare string is ``{"provider": <string>, "percent": 100}``. Missing groups
   fall through to the environment.
2. Environment / ``config.py``: ``LLM_ROUTE_<GROUP>`` (``vertex`` default),
   ``LLM_PERCENT_<GROUP>`` (default 100), ``VOICE_PROVIDER``,
   ``LLM_INFERENCE_FALLBACK``.

``percent`` is the share of calls sent to Inference when the provider is
``inference``; the rest stay on Google, which makes per-feature A/B trivial.
A bad or unreadable doc never breaks a request: it is logged and the last good
value (or the environment) applies.
"""

from __future__ import annotations

import logging
import random
import time

from config import CONFIG

logger = logging.getLogger("ayma.llm_routing")

GROUPS = ("json", "vision", "chat", "voice")
_ROUTES = ("vertex", "inference")
_CONFIG_COLLECTION = "config"
_ROUTING_DOC = "llm_routing"

_cache: dict = {"at": -1e9, "data": {}}


def _env_setting(group: str) -> tuple[str, int]:
    if group == "voice":
        provider = "inference" if CONFIG.voice_provider == "inference" else "vertex"
    else:
        provider = getattr(CONFIG, f"llm_route_{group}")
    return provider, getattr(CONFIG, f"llm_percent_{group}")


def _read_doc() -> dict:
    now = time.monotonic()
    if now - _cache["at"] < CONFIG.llm_routing_cache_seconds:
        return _cache["data"]
    data: dict = {}
    try:
        from db import get_db

        snap = get_db().collection(_CONFIG_COLLECTION).document(_ROUTING_DOC).get()
        if snap.exists:
            data = snap.to_dict() or {}
    except Exception:  # noqa: BLE001 - routing must never break a request
        logger.warning("llm_routing: reading config/llm_routing failed", exc_info=True)
        data = _cache["data"]  # keep the last good value
    _cache.update(at=now, data=data)
    return data


def _setting(group: str) -> tuple[str, int]:
    provider, percent = _env_setting(group)
    raw = _read_doc().get(group)
    if isinstance(raw, str):
        raw = {"provider": raw}
    if isinstance(raw, dict):
        p = str(raw.get("provider", provider)).strip().lower()
        if p in _ROUTES:
            provider = p
        else:
            logger.warning("llm_routing: ignoring invalid provider %r for %s", p, group)
        pct = raw.get("percent", percent)
        if isinstance(pct, (int, float)) and not isinstance(pct, bool) and 0 <= pct <= 100:
            percent = int(pct)
        else:
            logger.warning("llm_routing: ignoring invalid percent %r for %s", pct, group)
    return provider, percent


def route_for(group: str) -> str:
    """``"vertex"`` or ``"inference"`` for this call."""
    provider, percent = _setting(group)
    if provider != "inference" or percent <= 0:
        return "vertex"
    if percent >= 100 or random.uniform(0, 100) < percent:
        return "inference"
    return "vertex"


def fallback_enabled() -> bool:
    raw = _read_doc().get("fallback")
    if isinstance(raw, bool):
        return raw
    return CONFIG.llm_inference_fallback


def reset_cache() -> None:
    _cache.update(at=-1e9, data={})
