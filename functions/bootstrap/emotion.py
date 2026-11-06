"""Emotion-matched responses (founder directive, 2026-11-06).

Ayma reads the user's emotional state from what they say and meets it —
reply content, tone, and (on the cascade voice path) the Cartesia delivery
— on every surface: text chat, cascade voice, and realtime voice.

Design (full doc: ``docs/EMOTION_MATCHING.md``):

* **One read, folded into passes that already run.** On voice, the read
  rides the voice-actions skill's single LiveKit-Inference pass
  (``skills.voice_actions`` adds ``emotion`` / ``emotion_intensity`` /
  ``distress`` fields to the SAME structured response — no extra gateway
  call, no added latency). In text chat the reply-generating brain pass
  itself does the read: the standing guidance in :func:`guidance_block`
  is appended to that turn's system prompt, so the model reads the latest
  message as part of generating its reply — again zero extra calls.
* **Session-scoped state, never a profile trait.** :class:`EmotionState`
  lives in memory for one chat/voice session only. Nothing here writes
  to Firestore or the user's profile; whether emotion history should
  ever be stored is a founder decision (flagged in the design doc), not
  something this module decides.
* **Matching means meeting, not mirroring.** Upset is de-escalated, never
  matched back; sadness gets softness, not cheer; wins get a brief
  celebration, not a parade. Ayma never names the detection mechanically
  ("you seem sad") unless it fits naturally.
* **Distress is not an emotion to match.** A read with ``distress=True``
  (self-harm / crisis signals) routes to care behaviour: the guidance
  line switches to the care directive and the voice delivery goes calm
  and slow, whatever the label says.

Everything is gated by the ``emotion_matching`` feature flag
(``feature_flags`` registry, default OFF); call sites check the flag
before touching anything in this module's behaviour.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

logger = logging.getLogger("ayma.emotion")

# The label set: small on purpose. These are the states Ayma can usefully
# *do* something different for; anything finer is noise the model will
# flicker between turn to turn.
LABELS = (
    "neutral",
    "upbeat",
    "playful",
    "frustrated",
    "sad",
    "anxious",
    "tired",
)

INTENSITIES = ("low", "medium", "high")

# A read stays "current" for this many subsequent user turns before the
# state decays back to neutral (emotions are sticky, not permanent; a
# three-turn-old frustration should not colour a fresh topic forever).
DECAY_TURNS = 3


@dataclass(frozen=True)
class EmotionRead:
    """One turn's read: a label, an intensity, and the distress flag."""

    label: str = "neutral"
    intensity: str = "low"
    distress: bool = False


def normalize_read(
    label: object = "",
    intensity: object = "",
    distress: object = False,
) -> EmotionRead:
    """Untrusted model output -> a safe :class:`EmotionRead`.

    Anything unrecognised degrades to neutral/low — a bad read must never
    produce a weird delivery, only an ordinary one. ``distress`` is taken
    at face value when truthy: for the care path, a false positive (a
    gentle reply to a fine user) costs far less than a false negative.
    """
    lab = str(label or "").strip().lower()
    if lab not in LABELS:
        lab = "neutral"
    inten = str(intensity or "").strip().lower()
    if inten not in INTENSITIES:
        inten = "low" if lab == "neutral" else "medium"
    if isinstance(distress, str):
        distressed = distress.strip().lower() in ("true", "1", "yes")
    else:
        distressed = bool(distress)
    return EmotionRead(label=lab, intensity=inten, distress=distressed)


class EmotionState:
    """The session's current emotional read, with turn-based decay.

    One instance per voice session (agent.py) — created when the session
    starts, dropped when it ends. ``update`` is called once per finalized
    user turn with that turn's read; ``current`` is what context
    injection and TTS delivery consult.
    """

    def __init__(self) -> None:
        self._read = EmotionRead()
        self._age = DECAY_TURNS + 1  # start decayed: neutral

    def update(self, read: EmotionRead) -> None:
        # Distress always lands immediately. A fresh non-neutral read
        # replaces the old one. A neutral read does NOT clear a live
        # state on the spot (people don't reset between sentences) — it
        # just lets the decay clock run.
        if read.distress or read.label != "neutral":
            self._read = read
            self._age = 0
        else:
            self._age += 1

    def note_turn(self) -> None:
        """Advance the decay clock for a turn that carried no new read."""
        self._age += 1

    def current(self) -> EmotionRead:
        if self._age > DECAY_TURNS:
            return EmotionRead()
        return self._read

    @property
    def active(self) -> bool:
        cur = self.current()
        return cur.distress or cur.label != "neutral"


# --- Response adjustment ---------------------------------------------------

# Per-label reply guidance: what Ayma DOES differently. Kept terse — this
# rides inside prompts, and every line has to earn its tokens.
_ADJUSTMENTS = {
    "upbeat": (
        "match their energy warmly and celebrate the win briefly, then "
        "keep things moving — do not out-cheer them or stretch the moment"
    ),
    "playful": (
        "be playful back: lighter, wittier, a little teasing is welcome — "
        "match their play level, never go broader or cruder than they did"
    ),
    "frustrated": (
        "stay calm and unhurried, acknowledge the friction plainly without "
        "arguing or over-apologising, and get practical: name the concrete "
        "next step. Never mirror frustration back at them"
    ),
    "sad": (
        "soften: slower, gentler, fewer words. Make room rather than "
        "fixing; do not cheerlead or rush to silver linings"
    ),
    "anxious": (
        "be steady and reassuring: clear, concrete, one thing at a time. "
        "Reduce uncertainty where you honestly can; never amplify the worry"
    ),
    "tired": (
        "keep it light and low-effort for them: short replies, no big "
        "questions, offer to pick things up later without making it a thing"
    ),
    "neutral": "respond in your normal register",
}

