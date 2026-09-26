"""Token-cost context optimization: flags, measurement, and the rolling
summary (cost program, 2026-09-26).

~85% of recent credit burn is voice — the Gemini Live API re-bills the entire
accumulated session context every turn and our sessions historically set no
context-window compression — and text chat resends a ~12k-char wiki block plus
a ~200-turn history window with every message. This module is the single
switchboard for the fixes:

* **Every behavior change is gated on ``CONTEXT_OPT_LEVEL``** (env var,
  default ``0`` = everything off, old code paths byte-identical). The level is
  read at *call* time, not import time, so rollback is a config flip on the
  Cloud Run service (no code deploy). Both services — ``ayma-api`` and
  ``ayma-agent`` — should carry the same value; each degrades safely to its
  own old behavior when the other is behind.

    level >= 1 (config wins):
      - voice: Live API context_window_compression (sliding window)
      - text: byte-stable prompt prefix ordering (implicit-cache alignment)
    level >= 2 (context diet):
      - text: rolling summary + last-N-turns window instead of ~200 raw turns
      - voice: seed diet — core wiki card + summary + last ~10 turns
      - text: wiki block trimmed to message-relevant page types + core
    level >= 3 (on-demand recall):
      - both: the ``recall(topic)`` tool is registered, and the standing wiki
        context shrinks to the core card everywhere.

* **Phase 0 measurement** (``CONTEXT_OPT_MEASURE=true``, independent of the
  level): per-turn prompt-size breakdowns by component (system / wiki /
  history / summary / message), logged always at INFO (grep
  ``context-breakdown``) and — when the flag is on — persisted to
  ``users/{uid}/token_turns`` (capped, pruned) so live before/after comparison
  is queryable. Token counts are estimated as ``chars // 4``; the SDK's
  ``count_tokens`` is a network round-trip per call and too expensive to sit
  on the request path.

* The rolling summary itself: stored on ``users/{uid}.context_summary``,
  updated **incrementally in the background** only when at least
  ``CONTEXT_OPT_SUMMARY_MIN_NEW_TURNS`` new turns have landed since the last
  update — never per-message — so summarization never eats its own savings.
"""

from __future__ import annotations

import logging
import os

logger = logging.getLogger("ayma.context_opt")

# Firestore field on users/{uid} holding the rolling conversation summary.
SUMMARY_FIELD = "context_summary"

# Measurement subcollection under users/{uid} (Phase 0). Pruned to a cap so it
# can't grow unbounded.
TOKEN_TURNS_COLLECTION = "token_turns"

# The always-on wiki core: who they are, what they want, and the user's own
# standing instructions to Ayma. Everything else is either summarizable,
# trimmable per message topic (level 2), or recallable on demand (level 3).
CORE_PAGE_TYPES = frozenset({"identity", "relationships", "dealbreakers", "steering"})

# When level-2 wiki trimming finds no topical match in the message, fall back
# to a still-useful medium set rather than core-only, so an off-topic opener
# ("hey", "good morning") never strips Ayma of her working knowledge.
DEFAULT_EXTRA_TYPES = frozenset({"values", "personality", "interests", "lifestyle"})


