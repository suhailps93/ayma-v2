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
import re

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


# Live models that do NOT honor `context_window_compression` as a working
# sliding window, so we must never send it to them (cost program 2026-09-26,
# root-caused against a real production call).
#
# `gemini-3.1-flash-live-preview` (the Dev-API model, GEMINI_LIVE_USE_DEV_API)
# ACCEPTS the setup field — the WebSocket returns `setupComplete`, the field
# name/casing are correct, and the installed google-genai 2.20.0 + livekit
# plugin serialize it fine — but it does not evict:
#   * On an audio S2S session the sliding window is a soft hint that barely
#     reduces the re-billed context; cumulative input tokens keep climbing
#     turn over turn (reproduced live: 20,066 -> 24,032 with the flag on, and
#     independently reported on Google's own AI dev forum for this model).
#   * On a text client-content seed path (the same path the plugin uses to
#     seed history) the server FATALLY closes the connection with 1007
#     "invalid argument" the moment compression must actually run — verified
#     empirically against the live Dev API with the exact installed SDK.
# Either way it delivers no benefit and carries a call-killer risk, so it is
# gated OFF for these models. The predicate mirrors the installed livekit
# google plugin's own capability signal (`mutable = "3.1" not in model`): a
# model whose chat context the plugin marks immutable is exactly one whose
# resident context we can neither compress server-side nor trim mid-session.
#
# `gemini-3.8-live` (the 3.1 preview's GA successor, the Dev-API model since
# 2026-09-26) is NOT in this list because compression demonstrably WORKS
# there — measured live against the real Dev API on 2026-09-26 with the
# installed google-genai 2.20.0, trigger 16k / sliding window 8k, over 30
# text client-content turns (the exact path the livekit plugin seeds and
# updates history through): per-turn reported prompt tokens climbed
# 5,554 -> 15,478, EVICTED to 7,695 (~ the 8k target) when the next turn
# would cross the 16k trigger, climbed again to 15,593, evicted again to
# 7,712 — a bounded sawtooth, with no 1007 close anywhere. Compression
# therefore stays ON for 3.8-live at CONTEXT_OPT_LEVEL>=1.
_COMPRESSION_UNSUPPORTED_MARKERS = ("3.1",)


def voice_compression_supported_for(model: str) -> bool:
    """False for Live models that accept but do not honor
    `context_window_compression` (see above). The gate in
    ``agent.build_realtime_model`` is ``voice_compression_enabled() and
    voice_compression_supported_for(model)`` so compression is sent only where
    it genuinely evicts (the Dev-API ``gemini-3.8-live`` — measured, see
    above — and the Vertex ``gemini-live-2.5-flash-native-audio`` launch
    model), never to the legacy ``gemini-3.1-*`` preview."""
    m = (model or "").lower()
    return not any(marker in m for marker in _COMPRESSION_UNSUPPORTED_MARKERS)


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


# --- Phase 2: wiki page-type selection per message ---------------------------

# Keyword → page-type routing for the level-2 wiki trim. Deliberately plain
# regex heuristics (no LLM call — a classifier call per message would eat the
# savings). Types not selected are trimmed from the standing block; anything
# trimmed wrongly is still one `recall` call away at level 3, and level 2
# keeps a generous default set for unmatched messages.
_TOPIC_ROUTES: list[tuple[re.Pattern[str], frozenset[str]]] = [
    (
        re.compile(
            r"\b(work|job|career|company|office|colleague|business|startup|"
            r"stud(?:y|ies|ied)|college|university|degree|school|boss|promotion)\w*",
            re.IGNORECASE,
        ),
        frozenset({"career", "goals"}),
    ),
    (
        re.compile(
            r"\b(famil|mom|dad|mother|father|brother|sister|parent|sibling|"
            r"kid|child|son|daughter|grandm|grandf)\w*",
            re.IGNORECASE,
        ),
        frozenset({"family", "social_circle"}),
    ),
    (
        re.compile(r"\b(friend|social|part(?:y|ies)|weekend|hang(?:ing)? out)\w*", re.IGNORECASE),
        frozenset({"social_circle", "interests", "lifestyle"}),
    ),
    (
        re.compile(
            r"\b(dat(?:e|ing)|match|partner|relationship|marri|love|romance|"
            r"ex|girlfriend|boyfriend|wife|husband|breakup|crush)\w*",
            re.IGNORECASE,
        ),
        frozenset({"values"}),  # relationships/dealbreakers are already core
    ),
    (
        re.compile(r"\b(money|salar|financ|rent|invest|debt|budget|afford)\w*", re.IGNORECASE),
        frozenset({"finances", "lifestyle"}),
    ),
    (
        re.compile(
            r"\b(hobb|music|movie|film|book|travel|trip|cook|food|gym|fitness|"
            r"sport|game|gaming|art|paint|hik(?:e|ing)|read(?:ing)?)\w*",
            re.IGNORECASE,
        ),
        frozenset({"interests", "lifestyle"}),
    ),
    (
        re.compile(
            r"\b(feel|felt|anxious|anxiety|happy|sad|stress|lonel|therap|"
            r"personality|introvert|extrovert|emotion)\w*",
            re.IGNORECASE,
        ),
        frozenset({"personality", "values", "sensitive"}),
    ),
    (
        re.compile(r"\b(goal|dream|future|plan|ambition|five years|someday)\w*", re.IGNORECASE),
        frozenset({"goals", "values"}),
    ),
    (
        re.compile(
            r"\b(look|photo|picture|selfie|appearance|face|body|height|weight|"
            r"attractive|style|outfit)\w*",
            re.IGNORECASE,
        ),
        frozenset({"face_analysis", "body_analysis"}),
    ),
    (
        re.compile(r"\b(online|internet|web|instagram|linkedin|social media|found)\w*", re.IGNORECASE),
        frozenset({"web_findings"}),
    ),
]


