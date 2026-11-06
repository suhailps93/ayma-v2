"""In-chat feedback bubble decisions (founder spec, 2026-11-06).

The bubble is a small card rendered INSIDE the chat stream that asks the
user what their feedback is: a text field they can type into, a dictate
affordance (their spoken words land in the same field via the chat
transcript), Submit and Dismiss. Submitting files through the existing
product-feedback path (``feedback_ops.record_submission``,
``source="chat_card"``) — this module never writes anything; it only
decides WHEN a bubble should be offered and with what prefill.

Two triggers:

* **explicit** — the user says/types "capture feedback" (or a close
  variant). Detected DETERMINISTICALLY here and mirrored client-side
  (``feedback_bubble.dart``), never left to the model's discretion: the
  old flow depended on the brain choosing to call ``submit_feedback``,
  which needs a drafted title/body and silently does nothing when the
  user has not said what the feedback IS yet. The phrase list is tight
  on purpose — a bare mention of the word "feedback" in ordinary
  conversation ("thanks for the feedback") must not pop a card.

* **frustration** — Ayma made a mistake / the user is frustrated WITH
  AYMA. Mechanism choice (the spec asked us to pick and justify):
  a RULE over signals we already have, not a model tool call.

  - The strongest signal is Ayma's own ``record_feedback`` firing this
    turn (its ``tools_used`` label is "Noted your feedback"): Ayma
    herself noticed her handling slipped. That is a fact, not a guess.
  - The second signal is a conservative lexical read of the user's own
    message for Ayma-directed frustration ("you keep asking", "not what
    I said", "you are not listening", ...). This stands in for the
    emotion-matching read on the text surface: text chat folds emotion
    into the reply-generating pass (``emotion.guidance_block``) and
    produces no structured label the bubble could consume, and adding a
    second model pass just for this would cost latency on every turn.
    On voice, the structured emotion read exists (voice-actions pass);
    :func:`decide_feedback_bubble` accepts it via ``emotion_label`` /
    ``emotion_intensity`` so the agent path can reuse the same rule
    (frustrated + medium/high only).

  A free-form model decision to "offer feedback now" was rejected: it
  fires unreliably, cannot be capped deterministically, and is exactly
  how you get false-positive nagging — the failure mode the founder
  called out. Distress never triggers an offer (care behaviour owns
  that path, see ``emotion.py``).

Caps: at most once per session per trigger, enforced by
:class:`FeedbackBubbleGate` (server) and mirrored client-side. The
bubble is only ever attached to a FINISHED turn's reply payload — it
renders in the chat after the exchange, never mid-voice-turn and never
as a spoken interruption.
"""

from __future__ import annotations

import re
import threading

# --- Explicit trigger -------------------------------------------------------

_EXPLICIT_PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in (
        r"\bcapture\s+(?:my\s+|some\s+|this\s+)?feedback\b",
        r"\brecord\s+(?:my\s+|some\s+|this\s+)?feedback\b",
        r"\btake\s+(?:my\s+|some\s+|this\s+)?feedback\b",
        r"\blog\s+(?:my\s+|some\s+|this\s+)?feedback\b",
        r"\bsubmit\s+(?:my\s+|some\s+|this\s+)?feedback\b",
        r"\bfeedback\s+capture\b",
        r"\bi\s+(?:want|would\s+like|need)\s+to\s+(?:give|leave|submit|share)\s+(?:some\s+|my\s+)?feedback\b",
        r"\bi\s+have\s+(?:some\s+)?feedback\b",
        r"\bgive\s+feedback\b",
        r"\bleave\s+feedback\b",
    )
]


def is_explicit_feedback_request(text: str) -> bool:
    """True when the user plainly asked to capture/give feedback."""
    t = (text or "").strip()
    if not t:
        return False
    return any(p.search(t) for p in _EXPLICIT_PATTERNS)


