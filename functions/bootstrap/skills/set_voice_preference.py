"""``set_voice_preference`` — when the user asks mid-conversation for Ayma to
sound different (§13.3, §13.6). Maps the request to the closest Gemini Live
preset, writes ``ayma_voice_name`` on ``users/{uid}/profile/main``, and tells
the caller it takes effect **next session** (Gemini Live sets the voice at
session start; it can't hot-swap mid-call).

Callable in both voice and text sessions.
"""

from __future__ import annotations

import logging
from typing import Callable

from firebase_admin import firestore

import voices

from ._base import Skill

logger = logging.getLogger("ayma.skills")

DESCRIPTION = (
    "Change the voice Ayma speaks with. Call this when the user asks you to "
    "sound different (deeper, warmer, younger, more masculine, etc.). Pass "
    "their request in their own words; you do not need to know preset names. "
    "The new voice applies from the next voice session, not the current call."
)

DECLARATION = {
    "name": "set_voice_preference",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "request": {
                "type": "string",
                "description": "what the user asked for, e.g. 'a deeper male "
                "voice' or 'something softer and calmer'",
            }
        },
        "required": ["request"],
    },
}

# Ordered most-specific first: the first group with a keyword hit wins.
_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    ("Fenrir", ("gravelly", "rough", "raspy", "intense")),
    ("Charon", ("deep", "low", "deeper", "masculine", "male", "man", "baritone")),
    ("Orus", ("firm", "confident", "assertive", "strong", "authoritative")),
    ("Zephyr", ("soft", "softer", "calm", "calmer", "soothing", "gentle",
                "quiet", "relax")),
    ("Kore", ("even", "steady", "neutral", "measured", "professional")),
    ("Leda", ("young", "younger", "youthful", "upbeat", "bright", "light",
              "cheerful")),
    ("Puck", ("playful", "fun", "energetic", "lively", "quirky", "expressive")),
    ("Aoede", ("warm", "warmer", "friendly", "default")),
]


def _closest_preset(request: str) -> str:
    """Keyword map over the fixed preset set (§13.3). Default last."""
    r = request.lower()
    for preset, words in _KEYWORDS:
        if any(w in r for w in words):
            return preset
    return "Aoede"


def _bind(db, uid: str) -> Callable[..., str]:
    def set_voice_preference(request: str) -> str:
        """Pick the closest preset and persist it for the next session."""
        if not request.strip():
            return "no voice request given"
        preset = _closest_preset(request)
        (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
        ).set(
            {
                "ayma_voice_name": preset,
                "updated_at": firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
        return (
            f"voice set to {preset} ({voices.VOICE_PRESETS[preset]}); "
            f"it takes effect from your next voice session"
        )

    return set_voice_preference


SKILL = Skill(declaration=DECLARATION, bind=_bind)
