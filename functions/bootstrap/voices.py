"""Gemini Live built-in HD voice presets (ARCHITECTURE.md §13.3).

A fixed set — not free-form synthesis. ``ayma_voice_name`` on
``users/{uid}/profile/main`` holds the chosen preset; the agent worker reads it
at session start, and a mid-call change reconnects the Live session in the new
voice (agent.py ``VoiceSwapper``). The default preset comes from
``CONFIG.gemini_live_voice`` per the AGENTS.md "model strings live in config"
rule; this module only names the selectable set and their character.
"""

from __future__ import annotations

import re

# name -> short description used both for the settings picker and for the
# LLM "closest match" selection in the set_voice_preference skill.
VOICE_PRESETS: dict[str, str] = {
    "Aoede": "warm, bright, mid-range — leans feminine; the default",
    "Kore": "calm, even, gently authoritative — leans feminine",
    "Leda": "youthful, light, upbeat — leans feminine",
    "Zephyr": "airy, soft, soothing — leans feminine",
    "Puck": "playful, quick, expressive — leans masculine",
    "Charon": "deep, steady, measured — leans masculine",
    "Fenrir": "gravelly, low, intense — leans masculine",
    "Orus": "clear, firm, confident — leans masculine",
}


def voice_names() -> list[str]:
    return list(VOICE_PRESETS)


def is_valid_voice(name: str) -> bool:
    return name in VOICE_PRESETS


def presets_block() -> str:
    return "\n".join(f"- {n}: {d}" for n, d in VOICE_PRESETS.items())


def presets_by_lean() -> str:
    """``"feminine: Aoede, Kore, …; masculine: Charon, …"`` — derived from the
    descriptions above so the tool description never drifts from them."""
    groups: dict[str, list[str]] = {}
    for name, desc in VOICE_PRESETS.items():
        m = re.search(r"leans (\w+)", desc)
        groups.setdefault(m.group(1) if m else "other", []).append(name)
    return "; ".join(f"{k}: {', '.join(v)}" for k, v in groups.items())


# --- Speaking language / accent (§13.3) -------------------------------------
#
# A FREE-TEXT instruction, not a fixed list: "Malayalam mixed with English",
# "a soft Southern US accent", "British RP", "hablar en español". Lives in
# ``ayma_voice_language`` on ``profile/main`` — set on the settings screen or
# by ``set_voice_preference`` from what the user says. Empty = plain English.
# The Live model is steered by the system prompt; a mid-call switch by the
# caller is handled there too.

PF_AYMA_VOICE_LANGUAGE = "ayma_voice_language"

# Placeholder / helper examples for the settings text field.
LANGUAGE_EXAMPLES = (
    "Malayalam mixed with English",
    "a soft Southern US accent",
    "British RP",
    "Hindi",
    "Australian English",
)

_BCP47 = re.compile(r"^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$")


def looks_like_bcp47(text: str) -> bool:
    """True only for an exact-looking language tag (``en-GB``, ``cmn-CN``) — the
    one case where we can hand it straight to the Live model's ``language``
    kwarg. Free-text instructions go through the prompt instead."""
    return bool(_BCP47.match((text or "").strip()))


# Free-text accent/language preference -> a BCP-47 hint for Gemini Live's
# transcription. Without a hint, romanised Indian-language speech ("appo entha
# parupadi") gets misdetected (often as Chinese). First keyword hit wins; for a
# mix ("Malayalam and English") the non-English language wins because English is
# recognised well regardless.
_LANG_HINTS: list[tuple[str, str]] = [
    ("malayalam", "ml-IN"),
    ("manglish", "ml-IN"),
    ("tamil", "ta-IN"),
    ("telugu", "te-IN"),
    ("kannada", "kn-IN"),
    ("hindi", "hi-IN"),
    ("hinglish", "hi-IN"),
    ("marathi", "mr-IN"),
    ("bengali", "bn-IN"),
    ("punjabi", "pa-IN"),
    ("gujarati", "gu-IN"),
    ("urdu", "ur-PK"),
    ("arabic", "ar"),
    ("spanish", "es-ES"),
    ("french", "fr-FR"),
    ("german", "de-DE"),
    ("portuguese", "pt-BR"),
    ("italian", "it-IT"),
    ("mandarin", "cmn-CN"),
    ("chinese", "cmn-CN"),
    ("japanese", "ja-JP"),
    ("korean", "ko-KR"),
    ("russian", "ru-RU"),
    ("dutch", "nl-NL"),
    ("turkish", "tr-TR"),
    ("vietnamese", "vi-VN"),
    ("thai", "th-TH"),
    ("indonesian", "id-ID"),
    ("filipino", "fil-PH"),
    ("tagalog", "fil-PH"),
    ("british", "en-GB"),
    ("australian", "en-AU"),
    ("irish", "en-IE"),
    ("scottish", "en-GB"),
    ("indian english", "en-IN"),
    ("southern us", "en-US"),
    ("american", "en-US"),
    # Last: "an Indian accent" with no named Indian language → Indian English.
    ("indian", "en-IN"),
]


def bcp47_hint(text: str) -> str | None:
    """Best-guess BCP-47 code for a free-text language/accent preference, or
    ``None`` when nothing recognisable is in it."""
    t = (text or "").strip().lower()
    if not t:
        return None
    if looks_like_bcp47(text):
        return text.strip()
    for kw, code in _LANG_HINTS:
        if kw in t:
            return code
    return None