def extract_prefill(text: str) -> str:
    """Feedback content the user already stated alongside the trigger.

    "capture feedback: the mic keeps dropping" -> "the mic keeps
    dropping". Returns "" when the message is just the trigger phrase —
    the bubble then opens empty and asks.
    """
    t = (text or "").strip()
    for p in _EXPLICIT_PATTERNS:
        m = p.search(t)
        if m:
            rest = t[m.end():].strip().lstrip(":-\u2014").strip()
            # A trailing fragment like "please" / "now" is not content.
            if rest.lower() in ("", "please", "now", "please now"):
                return ""
            return rest[:4000]
    return ""


# --- Frustration signal -----------------------------------------------------

# Ayma-directed frustration, kept deliberately narrow: every phrase names
# Ayma's conduct (second person + a failure), not general unhappiness.
_FRUSTRATION_PATTERNS = [
    re.compile(p, re.IGNORECASE)
    for p in (
        r"\byou\s+keep\s+(asking|saying|repeating|doing)",
        r"\byou\s+(already|just)\s+asked",
        r"\byou\s+are\s+not\s+listening",
        r"\byou\s+aren.t\s+listening",
        r"\bnot\s+what\s+i\s+(said|asked|meant)",
        r"\bthat.s\s+not\s+what\s+i\s+(said|asked|meant)",
        r"\bstop\s+repeating",
        r"\byou\s+got\s+(it|that)\s+wrong",
        r"\bwrong\s+again\b",
        r"\byou\s+messed\s+up",
        r"\bthis\s+is\s+frustrating\b",
        r"\bi.m\s+frustrated\b",
        r"\bso\s+annoying\b",
        r"\byou\s+ignored\s+(my|what)",
        r"\bdidn.t\s+listen\b",
    )
]


def looks_frustrated_with_ayma(text: str) -> bool:
    """Conservative lexical read: frustration aimed at Ayma's conduct."""
    t = (text or "").strip()
    if not t:
        return False
    return any(p.search(t) for p in _FRUSTRATION_PATTERNS)


#: The ``tools_used`` label ``record_feedback`` contributes (tool_labels.py).
RECORD_FEEDBACK_LABEL = "Noted your feedback"


# --- Once-per-session-per-trigger gate ---------------------------------------


class FeedbackBubbleGate:
    """In-memory cap: each (session, trigger) may be offered once."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._offered: dict[str, set[str]] = {}

    def claim(self, session_key: str, trigger: str) -> bool:
        """True (and records the offer) iff this trigger has not been
        offered yet in this session."""
        if not session_key:
            session_key = "-"
        with self._lock:
            seen = self._offered.setdefault(session_key, set())
            if trigger in seen:
                return False
            seen.add(trigger)
            return True

    def reset(self, session_key: str) -> None:
        with self._lock:
            self._offered.pop(session_key, None)


#: Process-wide gate for the API server. Sessions are chat sessions
#: (``uid:session_id``); a fresh app session starts a fresh cap.
GATE = FeedbackBubbleGate()


# --- The decision -------------------------------------------------------------


def decide_feedback_bubble(
    *,
    uid: str,
    session_id: str,
    message: str,
    tools_used: list[str] | tuple[str, ...] = (),
    has_draft_card: bool = False,
    emotion_label: str = "",
    emotion_intensity: str = "",
    distress: bool = False,
    gate: FeedbackBubbleGate | None = None,
) -> dict | None:
    """``{"trigger": ..., "prefill": ...}`` when a bubble should be
    offered on this finished turn, else ``None``.

    An already-drafted ``submit_feedback`` card wins: the user is
    already looking at a confirmation card, so a second ask would be
    the nagging this feature must avoid. Distress suppresses the
    frustration trigger outright.
    """
    if has_draft_card:
        return None
    gate = gate or GATE
    key = f"{uid}:{session_id}"

    if is_explicit_feedback_request(message):
        if gate.claim(key, "explicit"):
            return {"trigger": "explicit", "prefill": extract_prefill(message)}
        return None

    frustrated = (
        RECORD_FEEDBACK_LABEL in (tools_used or ())
        or looks_frustrated_with_ayma(message)
        or (
            (emotion_label or "").strip().lower() == "frustrated"
            and (emotion_intensity or "").strip().lower() in ("medium", "high")
        )
    )
    if frustrated and not distress:
        if gate.claim(key, "frustration"):
            return {"trigger": "frustration", "prefill": ""}
    return None
