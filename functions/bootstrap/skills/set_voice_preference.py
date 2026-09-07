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
    "Change how Ayma sounds for future sessions: the voice character (deeper, "
    "warmer, younger, more masculine…) AND/OR the accent or language she "
    "speaks in ('talk with an Irish accent', \"let's speak Spanish\", 'use "
    "Hindi'). Call it when the user asks for a lasting change — pass their "
    "request in their own words. It updates their saved default and takes "
    "effect from the next voice session (not the current call). Do NOT call it "
    "just because the user spoke a sentence in another language — only for an "
    "explicit request to change."
)

DECLARATION = {
    "name": "set_voice_preference",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "request": {
                "type": "string",
                "description": "what the user asked for about the voice "
                "*character*, e.g. 'a deeper male voice', 'something softer'. "
                "Empty if they only asked about accent/language.",
            },
            "accent_language": {
                "type": "string",
                "description": "the accent/language to speak in, in the "
                "user's own plain words — 'a Southern US accent', 'Malayalam "
                "mixed with English', 'British RP', 'speak Spanish'. Empty if "
                "they only asked about the voice character.",
            },
        },
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


def _closest_preset(request: str) -> str | None:
    """Keyword map over the fixed preset set (§13.3). ``None`` when the request
    isn't about the voice character."""
    r = request.lower()
    for preset, words in _KEYWORDS:
        if any(w in r for w in words):
            return preset
    return None


def _bind(db, uid: str) -> Callable[..., str]:
    def set_voice_preference(
        request: str = "", accent_language: str = ""
    ) -> str:
        """Persist the voice character and/or the accent/language for the next
        session. ``accent_language`` is stored as free text, verbatim."""
        preset = _closest_preset(request) if request.strip() else None
        accent = accent_language.strip()[:200]
        if not preset and not accent:
            return (
                "couldn't tell what to change — ask them to name the voice "
                "style or the accent/language they want"
            )

        payload: dict = {"updated_at": firestore.SERVER_TIMESTAMP}
        parts: list[str] = []
        if preset:
            payload["ayma_voice_name"] = preset
            parts.append(f"voice → {preset} ({voices.VOICE_PRESETS[preset]})")
        if accent:
            payload[voices.PF_AYMA_VOICE_LANGUAGE] = accent
            parts.append(f"accent/language → {accent}")

        (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
        ).set(payload, merge=True)
        return (
            "; ".join(parts)
            + " — saved as your default, effective from the next voice session"
        )

    return set_voice_preference


SKILL = Skill(declaration=DECLARATION, bind=_bind)
