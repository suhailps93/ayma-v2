"""``set_voice_preference`` — when the user asks mid-conversation for Ayma to
sound different (§13.3, §13.6).

Two kinds of change, with different timing:

* **accent / language** ("speak with an Irish accent", "let's talk Malayalam")
  — Ayma can just start speaking that way *now* in the live call; this tool
  only persists it as the saved default. So the response says it's switching
  immediately.
* **voice character** (Aoede / Charon / Kore …) — set by the Gemini Live model
  at session start and can't hot-swap, so this takes effect from the next
  voice session.

Callable in both voice and text sessions.
"""

from __future__ import annotations

import logging
import re
from typing import Callable

from firebase_admin import firestore

import voices

from ._base import Skill

logger = logging.getLogger("ayma.skills")

DESCRIPTION = (
    "Change how Ayma sounds, on an explicit request only (never just because "
    "they spoke another language). Voice CHARACTER incl. gender → `request`, "
    "applies next session; ACCENT/LANGUAGE → `accent_language`, immediate and "
    "saved as default."
)

DECLARATION = {
    "name": "set_voice_preference",
    "description": DESCRIPTION,
    "parameters": {
        "type": "object",
        "properties": {
            "request": {
                "type": "string",
                "description": "the character ask in their words, or ''",
            },
            "voice_name": {
                "type": "string",
                "description": "optional exact preset name; overrides `request`",
            },
            "accent_language": {
                "type": "string",
                "description": "language/accent only, never gender "
                "(that's `request`), or ''",
            },
        },
    },
}

# Ordered most-specific first: the first group with a whole-word hit wins.
# Gendered descriptors come before the timbre words so "female" resolves to a
# feminine preset (and never trips the "male" in Charon's list).
_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    ("Fenrir", ("gravelly", "rough", "raspy", "intense")),
    ("Kore", ("female", "woman", "feminine", "she", "her", "girl", "lady",
              "even", "steady", "neutral", "measured", "professional")),
    ("Charon", ("male", "man", "masculine", "guy", "baritone", "he", "him",
                "deep", "low", "deeper")),
    ("Orus", ("firm", "confident", "assertive", "strong", "authoritative")),
    ("Zephyr", ("soft", "softer", "calm", "calmer", "soothing", "gentle",
                "quiet", "relax", "airy", "breathy")),
    ("Leda", ("young", "younger", "youthful", "upbeat", "bright", "light",
              "cheerful")),
    ("Puck", ("playful", "fun", "energetic", "lively", "quirky", "expressive")),
    ("Aoede", ("warm", "warmer", "friendly", "default")),
]


def _closest_preset(request: str) -> str | None:
    """Keyword map over the fixed preset set (§13.3), whole words only. ``None``
    when the request isn't about the voice character."""
    r = request.lower()
    for preset, words in _KEYWORDS:
        if any(re.search(rf"\b{re.escape(w)}\b", r) for w in words):
            return preset
    return None


def _bind(db, uid: str) -> Callable[..., str]:
    def set_voice_preference(
        request: str = "", voice_name: str = "", accent_language: str = ""
    ) -> str:
        """Persist the voice character and/or the accent/language. The
        accent/language is stored as free text, verbatim; the character is one
        of the fixed presets."""
        vn = voice_name.strip()
        if vn and voices.is_valid_voice(vn):
            preset = vn
        else:
            preset = _closest_preset(request) if request.strip() else None
        accent = accent_language.strip()[:200]
        if not preset and not accent:
            return (
                "couldn't tell what to change — ask them to name the voice "
                "style/gender or the accent/language they want"
            )

        payload: dict = {"updated_at": firestore.SERVER_TIMESTAMP}
        if preset:
            payload["ayma_voice_name"] = preset
        if accent:
            payload[voices.PF_AYMA_VOICE_LANGUAGE] = accent

        (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
        ).set(payload, merge=True)

        if accent and not preset:
            return (
                f"accent/language → {accent} — switching now and saved as "
                "your default"
            )
        if preset and not accent:
            return (
                f"voice → {preset} ({voices.VOICE_PRESETS[preset]}) — saved; "
                "it takes effect from your next voice call"
            )
        return (
            f"accent/language → {accent} (switching now); voice → {preset} "
            f"({voices.VOICE_PRESETS[preset]}) from your next voice call — "
            "both saved as your default"
        )

    return set_voice_preference


SKILL = Skill(declaration=DECLARATION, bind=_bind)
