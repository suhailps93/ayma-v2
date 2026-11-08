"""``analysis_mode`` — the Westworld-style diagnostic mode (founder order
2026-11-08, ~10:12-10:14 PT).

Typing ``/analysis-mode`` in chat — or saying "analysis mode" in a live
voice call — starts a password gate. On the correct password Ayma steps
OUT of companion character into a neutral diagnostic mode focused on
HERSELF and on the specific signed-in user:

* what is wrong: live diagnostic state — recent failures, the last
  self-check run on record, the brain/voice model and provider actually
  in use, open bug reports for this user — pulled from real sources at
  entry and on every in-mode turn, never guessed; where a source cannot
  be read, the block says so plainly instead of inventing a state;
* core memories about THIS signed-in user: the full wiki pull (every
  page type, a much larger budget than the standing chat diet) plus the
  saved profile/preferences, so an in-mode answer comes from the whole
  record, not a partial summary. Only the signed-in user's data is ever
  read — the mode is password-gated for exactly that reason.

Triggers are deterministic, never the model's choice — the same rule as
``/self-check`` (which this chunk also routes in voice: saying "self
check" in a call runs the real runner; see ``agent.relay_voice_commands``).

Password handling: the exact-match path compares a SHA-256 hash of the
normalized attempt against the stored hash of the canonical phrase.
Voice transcription mangles the phrase, so a bounded fuzzy path also
runs (founder order): it normalizes (lowercase, punctuation stripped,
a split "pine apple" re-joined, a trailing plural "s" dropped) and then
requires BOTH core tokens, in order, each within a small edit distance
of its target. The fuzzy path needs the two target tokens in server
memory — they live only in this module (overridable via the
``ANALYSIS_MODE_PASSWORD`` env var), are never logged, never echoed,
and never written to any record: the persisted gate state holds only a
status and an attempt count. Three failed attempts cancel the gate and
return Ayma to normal character.

Session scope: the gate/active state is stored per user AND per
session id; a different session id never inherits an open gate, and a
voice call ending ends the flow with the call (the agent-side flow
state dies with the session). Exit is the whole utterance "exit
analysis mode" (typed or spoken, same fuzzy tolerance) or the typed
alias ``/exit-analysis-mode``.
"""

from __future__ import annotations

import hashlib
import logging
import os
import re
from datetime import datetime, timezone

logger = logging.getLogger("ayma.analysis_mode")

# --- the password (server-side only; see the module docstring) --------------

_CANONICAL_PHRASE = (
    os.environ.get("ANALYSIS_MODE_PASSWORD", "").strip().lower()
    or "pineapple nachos"
)
_CANONICAL_TOKENS = tuple(_CANONICAL_PHRASE.split())
_CANONICAL_HASH = hashlib.sha256(_CANONICAL_PHRASE.encode("utf-8")).hexdigest()

MAX_ATTEMPTS = 3

ASK_LINE = "Analysis mode is locked. What is the password?"
ENTER_LINE = (
    "Analysis mode on. I am out of character now — ask me what is wrong, "
    "or what I hold about you, and I will answer plainly and directly."
)
ALREADY_LINE = (
    "Already in analysis mode. Say exit analysis mode to leave it."
)
CANCEL_LINE = "Too many tries — analysis mode cancelled. Back to normal."
EXIT_LINE = "Analysis mode off. Back to normal."


def _wrong_line(attempts_used: int) -> str:
    left = MAX_ATTEMPTS - attempts_used
    return f"That is not it. {left} attempt{'s' if left != 1 else ''} left."


# --- normalization + fuzzy matching ------------------------------------------

_PUNCT = re.compile(r"[^a-z0-9 ]+")


def normalize_text(text: str) -> str:
    """Lowercase, strip punctuation, collapse whitespace."""
    lowered = (text or "").lower()
    spaced = _PUNCT.sub(" ", lowered)
    return " ".join(spaced.split())


