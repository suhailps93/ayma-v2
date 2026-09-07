"""Gemini Live built-in HD voice presets (ARCHITECTURE.md §13.3).

A fixed set — not free-form synthesis. ``ayma_voice_name`` on
``users/{uid}/profile/main`` holds the chosen preset; the agent worker reads it
at session start (voice can't hot-swap mid-call). The default preset comes from
``CONFIG.gemini_live_voice`` per the AGENTS.md "model strings live in config"
rule; this module only names the selectable set and their character.
"""

from __future__ import annotations

# name -> short description used both for the settings picker and for the
# LLM "closest match" selection in the set_voice_preference skill.
VOICE_PRESETS: dict[str, str] = {
    "Aoede": "warm, bright, mid-range — the default",
    "Kore": "calm, even, gently authoritative — leans feminine",
    "Leda": "youthful, light, upbeat — leans feminine",
    "Zephyr": "airy, soft, soothing — leans feminine",
    "Puck": "playful, quick, expressive — gender-neutral",
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


# --- Speaking language / accent (§13.3) -------------------------------------
#
# BCP-47 code -> human label. Gemini Live picks the accent from the code. The
# user's pick lives in ``ayma_voice_language`` on ``profile/main``; empty means
# "let Ayma follow the conversation, defaulting to English". A mid-call switch
# by the caller is handled by the system prompt, not this list.

DEFAULT_LANGUAGE = "en-US"

# ``profile/main`` field holding the chosen code (sibling of
# ``schema.PF_AYMA_VOICE``).
PF_AYMA_VOICE_LANGUAGE = "ayma_voice_language"

VOICE_LANGUAGES: dict[str, str] = {
    "en-US": "English — American",
    "en-GB": "English — British",
    "en-IN": "English — Indian",
    "en-AU": "English — Australian",
    "en-IE": "English — Irish",
    "es-ES": "Spanish — Spain",
    "es-US": "Spanish — Latin America",
    "fr-FR": "French",
    "de-DE": "German",
    "it-IT": "Italian",
    "pt-BR": "Portuguese — Brazil",
    "hi-IN": "Hindi",
    "ar-XA": "Arabic",
    "ja-JP": "Japanese",
    "ko-KR": "Korean",
    "cmn-CN": "Mandarin Chinese",
    "nl-NL": "Dutch",
    "pl-PL": "Polish",
    "ru-RU": "Russian",
    "tr-TR": "Turkish",
}

# Free-text request keyword -> BCP-47 code, for the set_voice_preference skill.
# Most-specific first.
_LANGUAGE_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    ("en-IE", ("irish", "ireland", "irish accent")),
    ("en-GB", ("british", "britain", "england", "english accent", "uk accent",
               "posh", "received pronunciation")),
    ("en-IN", ("indian english", "indian accent")),
    ("en-AU", ("australian", "aussie")),
    ("en-US", ("american accent", "us accent", "american english")),
    ("es-US", ("latin american spanish", "mexican spanish", "latino")),
    ("es-ES", ("spanish", "español", "castilian", "castellano", "en español")),
    ("fr-FR", ("french", "français", "en français")),
    ("de-DE", ("german", "deutsch", "auf deutsch")),
    ("it-IT", ("italian", "italiano")),
    ("pt-BR", ("portuguese", "português", "brazilian")),
    ("hi-IN", ("hindi", "हिंदी")),
    ("ar-XA", ("arabic", "عربي")),
    ("ja-JP", ("japanese", "日本語", "nihongo")),
    ("ko-KR", ("korean", "한국어")),
    ("cmn-CN", ("mandarin", "chinese", "中文", "putonghua")),
    ("nl-NL", ("dutch", "nederlands")),
    ("pl-PL", ("polish", "polski")),
    ("ru-RU", ("russian", "русский")),
    ("tr-TR", ("turkish", "türkçe")),
]


def is_valid_language(code: str) -> bool:
    return code in VOICE_LANGUAGES


def language_label(code: str) -> str:
    return VOICE_LANGUAGES.get(code, code)


def closest_language(request: str) -> str | None:
    """Map a free-text "speak X" / "with an X accent" request to a BCP-47 code,
    or ``None`` when the request isn't about language/accent."""
    r = (request or "").lower()
    for code, words in _LANGUAGE_KEYWORDS:
        if any(w in r for w in words):
            return code
    return None