def _int_env(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default


def level() -> int:
    """``CONTEXT_OPT_LEVEL`` (0..3), read at call time so a Cloud Run env flip
    is a full rollback/rollout with no code deploy. Anything unparseable or
    out of range clamps to the safe end."""
    try:
        raw = int(os.getenv("CONTEXT_OPT_LEVEL", "0"))
    except ValueError:
        return 0
    return max(0, min(3, raw))


# --- per-feature gates (all level-driven; one knob to turn) -----------------

def voice_compression_enabled() -> bool:
    """Phase 1: Live API sliding-window context compression."""
    return level() >= 1


def stable_prefix_enabled() -> bool:
    """Phase 1: byte-stable system-prompt prefix ordering for text chat."""
    return level() >= 1


def summary_enabled() -> bool:
    """Phase 2: rolling summary + short tail instead of the full window."""
    return level() >= 2


def voice_seed_diet_enabled() -> bool:
    """Phase 2: voice sessions seed with core card + summary + short tail."""
    return level() >= 2


def wiki_trim_enabled() -> bool:
    """Phase 2: per-message wiki page-type selection for text chat."""
    return level() >= 2


def recall_enabled() -> bool:
    """Phase 3: the ``recall(topic)`` tool is registered (text + voice) and
    the standing wiki context shrinks to the core card."""
    return level() >= 3


def measure_enabled() -> bool:
    """Phase 0: persist per-turn breakdowns to ``token_turns`` (logging always
    happens regardless). Independent of the level so the before side of the
    A/B can be measured with every optimization still off."""
    return os.getenv("CONTEXT_OPT_MEASURE", "false").strip().lower() == "true"


# --- tunables ---------------------------------------------------------------

def voice_compression_trigger_tokens() -> int:
    return _int_env("CONTEXT_OPT_VOICE_TRIGGER_TOKENS", 16000)


def voice_compression_target_tokens() -> int:
    return _int_env("CONTEXT_OPT_VOICE_WINDOW_TOKENS", 8000)


def tail_turns() -> int:
    """Raw turns kept verbatim in the text-chat prompt when the summary is on."""
    return _int_env("CONTEXT_OPT_TAIL_TURNS", 15)


def voice_tail_turns() -> int:
    """Raw turns seeded into a voice session when the seed diet is on."""
    return _int_env("CONTEXT_OPT_VOICE_TAIL_TURNS", 10)


def summary_min_new_turns() -> int:
    """New turns that must accumulate before the summary is regenerated —
    the incremental-update threshold that keeps summarization itself cheap."""
    return _int_env("CONTEXT_OPT_SUMMARY_MIN_NEW_TURNS", 20)


def core_wiki_chars() -> int:
    """Budget for the always-on core wiki card (persona card, ~1–2k chars)."""
    return _int_env("CONTEXT_OPT_CORE_WIKI_CHARS", 2000)


def trim_wiki_chars() -> int:
    """Budget for the level-2 topical wiki block (vs. the full 12k)."""
    return _int_env("CONTEXT_OPT_TRIM_WIKI_CHARS", 6000)


def token_turns_cap() -> int:
    return _int_env("CONTEXT_OPT_TOKEN_TURNS_CAP", 200)


def est_tokens(chars: int) -> int:
    """chars/4 — the standard rough English-text token estimate. Good enough
    for component *breakdowns*; the ledger still records the model's real
    usage_metadata numbers for billing."""
    return max(0, int(chars)) // 4


# --- Phase 0: per-component prompt-size measurement ---------------------------

def record_breakdown(
    db,
    uid: str,
    surface: str,
    components: dict[str, int],
    *,
    session_id: str = "",
) -> None:
    """Log (always) and persist (only with ``CONTEXT_OPT_MEASURE=true``) one
    prompt-assembly breakdown. ``components`` maps component name → chars
    (``system`` / ``wiki`` / ``history`` / ``summary`` / ``message``); the
    token estimate is chars/4. ``surface`` is ``"chat"`` or ``"voice_seed"``.
    Best-effort, never raises — measurement must never break a request."""
    try:
        comps = {k: max(0, int(v)) for k, v in (components or {}).items()}
        total_chars = sum(comps.values())
        detail = " ".join(f"{k}={v}" for k, v in sorted(comps.items()))
        logger.info(
            "context-breakdown uid=%s surface=%s level=%d session=%s %s "
            "total_chars=%d est_tokens=%d",
            uid, surface, level(), session_id or "?", detail,
            total_chars, est_tokens(total_chars),
        )
        if not measure_enabled() or not uid:
            return

        from firebase_admin import firestore

        col = (
            db.collection("users").document(uid)
            .collection(TOKEN_TURNS_COLLECTION)
        )
        col.add(
            {
                "surface": surface,
                "level": level(),
                "session_id": session_id,
                "components_chars": comps,
                "components_tokens": {k: est_tokens(v) for k, v in comps.items()},
                "total_chars": total_chars,
                "est_tokens": est_tokens(total_chars),
                "created_at": firestore.SERVER_TIMESTAMP,
            }
        )
        _prune_token_turns(col)
    except Exception:  # noqa: BLE001 - measurement is strictly best-effort
        logger.exception("context breakdown record failed for %s", uid)


def _prune_token_turns(col) -> None:
    """Keep ``token_turns`` bounded: delete anything past the newest
    ``token_turns_cap()`` docs (small batch per call — the collection can only
    grow by one per turn, so slow pruning still converges)."""
    try:
        from firebase_admin import firestore

        stale = list(
            col.order_by("created_at", direction=firestore.Query.DESCENDING)
            .offset(token_turns_cap())
            .limit(25)
            .stream()
        )
        for snap in stale:
            snap.reference.delete()
    except Exception:  # noqa: BLE001 - pruning is opportunistic
        logger.debug("token_turns prune skipped", exc_info=True)
