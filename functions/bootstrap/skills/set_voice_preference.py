"""``set_voice_preference`` — when the user asks mid-conversation for Ayma to
sound different (§13.3, §13.6).

Two kinds of change:

* **accent / language** ("speak with an Irish accent", "let's talk Malayalam")
  — Ayma starts speaking that way *now*; this tool persists it as the saved
  default. Gemini Live has no accent control, so in a live call the closest
  real mechanisms are applied: a BCP-47 language hint (e.g. "Indian accent" →
  ``en-IN``, direct Google route only) plus Ayma speaking that way per the
  prompt — and the result says exactly that.
* **voice character** (Aoede / Charon / Kore …) — a fixed Gemini Live preset.
  In a live voice call the agent worker reconnects the Live session in the new
  voice right away (:func:`bind_live` + agent.py ``VoiceSwapper``); from a
  text chat it takes effect from the next voice call.

Callable in both voice and text sessions.
"""

from __future__ import annotations

import logging
import re
from typing import Callable

from firebase_admin import firestore

import prompt
import voices

from ._base import Skill

logger = logging.getLogger("ayma.skills")

DESCRIPTION = (
    "Change how Ayma sounds, on an explicit request only (never just because "
    "they spoke another language). Voice CHARACTER incl. gender → `request` "
    f"(presets — {voices.presets_by_lean()}); which LANGUAGE she speaks → "
    "`accent_language`; her ACCENT / way of speaking (e.g. 'southern American "
    "accent', 'British accent', 'Indian who's been in America a while') → "
    "`accent`. All saved as default; relay the result truthfully."
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
                "description": "the LANGUAGE to speak (e.g. 'Malayalam', "
                "'Spanish'), never gender (that's `request`) and never an "
                "accent (that's `accent`), or ''",
            },
            "accent": {
                "type": "string",
                "description": "the ACCENT / way of speaking in their words "
                "(e.g. 'southern American accent', 'British accent'), or ''",
            },
        },
    },
}

# Returned when the user asks for an accent change but the active (or saved)
# voice model ships only fixed voices and cannot speak a different accent — so
# the agent says so clearly and points at the fix, instead of silently saving a
# setting that does nothing (which reads as broken). §13.9.
_ACCENT_NOT_SUPPORTED = (
    "this voice can't change its accent — it only speaks its one built-in "
    "accent. To change the accent, switch to an accent-capable voice model "
    "(like Gemini Live or OpenAI Realtime) in “Ayma’s models”, "
    "then set the accent there"
)

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

_UNCLEAR = (
    "couldn't tell what to change — ask them to name the voice "
    "style/gender or the accent/language they want"
)


# The only words looked for in `accent_language` (gender is not an accent, but
# the live model puts "a male voice ... American English" there anyway).
_GENDER_KEYWORDS: list[tuple[str, tuple[str, ...]]] = [
    ("Kore", ("female", "woman", "feminine", "girl", "lady")),
    ("Charon", ("male", "man", "masculine", "guy")),
]


def _has_word(text: str, words: tuple[str, ...]) -> bool:
    return any(re.search(rf"\b{re.escape(w)}\b", text) for w in words)


def _named_preset(text: str) -> str | None:
    """A preset named in ``text`` ("Puck", "the puck voice"), any case."""
    for name in voices.voice_names():
        if re.search(rf"\b{name}\b", text, re.IGNORECASE):
            return name
    return None


def _closest_preset(request: str) -> str | None:
    """A preset named outright in the request (the live model often passes
    the name it picked, e.g. ``request="Puck"``), else the keyword map over
    the fixed preset set (§13.3), whole words only. ``None`` when the request
    isn't about the voice character."""
    named = _named_preset(request)
    if named:
        return named
    r = request.lower()
    for preset, words in _KEYWORDS:
        if _has_word(r, words):
            return preset
    return None


def _gender_preset(accent_language: str) -> str | None:
    a = accent_language.lower()
    for preset, words in _GENDER_KEYWORDS:
        if _has_word(a, words):
            return preset
    return None


def _persist(
    db, uid: str, request: str, voice_name: str, accent_language: str
) -> tuple[str | None, str]:
    """Resolve and save the change. Returns ``(preset, accent)``; ``(None,
    "")`` — and nothing written — when nothing recognisable was asked for.
    The accent/language is stored as free text, verbatim; the character is one
    of the fixed presets."""
    preset = _named_preset(voice_name.strip()) if voice_name.strip() else None
    if not preset and request.strip():
        preset = _closest_preset(request)
    if not preset:
        preset = _gender_preset(accent_language)
    accent = accent_language.strip()[:200]
    if not preset and not accent:
        return None, ""

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
    return preset, accent