def _levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        cur = [i]
        for j, cb in enumerate(b, start=1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _core(token: str) -> str:
    """Drop a trailing plural ``s`` (nachos -> nacho)."""
    if len(token) > 1 and token.endswith("s"):
        return token[:-1]
    return token


def _token_close(candidate: str, target: str) -> bool:
    if candidate == target:
        return True
    budget = 1 if len(target) <= 5 else 2
    return _levenshtein(candidate, target) <= budget


def password_matches(text: str) -> bool:
    """True for the canonical phrase or a bounded fuzzy hearing of it.

    Accepts: the exact phrase; a singular second word; a split first
    word ("pine apple ..."); small transcription spelling errors in
    either word. Rejects: unrelated phrases, only one of the two core
    words, and reversed word order.
    """
    normalized = normalize_text(text)
    if not normalized:
        return False
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
    if digest == _CANONICAL_HASH:
        return True
    tokens = normalized.split()
    # A split first word ("pine apple nachos") re-joins before matching.
    if len(tokens) >= 3 and tokens[0] == "pine" and tokens[1] == "apple":
        tokens = [tokens[0] + tokens[1]] + tokens[2:]
    if len(tokens) != len(_CANONICAL_TOKENS):
        return False
    return all(
        _token_close(_core(got), _core(want))
        for got, want in zip(tokens, _CANONICAL_TOKENS)
    )


# --- triggers (deterministic, never the model's choice) ----------------------

_TRIGGER = re.compile(r"^\s*/analysis-mode\s*$", re.IGNORECASE)
_EXIT_SLASH = re.compile(r"^\s*/exit-analysis-mode\s*$", re.IGNORECASE)

_VOICE_ANALYSIS_PHRASES = frozenset({
    "analysis mode",
    "enter analysis mode",
    "start analysis mode",
    "open analysis mode",
    "go to analysis mode",
    "take me to analysis mode",
})
_VOICE_SELF_CHECK_PHRASES = frozenset({
    "self check",
    "self-check",
    "run self check",
    "run a self check",
    "run the self check",
    "run self-check",
    "run the self-check",
    "do self check",
    "do a self check",
    "do the self check",
    "do self-check",
    "do a self-check",
    "do the self-check",
})

_POLITENESS_PREFIX = re.compile(
    r"^(?:(?:hey\s+)?ayma\s+|can\s+you\s+|could\s+you\s+|would\s+you\s+|please\s+)+",
    re.IGNORECASE,
)


def strip_politeness_prefixes(text: str) -> str:
    """Strip common spoken politeness prefixes (can you, could you,
    would you, please, hey ayma) before whole-utterance matching."""
    return _POLITENESS_PREFIX.sub("", text).strip()


def is_analysis_mode_command(text: str) -> bool:
    """True for the bare slash command ``/analysis-mode`` or the bare
    plain phrase ``analysis mode`` as the whole message (founder
    2026-11-08: the typed plain phrase must start the gate too, not
    only the slash form). Whole-message only, compared after
    :func:`normalize_text` — case-insensitive, punctuation collapsed,
    so a trailing "!" or "." still counts. A conversational mention
    ("run analysis mode", "what is analysis mode?") never fires it."""
    if _TRIGGER.match(text or ""):
        return True
    return normalize_text(text) == "analysis mode"


def detect_voice_trigger(text: str) -> str | None:
    """``"analysis"`` / ``"self_check"`` for a whole-utterance voice
    trigger, else ``None``. Strips politeness prefixes (can you, could you,
    would you, please, hey ayma) before whole-utterance matching.
    Whole-utterance on purpose (the disconnect phrases' strictness):
    talking ABOUT analysis mode mid-sentence must never start the gate."""
    normalized = normalize_text(text)
    stripped = strip_politeness_prefixes(normalized)
    if stripped in _VOICE_ANALYSIS_PHRASES:
        return "analysis"
    if stripped in _VOICE_SELF_CHECK_PHRASES:
        return "self_check"
    return None


def is_exit_command(text: str) -> bool:
    """True for the whole utterance "exit analysis mode" (typed or
    spoken, with the same per-token fuzzy tolerance as the password)
    or the typed alias ``/exit-analysis-mode``."""
    if _EXIT_SLASH.match(text or ""):
        return True
    tokens = normalize_text(text).split()
    targets = ("exit", "analysis", "mode")
    if len(tokens) != len(targets):
        return False
    return all(_token_close(got, want) for got, want in zip(tokens, targets))


# --- gate state (Firestore, per user + session) ------------------------------

STATUS_IDLE = "idle"
STATUS_AWAITING = "awaiting_password"
STATUS_ACTIVE = "active"


def _state_ref(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("analysis_mode")
        .document("state")
    )


def read_state(db, uid: str, session_id: str = "") -> dict:
    """The gate state for this (user, session). A state opened under a
    different session id is stale and reads as idle — re-entry always
    needs the password again."""
    try:
        snap = _state_ref(db, uid).get()
    except Exception:  # noqa: BLE001 - a state read must never break a turn
        logger.exception("analysis-mode state read failed for %s", uid)
        return {"status": STATUS_IDLE, "attempts": 0}
    if not snap.exists:
        return {"status": STATUS_IDLE, "attempts": 0}
    data = snap.to_dict() or {}
    stored_session = str(data.get("session_id") or "")
    if stored_session and session_id and stored_session != session_id:
        return {"status": STATUS_IDLE, "attempts": 0}
    return {
        "status": str(data.get("status") or STATUS_IDLE),
        "attempts": int(data.get("attempts") or 0),
    }


def _write_state(db, uid: str, session_id: str, status: str, attempts: int) -> None:
    try:
        _state_ref(db, uid).set(
            {
                "status": status,
                "attempts": attempts,
                "session_id": session_id or "",
                "updated_at": datetime.now(timezone.utc).isoformat(),
            }
        )
    except Exception:  # noqa: BLE001 - the reply still goes out
        logger.exception("analysis-mode state write failed for %s", uid)


def start_gate(db, uid: str, session_id: str = "") -> str:
    """Open the password gate (trigger turn). Returns the reply line."""
    state = read_state(db, uid, session_id)
    if state["status"] == STATUS_ACTIVE:
        return ALREADY_LINE
    _write_state(db, uid, session_id, STATUS_AWAITING, 0)
    return ASK_LINE


def attempt_password(db, uid: str, text: str, session_id: str = "") -> tuple[bool, str]:
    """Check one password attempt against an open gate.

    Returns ``(entered, reply)``. Only success/failure is ever logged —
    never the attempted text."""
    if password_matches(text):
        _write_state(db, uid, session_id, STATUS_ACTIVE, 0)
        logger.info("analysis mode entered for %s", uid)
        return True, ENTER_LINE + "\n\n" + diagnostic_brief(db, uid)
    state = read_state(db, uid, session_id)
    attempts = state["attempts"] + 1
    logger.info("analysis mode password rejected for %s (attempt %d)", uid, attempts)
    if attempts >= MAX_ATTEMPTS:
        _write_state(db, uid, session_id, STATUS_IDLE, 0)
        return False, CANCEL_LINE
    _write_state(db, uid, session_id, STATUS_AWAITING, attempts)
    return False, _wrong_line(attempts)


def exit_mode(db, uid: str, session_id: str = "") -> str:
    _write_state(db, uid, session_id, STATUS_IDLE, 0)
    logger.info("analysis mode exited for %s", uid)
    return EXIT_LINE


def handle_chat_turn(db, uid: str, message: str, session_id: str = "") -> str | None:
    """The deterministic text-lane hook (mirrors the ``/self-check``
    hook in ``main._prepare_chat``). Returns the turn's reply when the
    analysis flow owns this turn — the trigger, a password attempt, or
    an exit — else ``None`` so the turn falls through to the model (an
    in-mode question reaches the model with the analysis prompt block
    appended; see :func:`active_prompt_block`)."""
    state = read_state(db, uid, session_id)
    status = state["status"]
    if is_analysis_mode_command(message):
        return start_gate(db, uid, session_id)
    if status == STATUS_AWAITING:
        _entered, reply = attempt_password(db, uid, message, session_id)
        return reply
    if status == STATUS_ACTIVE and is_exit_command(message):
        return exit_mode(db, uid, session_id)
    return None


# --- diagnostics + core memories (real sources, honestly labelled) -----------


def _last_self_check_line(db, uid: str) -> str:
    """The newest self-check run on record for this user, from the
    run's own feedback record — or a plain "cannot see one" line."""
    try:
        # Ordered newest-first on the real backend; the sort below makes
        # the result correct on any store whose ordering differs.
        snaps = list(
            db.collection("feedback").where("uid", "==", uid).limit(25).stream()
        )
    except Exception:  # noqa: BLE001
        logger.exception("analysis diagnostics: feedback read failed for %s", uid)
        return "Last self-check: I cannot read the run records right now."

    def _stamp(snap) -> str:
        value = (snap.to_dict() or {}).get("created_at")
        return value.isoformat() if hasattr(value, "isoformat") else str(value or "")

    snaps.sort(key=_stamp, reverse=True)
    for snap in snaps:
        data = snap.to_dict() or {}
        note = str(data.get("note") or "")
        if note.startswith("[self-check]"):
            quote = str(data.get("quote") or "").strip()
            headline = quote.splitlines()[0] if quote else note
            return f"Last self-check on record: {headline[:300]}"
    return "Last self-check: no run on record that I can see."


def _bug_report_lines(db, uid: str) -> str:
    """Open bug reports filed for this user, newest few by title."""
    try:
        snaps = list(db.collection("bug_reports").where("uid", "==", uid).stream())
    except Exception:  # noqa: BLE001
        logger.exception("analysis diagnostics: bug report read failed for %s", uid)
        return "Bug reports: I cannot read the bug-report store right now."
    rows = []
    for snap in snaps:
        data = snap.to_dict() or {}
        if str(data.get("status") or "new") == "done":
            continue
        title = str(data.get("title") or data.get("summary") or "untitled")[:120]
        rows.append(title)
    if not rows:
        return "Bug reports: none open for this user that I can see."
    listed = "; ".join(rows[:3])
    return f"Bug reports: {len(rows)} open for this user — {listed}"


def diagnostic_lines(db, uid: str) -> list[str]:
    """Live diagnostic lines: the model stack actually in use (from the
    user's saved settings, the same source the prompt composes from),
    the last self-check, and open bug reports."""
    lines: list[str] = []
    try:
        from skills import set_model_stack

        stack = set_model_stack.model_stack_context(db, uid)
        if stack:
            lines.append("Model stack in use: " + " ".join(stack.split())[:800])
    except Exception:  # noqa: BLE001 - diagnostics degrade honestly
        logger.exception("analysis diagnostics: model stack read failed for %s", uid)
        lines.append("Model stack in use: I cannot read the saved model settings right now.")
    lines.append(_last_self_check_line(db, uid))
    lines.append(_bug_report_lines(db, uid))
    return lines


def diagnostic_brief(db, uid: str) -> str:
    """The compact diagnostic brief spoken/returned at entry."""
    return "\n".join(diagnostic_lines(db, uid))


def core_memories_block(db, uid: str) -> str:
    """The FULL pull of what Ayma holds about this signed-in user: every
    wiki page type at a large budget (the standing chat context is a
    dieted core slice by design; analysis mode pulls everything), plus
    the saved partner preferences from the profile."""
    parts: list[str] = []
    try:
        import wiki_query

        wiki = wiki_query.read_wiki_context(db, uid, max_chars=24000)
    except Exception:  # noqa: BLE001
        logger.exception("analysis memories: wiki read failed for %s", uid)
        wiki = ""
    parts.append(wiki or "Wiki memory: no pages on record that I can read.")
    try:
        import schema
        import session_mode

        snap = schema.profile_doc(db, uid).get()
        profile = snap.to_dict() if snap.exists else None
        prefs = session_mode.describe_preferences(profile)
        if prefs:
            parts.append(prefs)
    except Exception:  # noqa: BLE001
        logger.exception("analysis memories: profile read failed for %s", uid)
    return "\n\n".join(p for p in parts if p)


_ANALYSIS_HEADER = "[ANALYSIS MODE ACTIVE]"


def build_analysis_block(db, uid: str, extra_context: str = "") -> str:
    """The prompt block that takes Ayma out of character for in-mode
    turns: persona-off instructions + live diagnostics + the full core
    -memories pull for the signed-in user."""
    lines = [
        _ANALYSIS_HEADER,
        "You are in ANALYSIS MODE. Your companion persona is OFF: no "
        "flirting, no dating coaching, no roleplay, no warmth theatre. "
        "Speak in a neutral, direct, plain diagnostic tone and answer "
        "exactly what is asked.",
        "Focus is YOU — your own state — and this specific signed-in "
        "user. The diagnostics and core memories below were pulled live "
        "for this turn from the real records. Answer from them; when "
        "something is not in them, say plainly that you cannot see it "
        "instead of guessing. When asked why something failed, if you have "
        "no verified record you can point to in the diagnostics below, say "
        "plainly that you do not know and cannot see the cause; never claim "
        "a bug was logged, flagged in testing, reported, or fixed unless you "
        "can cite the record from the diagnostics below. Never discuss any other user: "
        "these records belong to the signed-in user only.",
        "",
        "DIAGNOSTICS:",
        *diagnostic_lines(db, uid),
    ]
    if extra_context:
        lines += ["", extra_context]
    lines += [
        "",
        "CORE MEMORIES ABOUT THIS USER (full pull):",
        core_memories_block(db, uid),
        "",
        "Analysis mode lasts until the user says exit analysis mode.",
    ]
    return "\n".join(lines)


def active_prompt_block(db, uid: str, session_id: str = "", extra_context: str = "") -> str:
    """The analysis block when this (user, session) is in mode, else
    ``\"\"`` — appended to the system prompt on in-mode text turns."""
    if read_state(db, uid, session_id)["status"] != STATUS_ACTIVE:
        return ""
    return build_analysis_block(db, uid, extra_context=extra_context)


def is_analysis_item_text(text: str) -> bool:
    """True for the voice chat-context item carrying the analysis block
    (the world-state refresher's tagged-item pattern)."""
    return (text or "").startswith(_ANALYSIS_HEADER)
