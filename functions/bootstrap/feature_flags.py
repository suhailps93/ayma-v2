"""Every runtime feature flag, in one place.

Source of truth is the Firestore doc ``config/feature_flags`` (flat keys, see
``docs/FEATURE_FLAGS.md``), cached for ``FLAGS_CACHE_SECONDS``. Resolution for
one flag, highest priority first:

1. ``FLAG_<NAME>`` environment variable (local dev / tests / emergency pin).
2. ``config/feature_flags`` -> ``<name>``.
3. The legacy docs, kept as a backward-compatible fallback: ``config/llm_routing``
   (``json|vision|chat|voice`` groups and ``fallback``) and ``app_config/sentry``
   (``enabled``).
4. The code default in ``config.py`` (``CONFIG``, itself fed by the legacy
   per-flag env vars such as ``LLM_ROUTE_JSON``).

A bad, missing or unreadable value never breaks a request: it is logged and the
next layer applies; an unreadable Firestore keeps the last good document.
Keys starting with ``_`` (e.g. ``_history``) are bookkeeping and never flags.
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass
from typing import Any

from config import CONFIG

logger = logging.getLogger("ayma.feature_flags")

FLAGS_CACHE_SECONDS = 60
CONFIG_COLLECTION = "config"
FLAGS_DOC = "feature_flags"
LEGACY_ROUTING_DOC = "llm_routing"
LEGACY_SENTRY = ("app_config", "sentry")
ENV_PREFIX = "FLAG_"

ROUTES = ("vertex", "inference")
VOICE_PROVIDERS = ("google", "inference")
ROUTE_GROUPS = ("json", "vision", "chat", "voice")


@dataclass(frozen=True)
class Flag:
    name: str
    kind: str  # bool | route | provider | percent | int | list
    config_attr: str | None
    description: str
    default: Any = None  # used only when ``config_attr`` is None


def _route_flags() -> list[Flag]:
    out: list[Flag] = []
    for g in ("json", "vision", "chat"):
        out.append(Flag(f"llm_route_{g}", "route", f"llm_route_{g}",
                        f"{g} jobs: 'inference' (LiveKit Inference) or 'vertex'"))
    out.append(Flag("voice_provider", "provider", "voice_provider",
                    "voice backend: 'inference' (LiveKit Inference) or 'google'"))
    for g in ROUTE_GROUPS:
        out.append(Flag(f"llm_percent_{g}", "percent", f"llm_percent_{g}",
                        f"share (0-100) of {g} calls sent to Inference"))
    for g in ROUTE_GROUPS:
        out.append(Flag(f"llm_allowlist_{g}", "list", None,
                        f"uids restricted to Inference for {g} (empty = everyone)",
                        default=()))
    return out


REGISTRY: dict[str, Flag] = {
    f.name: f
    for f in _route_flags() + [
        Flag("llm_fallback_to_google", "bool", "llm_inference_fallback",
             "on an Inference failure, retry on Google instead of failing loudly"),
        Flag("maps_grounding", "bool", "gemini_maps_grounding",
             "Google Maps grounding in text chat"),
        Flag("deepdive_public_profiles", "bool", "deepdive_public_profiles",
             "deep-dive public social-profile photo discovery"),
        Flag("deepdive_blocked_regions", "list", "deepdive_blocked_regions",
             "location tokens for which the public-profile step is skipped"),
        Flag("vertex_ai_search", "bool", "vertex_ai_search",
             "Vertex AI Search website source for deep-dive discovery"),
        Flag("vertex_ai_search_daily_cap", "int", "vertex_ai_search_daily_cap",
             "max Vertex AI Search queries per UTC day"),
        Flag("sentry", "bool", "sentry_enabled",
             "Sentry error reporting (DSN still comes from secrets)"),
    ]
}

_cache: dict = {"at": -1e9, "data": {}}


def _coerce(flag: Flag, raw: Any) -> Any:
    """``raw`` validated against ``flag.kind``; raises ``ValueError`` if bad."""
    k = flag.kind
    if k == "bool":
        if isinstance(raw, bool):
            return raw
    elif k in ("route", "provider"):
        allowed = ROUTES if k == "route" else VOICE_PROVIDERS
        if isinstance(raw, str) and raw.strip().lower() in allowed:
            return raw.strip().lower()
    elif k == "percent":
        if isinstance(raw, (int, float)) and not isinstance(raw, bool) and 0 <= raw <= 100:
            return int(raw)
    elif k == "int":
        if isinstance(raw, (int, float)) and not isinstance(raw, bool) and raw >= 0:
            return int(raw)
    elif k == "list":
        if isinstance(raw, (list, tuple)) and all(isinstance(x, str) for x in raw):
            lowered = flag.name == "deepdive_blocked_regions"
            return tuple(
                (x.strip().lower() if lowered else x.strip()) for x in raw if x.strip()
            )
    raise ValueError(f"invalid {k} value {raw!r} for {flag.name}")


def _parse_env(flag: Flag, text: str) -> Any:
    t = text.strip()
    if flag.kind == "bool":
        low = t.lower()
        if low in ("1", "true", "yes", "on"):
            return True
        if low in ("0", "false", "no", "off"):
            return False
        raise ValueError(f"invalid bool {text!r}")
    if flag.kind in ("percent", "int"):
        return _coerce(flag, int(t))
    if flag.kind == "list":
        return _coerce(flag, [x for x in t.split(",")])
    return _coerce(flag, t)


def _legacy_routing(doc: dict) -> dict:
    """Map the old ``config/llm_routing`` shape onto flag names."""
    out: dict = {}
    for g in ROUTE_GROUPS:
        raw = doc.get(g)
        if isinstance(raw, str):
            raw = {"provider": raw}
        if not isinstance(raw, dict):
            continue
        if "provider" in raw:
            out["voice_provider" if g == "voice" else f"llm_route_{g}"] = raw["provider"]
        if "percent" in raw:
            out[f"llm_percent_{g}"] = raw["percent"]
        if "allowlist" in raw:
            out[f"llm_allowlist_{g}"] = raw["allowlist"]
    if "fallback" in doc:
        out["llm_fallback_to_google"] = doc["fallback"]
    return out


def _read_docs() -> dict:
    """The merged Firestore layer (legacy docs under the new doc). Tests stub
    this; production reads at most once per ``FLAGS_CACHE_SECONDS``."""
    from db import get_db

    db = get_db()

    def _get(coll: str, doc: str) -> dict:
        snap = db.collection(coll).document(doc).get(timeout=5)
        return (snap.to_dict() or {}) if snap.exists else {}

    merged: dict = _legacy_routing(_get(CONFIG_COLLECTION, LEGACY_ROUTING_DOC))
    legacy_sentry = _get(*LEGACY_SENTRY)
    if "enabled" in legacy_sentry:
        merged["sentry"] = legacy_sentry["enabled"]
    new = _get(CONFIG_COLLECTION, FLAGS_DOC)
    merged.update({k: v for k, v in new.items() if not k.startswith("_")})
    return merged


def _doc_layer() -> dict:
    now = time.monotonic()
    if now - _cache["at"] < FLAGS_CACHE_SECONDS:
        return _cache["data"]
    try:
        data = _read_docs()
    except Exception:  # noqa: BLE001 - flags must never break a request
        logger.warning("feature_flags: reading Firestore failed", exc_info=True)
        data = _cache["data"]  # keep the last good document
    _cache.update(at=now, data=data)
    return data


def _base(flag: Flag) -> Any:
    if flag.config_attr is None:
        return flag.default
    return getattr(CONFIG, flag.config_attr)


def resolve(name: str) -> tuple[Any, str]:
    """``(value, source)``; source is ``env``, ``firestore`` or ``default``."""
    flag = REGISTRY[name]
    env_text = os.environ.get(ENV_PREFIX + name.upper())
    if env_text is not None and env_text.strip():
        try:
            return _parse_env(flag, env_text), "env"
        except ValueError:
            logger.warning("feature_flags: ignoring invalid %s%s=%r",
                           ENV_PREFIX, name.upper(), env_text)
    layer = _doc_layer()
    if name in layer:
        try:
            return _coerce(flag, layer[name]), "firestore"
        except ValueError as exc:
            logger.warning("feature_flags: ignoring %s", exc)
    return _base(flag), "default"


def get(name: str) -> Any:
    return resolve(name)[0]


def enabled(name: str) -> bool:
    return bool(get(name))


def snapshot() -> dict[str, dict]:
    """All flags with value, source and description (admin view, CLI)."""
    out = {}
    for name, flag in REGISTRY.items():
        value, source = resolve(name)
        out[name] = {
            "value": list(value) if isinstance(value, tuple) else value,
            "source": source,
            "description": flag.description,
        }
    return out


def reset_cache() -> None:
    _cache.update(at=-1e9, data={})