def _persist_accent(db, uid: str, accent: str) -> None:
    """Save the dedicated free-text ACCENT (``ayma_voice_accent``) verbatim.
    On a live Gemini call it hot-swaps the running session (``bind_live``
    routes it through the swapper); everywhere else it is routed to
    accent-capable providers at the next session boot
    (``agent._accent_block``); fixed-voice providers ignore it."""
    (
        db.collection("users").document(uid).collection("profile").document("main")
    ).set(
        {voices.PF_AYMA_VOICE_ACCENT: accent, "updated_at": firestore.SERVER_TIMESTAMP},
        merge=True,
    )


def _accent_clause(db, uid: str, accent: str, *, supports_accent: bool) -> str:
    """Handle a dedicated ACCENT request (§13.9). Returns a clause for the tool
    reply, or ``""`` when no accent was asked for. When the active/saved model
    cannot change accent, nothing is saved and the clause is the clear
    "switch models" message (:data:`_ACCENT_NOT_SUPPORTED`)."""
    accent = (accent or "").strip()[:200]
    if not accent:
        return ""
    if not supports_accent:
        return _ACCENT_NOT_SUPPORTED
    _persist_accent(db, uid, accent)
    return (
        f"accent → {accent} — saved as your default; it takes effect from your "
        "next voice call"
    )


def _combine(base: str, accent_clause: str) -> str:
    """Join the voice/language result with the accent result, where ``base`` may
    be :data:`_UNCLEAR` (nothing recognised). An accent clause always wins over a
    lone _UNCLEAR, so an accent-only request never reads as "couldn't tell"."""
    if accent_clause and base and base != _UNCLEAR:
        return f"{base}; {accent_clause}"
    if accent_clause:
        return accent_clause
    return base


def _profile(db, uid: str) -> dict:
    try:
        snap = db.collection("users").document(uid).collection("profile").document(
            "main"
        ).get()
        return snap.to_dict() or {}
    except Exception:  # noqa: BLE001 - a read failure must not break the tool
        logger.exception("could not read voice stack for accent gating (%s)", uid)
        return {}


def _bind(db, uid: str) -> Callable[..., str]:
    def set_voice_preference(
        request: str = "", voice_name: str = "", accent_language: str = "",
        accent: str = "",
    ) -> str:
        """Persist the voice character, language, and/or accent (text chat: all
        apply from the next voice call)."""
        acc_clause = ""
        if accent.strip():
            import voice_catalog

            acc_clause = _accent_clause(
                db, uid, accent,
                supports_accent=voice_catalog.accent_supported(_profile(db, uid)),
            )
        preset, lang = _persist(db, uid, request, voice_name, accent_language)
        if not preset and not lang:
            base = _UNCLEAR
        elif lang and not preset:
            base = (
                f"accent/language → {lang} — switching now and saved as your default"
            )
        elif preset and not lang:
            base = (
                f"voice → {preset} ({voices.VOICE_PRESETS[preset]}) — saved; "
                "it takes effect from your next voice call"
            )
        else:
            base = (
                f"accent/language → {lang} (switching now); voice → {preset} "
                f"({voices.VOICE_PRESETS[preset]}) from your next voice call — "
                "both saved as your default"
            )
        return _combine(base, acc_clause)

    return set_voice_preference


# ``on_change(preset, accent_language, *, voice_accent) ->
# (reconnecting, detail)`` — the live call's hot-swap hook (agent.py
# ``VoiceSwapper.request``). ``detail`` is the truthful one-line account of
# what actually changes on the Live session. The ``voice_accent`` keyword is
# passed only when an accent change was asked for, so a plain 2-arg hook keeps
# working for voice/language-only calls.
VoiceChangeHook = Callable[..., tuple[bool, str]]


def bind_live(db, uid: str, on_change: VoiceChangeHook) -> Callable[..., str]:
    """The live-voice-call variant: same persistence, but the change is applied
    to the running call through ``on_change`` and the result tells the model
    what really happened."""

    def set_voice_preference(
        request: str = "", voice_name: str = "", accent_language: str = "",
        accent: str = "",
    ) -> str:
        """Persist the voice character, the accent/language, and/or the
        dedicated ACCENT (``accent``) and apply it to this call right now —
        including the accent, which hot-swaps the live session. Always
        accent-capable here: this is the Gemini Live path."""
        new_accent = (accent or "").strip()[:200]
        if new_accent:
            _persist_accent(db, uid, new_accent)
        preset, lang = _persist(db, uid, request, voice_name, accent_language)
        if not preset and not lang and not new_accent:
            return _UNCLEAR
        if new_accent:
            reconnecting, detail = on_change(
                preset, lang, voice_accent=new_accent
            )
        else:
            reconnecting, detail = on_change(preset, lang)
        if reconnecting:
            base = f"{detail}. Saved as their default. {prompt.load_voice_swap_heads_up()}"
        else:
            base = f"{detail}. Saved as their default."
        return base

    return set_voice_preference