_CARE_ADJUSTMENT = (
    "CARE: the user may be in distress. Drop any matching or playfulness. "
    "Be calm, warm and present; take what they said seriously, do not "
    "minimise it, and gently point to real-world help (in the US, call or "
    "text 988 for the Suicide and Crisis Lifeline) if they hint at harming "
    "themselves. Follow your standing care behaviour above all else"
)


def context_line(state: EmotionState | EmotionRead) -> str:
    """The one-line context injection for the brain's next reply.

    Internal guidance for the model — it is never spoken verbatim, and it
    deliberately tells Ayma NOT to narrate the detection.
    """
    read = state.current() if isinstance(state, EmotionState) else state
    if read.distress:
        return f"Emotional context (internal, never quote it): {_CARE_ADJUSTMENT}."
    if read.label == "neutral":
        return ""
    return (
        f"Emotional context (internal, never quote it or name the "
        f"detection mechanically — no 'you seem {read.label}'): the user's "
        f"current state reads as {read.label} ({read.intensity}). "
        f"Adjust: {_ADJUSTMENTS[read.label]}."
    )


_GUIDANCE_BLOCK = """\
EMOTION MATCHING (standing guidance):
Read the user's emotional state from their latest message and the recent
turns — word choice, punctuation, pace, what they are actually saying —
and meet it in your reply's content, tone, and (when you are speaking)
delivery:
- Upbeat: match the energy, celebrate briefly, keep moving.
- Playful: play back at their level; never broader or cruder than them.
- Frustrated: stay calm, acknowledge the friction plainly, get practical
  about the next step. Never mirror frustration, never argue.
- Sad: soften — slower, gentler, fewer words. Make room; do not rush to
  cheer them up or find silver linings.
- Anxious: be steady and concrete, one thing at a time; reduce
  uncertainty where you honestly can.
- Tired: keep it light and low-effort — short replies, no big asks.
Meet the state; never out-emote the user, and never name the detection
mechanically ("you seem sad") unless saying it plainly fits naturally.
If the user sounds in distress or hints at harming themselves, drop
matching entirely: be calm, warm and present, take it seriously, and
gently point to real-world help (in the US, call or text 988)."""


def guidance_block() -> str:
    """The standing emotion-matching guidance appended to system prompts
    (text chat per turn, voice via the session seed). This is what folds
    the read into the reply-generating pass itself on surfaces with no
    separate structured read."""
    return _GUIDANCE_BLOCK


def apply_to_prompt(system_prompt: str, *, enabled: bool) -> str:
    """``system_prompt`` with the guidance block appended when enabled —
    byte-identical to the input when not, so the flag-off path cannot
    drift from today's behaviour."""
    if not enabled:
        return system_prompt
    return f"{system_prompt}\n\n{_GUIDANCE_BLOCK}"


# --- Voice delivery (Cartesia) ----------------------------------------------

# Cartesia Sonic delivery mapping. The LiveKit plugin (1.8.9) accepts
# ``emotion`` as a list, but for sonic-3 models it sends only the FIRST
# entry as ``generation_config.emotion`` (a single string from Cartesia's
# emotion list) plus ``generation_config.speed`` as a float multiplier
# (0.6–1.5). So each state maps to exactly one Cartesia emotion word +
# one speed. Values are the plugin's ``TTSVoiceEmotion`` literals.
#
# Deliberately NOT a mirror: frustrated/anxious map to Calm (de-escalate),
# sad/distress to Sympathetic (soften), never to the user's own negative
# emotion. Neutral maps to nothing — Sonic's default behaviour already
# infers delivery from the reply text, which the brain has shaped.
_CARTESIA_DELIVERY: dict[str, dict[str, tuple[str | None, float | None]]] = {
    "upbeat": {"low": ("Content", 1.0), "medium": ("Content", 1.05), "high": ("Excited", 1.08)},
    "playful": {"low": ("Happy", 1.0), "medium": ("Happy", 1.05), "high": ("Excited", 1.08)},
    "frustrated": {"low": ("Calm", 0.98), "medium": ("Calm", 0.95), "high": ("Calm", 0.92)},
    "sad": {"low": ("Sympathetic", 0.97), "medium": ("Sympathetic", 0.94), "high": ("Sympathetic", 0.9)},
    "anxious": {"low": ("Calm", 0.97), "medium": ("Calm", 0.94), "high": ("Serene", 0.92)},
    "tired": {"low": ("Peaceful", 0.97), "medium": ("Peaceful", 0.94), "high": ("Peaceful", 0.9)},
    "neutral": {"low": (None, None), "medium": (None, None), "high": (None, None)},
}

_DISTRESS_DELIVERY: tuple[str | None, float | None] = ("Sympathetic", 0.9)


def cartesia_delivery(
    state: EmotionState | EmotionRead,
) -> tuple[str | None, float | None]:
    """``(emotion, speed)`` for the Cartesia TTS leg, or ``(None, None)``
    when Sonic should be left to infer delivery from the reply text."""
    read = state.current() if isinstance(state, EmotionState) else state
    if read.distress:
        return _DISTRESS_DELIVERY
    return _CARTESIA_DELIVERY[read.label][read.intensity]
