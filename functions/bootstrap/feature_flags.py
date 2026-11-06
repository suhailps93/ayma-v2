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
from datetime import datetime, timezone
from typing import Any

from config import CONFIG

logger = logging.getLogger("ayma.feature_flags")

FLAGS_CACHE_SECONDS = 60
CONFIG_COLLECTION = "config"
FLAGS_DOC = "feature_flags"
LEGACY_ROUTING_DOC = "llm_routing"
LEGACY_SENTRY = ("app_config", "sentry")
ENV_PREFIX = "FLAG_"
HISTORY_KEY = "_history"
HISTORY_LIMIT = 20

# Flags the mobile client reads directly: each write mirrors them to
# ``app_config/<doc>.enabled`` (readable by any client, see firestore.rules),
# since the client cannot read ``config/feature_flags``.
APP_MIRRORS = {
    "sentry": ("app_config", "sentry"),
    "meta_integrations": ("app_config", "meta_integrations"),
}

ROUTES = ("vertex", "inference")
VOICE_PROVIDERS = ("google", "inference")
ROUTE_GROUPS = ("json", "vision", "chat", "voice")

# Flags the demo/judge ``all_flags_on_uids`` override must NEVER force ON.
# (Kept as a guardrail even though ``llm_fallback_to_google`` is INERT since
# the 2026-11-04 direct-Google kill: if anyone ever re-honors it, the denylist
# still stops an all-flags-on uid from arming an off-LiveKit path.)
ALL_FLAGS_ON_DENYLIST = frozenset({"llm_fallback_to_google"})


@dataclass(frozen=True)
class Flag:
    name: str
    kind: str  # bool | route | provider | percent | int | list
    config_attr: str | None
    description: str
    default: Any = None  # used only when ``config_attr`` is None


def _route_flags() -> list[Flag]:
    # INERT since the 2026-11-04 direct-Google kill: llm_routing always
    # resolves to Inference and never falls back, whatever these say. Kept so
    # old Firestore/env values validate and stay visible (never re-honor them).
    out: list[Flag] = []
    for g in ("json", "vision", "chat"):
        out.append(Flag(f"llm_route_{g}", "route", f"llm_route_{g}",
                        f"INERT (kill 2026-11-04): {g} jobs always run on "
                        "LiveKit Inference"))
    out.append(Flag("voice_provider", "provider", "voice_provider",
                    "INERT (kill 2026-11-04): voice always runs on LiveKit "
                    "Inference"))
    for g in ROUTE_GROUPS:
        out.append(Flag(f"llm_percent_{g}", "percent", f"llm_percent_{g}",
                        f"INERT (kill 2026-11-04): {g} always sends 100% to "
                        "Inference"))
    for g in ROUTE_GROUPS:
        out.append(Flag(f"llm_allowlist_{g}", "list", None,
                        f"INERT (kill 2026-11-04): no allowlist, everyone is "
                        f"on Inference for {g}",
                        default=()))
    return out