# --- Stack-aware (cascade / non-Gemini-realtime) live path (§13.9) ----------
#
# On a cascade (e.g. Muse-Spark brain + fishaudio TTS) or a non-Gemini realtime
# model, the switchable voices are NOT the Gemini Live presets — they are the
# active provider's voices (``voice_catalog.runtime_voices``). This path resolves
# the request within THAT set and persists the chosen voice id to
# ``ayma_tts_voice`` (the field the agent reads for every non-Gemini-preset
# voice). A mid-call hot-swap is Gemini-Live-only, so here the change is saved
# for the NEXT call and the result says exactly that.


def stack_description(runtime_voices) -> str:
    """The ``set_voice_preference`` tool description for a non-Gemini stack:
    names the active provider's voices instead of the Gemini presets, so the
    model never offers a voice the running stack can't produce."""
    names = ", ".join(v.label for v in runtime_voices.voices if v.id)
    names = names or "the provider's default voice"
    accent_rule = (
        "ACCENT (how she sounds) → `accent`. "
        if runtime_voices.supports_accent
        else "This voice CANNOT change its accent (fixed voice): if they ask for "
        "a different accent, tell them to pick an accent-capable model in "
        "“Ayma’s models”. "
    )
    return (
        "Change how Ayma sounds, on an explicit request only (never just "
        "because they spoke another language). Voice CHARACTER incl. gender → "
        f"`request`; the voices available on this call are: {names}. "
        f"LANGUAGE → `accent_language`. {accent_rule}A voice change applies from "
        "the NEXT call (this stack can't hot-swap mid-call); relay the result "
        "truthfully."
    )


def _persist_stack(
    db, uid: str, request: str, voice_name: str, accent_language: str, runtime_voices
) -> tuple[object | None, str]:
    """Resolve the voice within the ACTIVE provider's set and save it to
    ``ayma_tts_voice`` (plus the accent/language verbatim). Returns
    ``(voice, accent)``; ``(None, "")`` — nothing written — when nothing
    recognisable was asked for."""
    import schema
    import voice_catalog

    voice = None
    if voice_name.strip():
        voice = voice_catalog.resolve_voice(voice_name, runtime_voices.voices)
    if voice is None and request.strip():
        voice = voice_catalog.resolve_voice(request, runtime_voices.voices)
    if voice is None:
        # The live model sometimes puts gender in `accent_language` ("a male
        # voice … American English"); match only the gender there, never a
        # timbre word, so an accent request alone never changes the voice.
        voice = voice_catalog.resolve_voice(
            accent_language, runtime_voices.voices, gender_only=True
        )
    accent = accent_language.strip()[:200]
    if voice is None and not accent:
        return None, ""

    payload: dict = {"updated_at": firestore.SERVER_TIMESTAMP}
    if voice is not None:
        payload[schema.PF_AYMA_TTS_VOICE] = voice.id
    if accent:
        payload[voices.PF_AYMA_VOICE_LANGUAGE] = accent
    (
        db.collection("users").document(uid).collection("profile").document("main")
    ).set(payload, merge=True)
    return voice, accent


def bind_stack(db, uid: str, runtime_voices) -> Callable[..., str]:
    """The cascade / non-Gemini-realtime voice-call variant. Same accent/language
    handling as the Gemini path, but the voice CHARACTER is matched within
    ``runtime_voices`` (the active provider's set) and saved for the next call —
    there is no mid-call hot-swap on this stack."""

    def set_voice_preference(
        request: str = "", voice_name: str = "", accent_language: str = "",
        accent: str = "",
    ) -> str:
        """Persist the voice character (within the active stack's voices, from
        the next call), the language, and/or the dedicated ACCENT. The accent is
        only accepted when this stack's provider is accent-capable
        (``runtime_voices.supports_accent``); otherwise the reply says so and
        points at an accent-capable model in “Ayma’s models”."""
        acc_clause = _accent_clause(
            db, uid, accent, supports_accent=runtime_voices.supports_accent
        )
        voice, lang = _persist_stack(
            db, uid, request, voice_name, accent_language, runtime_voices
        )
        if voice is None and not lang:
            base = _UNCLEAR
        elif lang and voice is None:
            base = (
                f"accent/language → {lang} — speaking that way now and saved "
                "as your default"
            )
        else:
            label = f"{voice.label}" + (
                f" ({voice.description})" if voice.description else ""
            )
            if voice is not None and not lang:
                base = (
                    f"voice → {label} — saved; I'll switch to it on our next call "
                    "(this call's setup can't change voice mid-call)"
                )
            else:
                base = (
                    f"accent/language → {lang} (speaking that way now); voice → "
                    f"{label} from our next call (this call's setup can't change "
                    "voice mid-call) — both saved as your default"
                )
        return _combine(base, acc_clause)

    return set_voice_preference


SKILL = Skill(declaration=DECLARATION, bind=_bind)
