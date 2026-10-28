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


# Gender -> default built-in voice preset, used by Practice Date voice so a
# simulated match sounds like their profile gender (female persona -> a
# feminine-leaning voice, male -> masculine). The chosen presets are members of
# ``VOICE_PRESETS`` above (asserted below), so this never introduces a voice id
# that isn't in the catalog. Non-binary / unknown gender falls through to the
# session default (``CONFIG.gemini_live_voice``) — see :func:`voice_for_gender`.
_GENDER_VOICE: dict[str, str] = {"female": "Aoede", "male": "Charon"}

_FEMALE_GENDER_WORDS = frozenset(
    {"female", "woman", "women", "f", "girl", "lady", "she", "her", "feminine"}
)
_MALE_GENDER_WORDS = frozenset(
    {"male", "man", "men", "m", "guy", "boy", "he", "him", "masculine"}
)

assert all(v in VOICE_PRESETS for v in _GENDER_VOICE.values()), (
    "gender->voice mapping must only name presets defined in VOICE_PRESETS"
)


def voice_for_gender(gender: str | None) -> str:
    """Built-in voice preset matching a persona's ``gender`` for Practice Date.

    ``female``/``woman`` → a feminine-leaning preset, ``male``/``man`` → a
    masculine one. Returns ``""`` for non-binary, other, blank or unrecognised
    gender so the caller falls back to its own default voice
    (``CONFIG.gemini_live_voice``) — never a wrong-gender guess."""
    g = (gender or "").strip().lower()
    if not g:
        return ""
    if g in _FEMALE_GENDER_WORDS:
        return _GENDER_VOICE["female"]
    if g in _MALE_GENDER_WORDS:
        return _GENDER_VOICE["male"]
    return ""


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

# The user's saved ACCENT instruction — a dedicated free-text field, separate
# from the language selector (``ayma_voice_language``) above: HOW Ayma should
# sound, not WHICH language she speaks. "southern American accent", "California
# accent", "internet accent", "Indian who's been in America a while". Lives in
# ``ayma_voice_accent`` on ``profile/main``, set on the "Ayma's models" screen
# or by ``set_voice_preference``. It is handed to accent-capable providers at
# session boot (Gemini Live / OpenAI Realtime, via the instruction/style text);
# providers that ship only fixed voices ignore it (``voice_catalog.
# provider_supports_accent``). Empty = the provider's default accent.
PF_AYMA_VOICE_ACCENT = "ayma_voice_accent"

# Placeholder / helper examples for the accent text field.
ACCENT_EXAMPLES = (
    "southern American accent",
    "California accent",
    "British accent",
    "Indian who's been in America a while",
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


# A user line at most this many words long that carries a letter outside
# plain ASCII, from someone whose call language is English, is treated as a
# misheard fragment ("el número", "murió", "Größe") rather than a request.
_FRAGMENT_MAX_WORDS = 4


def is_misheard_fragment(text: str, preference: str) -> bool:
    """True when ``text`` (the caller's latest transcribed line) looks like
    speech recognition mishearing an English speaker as another language: a
    short line (up to ``_FRAGMENT_MAX_WORDS`` words) containing a non-ASCII
    letter, while the user's call language (``preference``) is English or
    unset. The voice agent refuses to run a tool on such a line (founder test
    2026-10-26: "el número" / "murió" turned a call Spanish). Never true for
    a user whose saved language is not English, where those letters are
    expected, nor for plain-ASCII lines like "yes" or "do it", so short
    confirmations still work."""
    hint = bcp47_hint(preference)
    if hint is not None and not hint.lower().startswith("en"):
        return False
    words = (text or "").split()
    if not words or len(words) > _FRAGMENT_MAX_WORDS:
        return False
    return any(ch.isalpha() and not ch.isascii() for ch in text)


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
