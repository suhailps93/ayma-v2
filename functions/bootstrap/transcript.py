"""Shared recent-turns window shape (§1.5).

The client keeps a bounded rolling window of interleaved voice + text turns and
sends it with every ``/chat`` and ``/bootstrap`` call so both entry points build
the same context (§13.5 layer 4). This module is dependency-free so both the
Main API and the agent worker (different dependency closures) can import it.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

ROLE_USER = "user"
ROLE_AYMA = "ayma"


@dataclass(frozen=True)
class Turn:
    role: str  # ROLE_USER | ROLE_AYMA
    text: str
    # When this turn was actually spoken/typed, as an ISO-8601 UTC string, set
    # the moment the turn is finalized (the voice agent stamps each transcript
    # segment as it lands — §1.7). Carried through to ``raw_turns`` so a history
    # reload shows each voice turn's own real time instead of the whole session
    # collapsing onto the single session-doc ``updated_at`` minute (founder bug
    # 2026-11-09). ``None`` for a turn seeded from prior history (it owns its
    # time at its original source) or a caller that has no per-turn time.
    # Excluded from equality/hash so existing (role, text) de-duplication is
    # unchanged.
    created_at: str | None = field(default=None, compare=False)


# Speech-control / vocalization markup a TTS-oriented model sometimes emits
# inline instead of plain words — e.g. ``<no speech>{pause}``, ``{laugh}``,
# ``<break time="400ms"/>``. It is a directive for the voice synthesizer, never
# meant to be read or persisted as chat text (founder bug 2026-11-09: an Ayma
# turn that was nothing but ``<no speech>{pause}`` rendered as a chat bubble).
# The keyword set is deliberately bounded so ordinary prose that merely contains
# a brace or an angle bracket is left untouched — only a bracketed run whose
# first token is one of these directives is stripped.
_SPEECH_DIRECTIVES = (
    r"no[\s_-]?speech",
    "pause",
    "long pause",
    "short pause",
    "break",
    "silence",
    "prosody",
    "emphasis",
    "say-as",
    "phoneme",
    "voice",
    "mark",
    "speak",
    "audio",
    "whisper",
    "laugh",
    "laughs",
    "laughter",
    "sigh",
    "sighs",
    "chuckle",
    "chuckles",
    "giggle",
    "giggles",
    "gasp",
    "cough",
    "clears throat",
    "beep",
)
_DIRECTIVE = "|".join(_SPEECH_DIRECTIVES)
# <no speech>, </prosody>, <break time="400ms"/>, <say-as interpret-as="...">
_ANGLE_MARKUP_RE = re.compile(
    r"<\s*/?\s*(?:" + _DIRECTIVE + r")\b[^<>]*>", re.IGNORECASE
)
# {pause}, {pause 500ms}, {laugh}, { long pause }
_CURLY_MARKUP_RE = re.compile(
    r"\{\s*(?:" + _DIRECTIVE + r")\b[^{}]*\}", re.IGNORECASE
)
# [pause], [laughs]
_SQUARE_MARKUP_RE = re.compile(
    r"\[\s*(?:" + _DIRECTIVE + r")\b[^\[\]]*\]", re.IGNORECASE
)


def strip_speech_markup(text: str) -> str:
    """Remove inline speech-control / vocalization markup from agent speech,
    leaving the genuine words. Returns ``""`` when the input was nothing but
    markup (the caller then drops the turn — it is not a chat message).

    Stripping happens in-place so a real step/line that merely contains a
    directive — ``"Take a look {pause} and say next"`` — keeps its words; only
    the directive token is removed, never the surrounding sentence."""
    if not text:
        return text
    cleaned = _ANGLE_MARKUP_RE.sub(" ", text)
    cleaned = _CURLY_MARKUP_RE.sub(" ", cleaned)
    cleaned = _SQUARE_MARKUP_RE.sub(" ", cleaned)
    # Tidy the whitespace / dangling punctuation the removals leave behind.
    cleaned = re.sub(r"[^\S\n]{2,}", " ", cleaned)
    cleaned = re.sub(r"[^\S\n]+([,.!?;:])", r"\1", cleaned)
    return cleaned.strip()


def format_recent_turns(turns: list[Turn]) -> str:
    """Render turns as a plain ``Speaker: text`` transcript for a system prompt."""
    out = []
    for turn in turns:
        who = "User" if turn.role == ROLE_USER else "Ayma"
        text = turn.text.strip()
        if text:
            out.append(f"{who}: {text}")
    return "\n".join(out)