REGISTRY: dict[str, Flag] = {
    f.name: f
    for f in _route_flags() + [
        Flag("llm_fallback_to_google", "bool", "llm_inference_fallback",
             "INERT (kill 2026-11-04): an Inference failure always surfaces, "
             "never retries on Google"),
        Flag("maps_grounding", "bool", "gemini_maps_grounding",
             "INERT (kill 2026-11-04): Maps grounding only existed on the "
             "direct-Google path"),
        Flag("deepdive_public_profiles", "bool", "deepdive_public_profiles",
             "deep-dive public social-profile photo discovery"),
        Flag("deepdive_validate_links", "bool", None,
             "validate every deep-dive link (404/soft-404/dead hosts dropped) "
             "before it is stored or shown", default=True),
        Flag("deepdive_blocked_regions", "list", "deepdive_blocked_regions",
             "location tokens for which the public-profile step is skipped"),
        Flag("vertex_ai_search", "bool", "vertex_ai_search",
             "Vertex AI Search website source for deep-dive discovery"),
        Flag("vertex_ai_search_daily_cap", "int", "vertex_ai_search_daily_cap",
             "max Vertex AI Search queries per UTC day"),
        Flag("meta_integrations", "bool", "meta_integrations",
             "Instagram / Facebook connect, sign-in and photo import (V2; off for V1)"),
        Flag("sentry", "bool", "sentry_enabled",
             "Sentry error reporting (DSN still comes from secrets)"),
        Flag("mcp_server", "bool", "mcp_server",
             "Ayma MCP server (bring-your-own-agent). Default OFF — when off "
             "every /mcp request answers 503. See docs/MCP_SERVER.md."),
        Flag("qloo_enabled", "bool", None,
             "Kill switch for ALL Qloo Taste API calls (billing protection). "
             "Default ON. When false, NO Qloo HTTP request is made anywhere and "
             "the taste features degrade to the no-taste empty state. Flip with "
             "scripts/flags.py set qloo_enabled=false --yes (no redeploy).",
             default=True),
        Flag("emotion_matching", "bool", None,
             "Emotion-matched responses (founder directive 2026-11-06): Ayma "
             "reads the user's emotional state from the transcript and "
             "adjusts reply content/tone and Cartesia voice delivery. Text "
             "chat folds the read into the reply pass itself (guidance block "
             "in the system prompt); voice folds it into the voice-actions "
             "pass (no extra gateway call). Session-scoped state only — "
             "never written to the profile. Default OFF. See "
             "docs/EMOTION_MATCHING.md.",
             default=False),
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


def resolve(name: str, uid: str | None = None) -> tuple[Any, str]:
    """``(value, source)``; source is ``env``, ``firestore``, ``default`` or,
    for a per-user override, ``user_override``.

    When ``uid`` is one of ``CONFIG.all_flags_on_uids`` (the demo/judge
    accounts, see ``docs/DEMO_ACCOUNTS.md``) every *boolean* flag resolves ON
    for that user, without touching any global flag. Non-bool flags (routes,
    percents, lists, ints) have no meaningful "on" and are resolved normally.
    Flags in ``ALL_FLAGS_ON_DENYLIST`` (e.g. ``llm_fallback_to_google``) are
    never force-enabled by this path — they would arm a banned off-LiveKit
    direct-Google path — and resolve normally instead."""
    flag = REGISTRY[name]
    if (
        uid
        and flag.kind == "bool"
        and uid in CONFIG.all_flags_on_uids
        and name not in ALL_FLAGS_ON_DENYLIST
    ):
        return True, "user_override"
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


def get(name: str, uid: str | None = None) -> Any:
    return resolve(name, uid)[0]


def enabled(name: str, uid: str | None = None) -> bool:
    return bool(get(name, uid))


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


def mirror_to_app(db, values: dict) -> None:
    """Copy every client-read flag in ``values`` to its ``app_config`` doc."""
    for name, (coll, doc) in APP_MIRRORS.items():
        if name in values:
            db.collection(coll).document(doc).set({"enabled": values[name]}, merge=True)


def write(db, changes: dict, *, by: str) -> dict:
    """Merge validated ``changes`` into ``config/feature_flags``, recording the
    previous values in ``_history`` (last ``HISTORY_LIMIT``), mirror the
    client-read flags and drop this process's cache. Returns the new doc."""
    ref = db.collection(CONFIG_COLLECTION).document(FLAGS_DOC)
    snap = ref.get()
    current = (snap.to_dict() or {}) if snap.exists else {}
    before = {k: v for k, v in current.items() if not k.startswith("_")}
    history = list(current.get(HISTORY_KEY) or [])
    history.append({
        "at": datetime.now(timezone.utc).isoformat(),
        "by": by,
        "changed": sorted(changes),
        "before": before,
    })
    new = {**before, **changes, HISTORY_KEY: history[-HISTORY_LIMIT:]}
    ref.set(new)
    mirror_to_app(db, changes)
    reset_cache()
    return new


def reset_cache() -> None:
    _cache.update(at=-1e9, data={})
