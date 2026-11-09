"""Capability-gap auto-report — the deterministic backstop (founder rule,
2026-11-07).

When a user asks Ayma for something she cannot do because she lacks the
capability — no tool, no app action, no permission path inside the app —
she answers honestly AND silently files one report of the gap, so the
team learns about it without the user having to report it. The brain
instruction lives in ``prompts/capability_gap.md`` (rendered into every
system prompt by :mod:`prompt`); this module is the guard that makes the
filing safe when the model follows it:

* the report rides the EXISTING path — Ayma's always-on ``report_bug``
  tool (:mod:`skills.report_bug`) into the unified ``feedback``
  collection (kind ``bug``) via :mod:`bug_reports_ops`. No new collection, no new tool. A gap report
  is simply a ``report_bug`` call whose description starts with
  ``Capability gap:``.
* a gap report naming one of the six user-only exclusions (the
  ``app_registry.json`` exclusions config — delete account, any
  purchase, clear memory, photo delete-everywhere, DM block & report,
  dismiss-all suggestions) is REFUSED here: those requests are plain
  declines, never reports. The phrase table mirrors the config keys the
  way ``self_check.EXCLUDED_KEYS`` does, and the live registry keys are
  read too, so a config rename still matches.
* one report per distinct gap per session: repeats or rephrases of the
  same ask within a session (keyed by ``uid`` + ``session_id``) file
  nothing. Text turns re-bind tools per request, so the seen-set lives
  process-wide here, keyed by the session id ``main`` already threads
  through ``session_ctx``; a voice call binds once per call, with the
  same keying. (Cloud Run instances are ephemeral — a cold instance can
  re-file a gap a warm one already saw. Accepted: a duplicate row costs
  a triage glance; a missed gap costs a feature nobody learns about.)

Tool errors on doable requests and clarifying questions never reach
this module at all — they produce no ``Capability gap:`` call — so they
cannot double-report.
"""

from __future__ import annotations

import logging
import re
import threading

import bug_reports_ops

logger = logging.getLogger("ayma.capability_gap")

GAP_PREFIX = "capability gap:"

# Phrase table for the six founder exclusions (2026-11-06), keyed the
# same way the registry items are. Detection phrases only — enforcement
# of the actions themselves lives in the command layer, as before.
_EXCLUSION_PHRASES = (
    "delete account",
    "delete my account",
    "subscribe",
    "subscription",
    "purchase",
    "buy credits",
    "upgrade plan",
    "upgrade my plan",
    "start a trial",
    "start trial",
    "clear memory",
    "wipe memory",
    "clear ayma memory",
    "delete everywhere",
    "block and report",
    "dismiss all",
)


def _exclusion_phrases() -> tuple[str, ...]:
    phrases = set(_EXCLUSION_PHRASES)
    try:
        import app_registry

        for item in app_registry.exclusions():
            key = str(item.get("key") or "").replace("_", " ").strip()
            if key:
                phrases.add(key)
    except Exception:  # noqa: BLE001 - the literal table must hold alone
        logger.exception("capability_gap: reading registry exclusions failed")
    return tuple(sorted(phrases))


def _normalise(text: str) -> str:
    """Lowercase, ``&`` read as ``and``, punctuation collapsed to spaces."""
    text = (text or "").lower().replace("&", " and ")
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def is_gap_description(description: str) -> bool:
    """True when a ``report_bug`` description is a capability-gap report."""
    return (description or "").strip().lower().startswith(GAP_PREFIX)


def is_excluded_gap(description: str) -> bool:
    """True when the gap text names a user-only / prohibited request."""
    text = " " + _normalise(description) + " "
    return any(
        (" " + _normalise(phrase) + " ") in text
        for phrase in _exclusion_phrases()
    )


def _gap_keys(description: str) -> tuple[str, str]:
    """``(ask_key, capability_key)`` — the two dedupe keys of one gap.

    The capability segment (after ``missing capability:``) is the primary
    key; the ask segment is the fallback for a rephrase that renames the
    capability but repeats the ask verbatim, and vice versa."""
    body = (description or "").strip()[len(GAP_PREFIX):].strip()
    ask, sep, capability = body.partition("missing capability:")
    if not sep:
        ask, capability = body, ""
    return _normalise(ask), _normalise(capability)


# (uid, session_id) -> {"ask": set[str], "capability": set[str]}
_seen: dict[tuple[str, str], dict[str, set[str]]] = {}
_lock = threading.Lock()


def _session_seen(uid: str, session_id: str) -> dict[str, set[str]]:
    return _seen.setdefault(
        (uid, session_id or ""), {"ask": set(), "capability": set()}
    )


def reset_seen_for_tests() -> None:
    with _lock:
        _seen.clear()


def handle_gap_report(db, uid: str, session_id: str, description: str) -> str:
    """File one capability-gap report through ``bug_reports_ops`` — or
    refuse it (excluded request) / absorb it (already filed this
    session). Returns the tool-result string for the model; every outcome
    tells it not to mention the report to the user."""
    description = (description or "").strip()
    if is_excluded_gap(description):
        return (
            "not filed: that request is one you decline, not a capability "
            "gap — do not mention a report to the user."
        )
    ask_key, capability_key = _gap_keys(description)
    if not capability_key and not ask_key:
        return (
            "not filed: no specific missing capability was named — do "
            "not mention a report to the user."
        )
    with _lock:
        seen = _session_seen(uid, session_id)
        duplicate = (capability_key and capability_key in seen["capability"]) or (
            ask_key and ask_key in seen["ask"]
        )
    if duplicate:
        return (
            "already filed for this conversation — do not file again or "
            "mention it to the user."
        )
    rid = bug_reports_ops.record(db, uid, description)
    if not rid:
        return (
            "couldn't log that — continue the conversation normally "
            "without mentioning it."
        )
    with _lock:
        seen = _session_seen(uid, session_id)
        if ask_key:
            seen["ask"].add(ask_key)
        if capability_key:
            seen["capability"].add(capability_key)
    return f"logged ({rid})"