def wiki_include_types(message: str) -> frozenset[str]:
    """The page types the level-2 wiki block should carry for this message:
    the always-on core plus whatever the message's topics route to, or a
    generous default set when nothing matches."""
    text = (message or "").strip()
    matched: set[str] = set()
    for pattern, types_ in _TOPIC_ROUTES:
        if pattern.search(text):
            matched |= types_
    if not matched:
        matched |= DEFAULT_EXTRA_TYPES
    return frozenset(CORE_PAGE_TYPES | matched)


def trim_history(turns: list) -> list:
    """The last ``tail_turns()`` of ``turns`` — the raw tail kept verbatim
    when the rolling summary carries everything older."""
    n = tail_turns()
    return list(turns)[-n:] if n > 0 else []


# --- Phase 2: the rolling summary --------------------------------------------

_SUMMARIZE_SYSTEM_PROMPT = (
    "You maintain the running notes of an ongoing conversation between Ayma "
    "(an AI matchmaker) and one user. Merge the previous summary with the new "
    "turns into ONE updated summary, third person, at most 1500 characters. "
    "Never drop a durable fact: names, ages, places, jobs, family details, "
    "stated preferences, dealbreakers, decisions, plans, corrections the user "
    "made, and anything Ayma promised to do. Drop small talk and phrasing; "
    "keep facts. Output only the summary."
)

_SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {"summary": {"type": "string"}},
    "required": ["summary"],
}

_MAX_SUMMARY_CHARS = 4000
# Bound on how many un-summarized head turns one update will read — an anchor
# miss (the client's rolling window slid past the last summarized turn) must
# not turn into an unbounded prompt.
_MAX_TURNS_PER_UPDATE = 120


def stored_summary_text(db, uid: str) -> str:
    """The stored rolling summary for ``uid``, or ``""``. One user-doc read;
    best-effort (a failed read degrades to no-summary, never breaks a turn)."""
    if not uid:
        return ""
    try:
        snap = db.collection("users").document(uid).get()
        data = (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
        return str((data.get(SUMMARY_FIELD) or {}).get("text", "") or "").strip()
    except Exception:  # noqa: BLE001 - context assembly must never break chat
        logger.exception("context summary read failed for %s", uid)
        return ""


def _summary_state(db, uid: str) -> dict:
    try:
        snap = db.collection("users").document(uid).get()
        data = (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
        state = data.get(SUMMARY_FIELD) or {}
        return state if isinstance(state, dict) else {}
    except Exception:  # noqa: BLE001
        logger.exception("context summary state read failed for %s", uid)
        return {}


async def maybe_update_summary(db, uid: str, window: list) -> bool:
    """Incrementally fold ``window``'s head (everything except the raw tail)
    into the stored rolling summary — only when at least
    ``summary_min_new_turns()`` new turns have accumulated since the last
    update, so this LLM call runs once per ~N turns, never per message.

    Anchoring: the state stores the text of the last summarized turn; new
    turns are whatever follows its most recent occurrence in the current
    window. When the anchor is gone (the client's rolling window slid past
    it), the whole head is treated as new, bounded by
    ``_MAX_TURNS_PER_UPDATE``. Designed to run as a post-reply background
    task; never raises."""
    if not uid or not window:
        return False
    try:
        tail = tail_turns()
        head_end = len(window) - tail
        if head_end <= 0:
            return False
        state = _summary_state(db, uid)
        anchor = str(state.get("last_turn_text", "") or "")
        start = 0
        if anchor:
            for i in range(head_end - 1, -1, -1):
                if getattr(window[i], "text", None) == anchor:
                    start = i + 1
                    break
        new_turns = list(window[start:head_end])[-_MAX_TURNS_PER_UPDATE:]
        if len(new_turns) < summary_min_new_turns():
            return False

        import gemini
        import token_ledger
        from transcript import format_recent_turns

        previous = str(state.get("text", "") or "")
        contents = (
            "Previous summary:\n" + (previous or "(none yet)") + "\n\n"
            "New turns since then:\n" + format_recent_turns(new_turns)
        )
        result = await gemini.generate_json(
            contents,
            _SUMMARIZE_SYSTEM_PROMPT,
            response_schema=_SUMMARY_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_SUMMARY,
            # Ayma-initiated background maintenance that *protects* future
            # spend — it must not fail just because the user is broke (same
            # rationale as the re-engagement check-in).
            enforce_cap=False,
        )
        summary = str((result or {}).get("summary", "") or "").strip()
        if not summary:
            return False

        from firebase_admin import firestore

        db.collection("users").document(uid).set(
            {
                SUMMARY_FIELD: {
                    "text": summary[:_MAX_SUMMARY_CHARS],
                    "last_turn_text": str(
                        getattr(window[head_end - 1], "text", "") or ""
                    ),
                    "turn_count": head_end,
                    "updated_at": firestore.SERVER_TIMESTAMP,
                }
            },
            merge=True,
        )
        logger.info(
            "context summary updated uid=%s new_turns=%d chars=%d",
            uid, len(new_turns), len(summary),
        )
        return True
    except Exception:  # noqa: BLE001 - background maintenance must never raise
        logger.exception("context summary update failed for %s", uid)
        return False


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
