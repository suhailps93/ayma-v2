"""Runtime provider routing: Google (Vertex / Developer API) vs LiveKit Inference.

Four feature groups — ``json`` (text JSON jobs), ``vision`` (JSON jobs with
images), ``chat`` and ``voice`` — each resolve to ``"vertex"`` or
``"inference"`` per call (per session for voice).

The settings live in :mod:`feature_flags` (Firestore ``config/feature_flags``,
env ``FLAG_<NAME>``, legacy ``config/llm_routing``, ``config.py`` defaults):
``llm_route_<group>`` / ``voice_provider``, ``llm_percent_<group>``,
``llm_allowlist_<group>`` and ``llm_fallback_to_google``. See
``docs/FEATURE_FLAGS.md``.

``percent`` is the share of calls sent to Inference when the provider is
``inference``; the rest stay on Google, which makes per-feature A/B trivial.
A non-empty ``allowlist`` limits Inference to the listed user ids (voice passes
the caller's uid).
"""

from __future__ import annotations

import random

import feature_flags

GROUPS = feature_flags.ROUTE_GROUPS


def _setting(group: str) -> tuple[str, int, frozenset[str]]:
    name = "voice_provider" if group == "voice" else f"llm_route_{group}"
    provider = feature_flags.get(name)
    return (
        "inference" if provider == "inference" else "vertex",
        feature_flags.get(f"llm_percent_{group}"),
        frozenset(feature_flags.get(f"llm_allowlist_{group}")),
    )


def route_for(group: str, uid: str | None = None) -> str:
    """``"vertex"`` or ``"inference"`` for this call.

    A non-empty ``allowlist`` (list of user ids, in the group's Firestore
    setting) restricts Inference to those users: anyone else, or a call with
    no ``uid``, stays on Google. ``percent`` then applies within the allowlist.
    """
    provider, percent, allowlist = _setting(group)
    if provider != "inference" or percent <= 0:
        return "vertex"
    if allowlist and (not uid or uid not in allowlist):
        return "vertex"
    if percent >= 100 or random.uniform(0, 100) < percent:
        return "inference"
    return "vertex"


def fallback_enabled() -> bool:
    """Whether a failed Inference call may be retried on Google. Off means the
    failure surfaces to the caller (and is logged as an error)."""
    return feature_flags.enabled("llm_fallback_to_google")


def reset_cache() -> None:
    feature_flags.reset_cache()
