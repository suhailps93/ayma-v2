"""Cross-language DM translation — the hackathon cross-language dating feature.

Two people who speak different languages can still connect: an incoming message
in a language other than the reader's preferred language is translatable (the
client shows the translation while keeping the original), and the reader can
optionally have their own outgoing draft translated into the match's language
before sending.

One function, :func:`translate`, backs ``POST /dm/translate``. It routes through
the LLM provider abstraction on the ``translate`` surface (``config.
llm_provider_translate``), which defaults to the Meta/Muse brain — this feature
is "powered by Muse". Detection and translation happen in one model call; when
the detected source language already equals the target, the model returns the
text unchanged (no pointless round-trip translation).

Translation is a *nicety* and must NEVER block a thread: on any failure it
returns the original text and an empty detected language, so the client simply
shows the original. Metered through ``token_ledger`` for cost visibility but
cap-exempt (``enforce_cap=False``) — a cross-language couple is never cut off
from reading each other because they are low on credits. Pair-only + 18+/consent
are enforced at the endpoint (``POST /dm/translate`` in ``main.py``): the caller
must be an adult participant of the thread whose text is being translated.
"""

from __future__ import annotations

import logging
from functools import lru_cache
from pathlib import Path

import llm_provider
import token_ledger

logger = logging.getLogger("ayma.dm")

_PROMPT_PATH = Path(__file__).with_name("prompts") / "dm_translate.md"
# A single DM message is short; cap the text we ever send to the model so this
# can't be abused as a bulk translation API (the client only ever sends one
# message body or one draft).
MAX_TEXT_CHARS = 4000

# Minimum model confidence required to surface a translation for text that is in
# the SAME writing system as the target language (typically Latin↔Latin, where
# short messages like "hello" or "hey" are easy to mis-detect as a foreign
# language). Below this, we assume the message is already in the reader's
# language and hand back the original — never offer "Translate" on ambiguous
# short Latin-script noise (§6.12). A DIFFERENT script (e.g. Malayalam) is
# reliable on script alone and is never gated on confidence.
CONFIDENCE_THRESHOLD = 0.75

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "translated": {"type": "string"},
        "detected_source_lang": {"type": "string"},
        "confidence": {"type": "number"},
    },
    "required": ["translated", "detected_source_lang", "confidence"],
}

# Coarse Unicode-script buckets — enough to tell whether a message is in a
# different writing system than the reader's language. Each entry is an
# inclusive codepoint range mapped to a bucket name. Mirrors the Flutter client
# (ayma_flutter/lib/utils/dm_language.dart) so both sides agree on "foreign
# script".
_SCRIPT_RANGES: tuple[tuple[int, int, str], ...] = (
    (0x0041, 0x005A, "latin"),
    (0x0061, 0x007A, "latin"),
    (0x00C0, 0x024F, "latin"),
    (0x0370, 0x03FF, "greek"),
    (0x0400, 0x04FF, "cyrillic"),
    (0x0590, 0x05FF, "hebrew"),
    (0x0600, 0x06FF, "arabic"),
    (0x0900, 0x097F, "devanagari"),
    (0x0980, 0x09FF, "bengali"),
    (0x0B80, 0x0BFF, "tamil"),
    (0x0C00, 0x0C7F, "telugu"),
    (0x0C80, 0x0CFF, "kannada"),
    (0x0D00, 0x0D7F, "malayalam"),
    (0x0E00, 0x0E7F, "thai"),
    (0x1100, 0x11FF, "hangul"),
    (0x3040, 0x30FF, "japanese"),
    (0x3400, 0x9FFF, "cjk"),
    (0xAC00, 0xD7AF, "hangul"),
)

# Non-Latin-script languages, by base code. Anything not listed (en, es, fr,
# de, pt, it, nl, tr, vi, id, …) is treated as Latin-script — the safe default,
# since an unknown target that is actually Latin keeps short same-script text
# out of the "offer Translate" path.
_NON_LATIN_LANG_SCRIPTS: dict[str, str] = {
    "ml": "malayalam", "ta": "tamil", "te": "telugu", "kn": "kannada",
    "hi": "devanagari", "mr": "devanagari", "ne": "devanagari",
    "bn": "bengali", "ar": "arabic", "ur": "arabic", "fa": "arabic",
    "ru": "cyrillic", "uk": "cyrillic", "bg": "cyrillic", "sr": "cyrillic",
    "el": "greek", "he": "hebrew", "th": "thai",
    "zh": "cjk", "ja": "japanese", "ko": "hangul",
}


def _script_of_char(code: int) -> str | None:
    for lo, hi, name in _SCRIPT_RANGES:
        if lo <= code <= hi:
            return name
    return None  # punctuation, digits, emoji, whitespace, symbols


def _dominant_script(text: str) -> str:
    """The writing system most of ``text``'s letters are in, or ``"none"`` when
    it carries no classified letters (emoji/numbers/punctuation only)."""
    counts: dict[str, int] = {}
    for ch in text:
        name = _script_of_char(ord(ch))
        if name is not None:
            counts[name] = counts.get(name, 0) + 1
    if not counts:
        return "none"
    return max(counts, key=lambda k: counts[k])


def _script_of_lang(code: str) -> str:
    base = code.strip().lower().replace("_", "-").split("-", 1)[0]
    if not base:
        return "latin"
    return _NON_LATIN_LANG_SCRIPTS.get(base, "latin")


def _norm_lang(code: str) -> str:
    return code.strip().lower().replace("_", "-").split("-", 1)[0]


def _coerce_confidence(value: object) -> float:
    try:
        conf = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0.0
    if conf != conf:  # NaN
        return 0.0
    return max(0.0, min(1.0, conf))


def _should_surface_translation(
    original: str,
    translated: str,
    detected: str,
    confidence: float,
    target: str,
) -> bool:
    """Whether to show ``translated`` (True) or treat ``original`` as already in
    the reader's language and hand it straight back (False).

    The rule, from §6.12: only surface a translation when the message is
    CONFIDENTLY in a language different from ``target``.

    - No real change (empty translation, or identical to the original) → False.
    - Detected source already equals the target language → False.
    - A different writing system than the target (e.g. Malayalam text, English
      target) → True, regardless of confidence — script detection is reliable
      even for very short messages.
    - Same writing system (typically Latin↔Latin): only True when the model is
      confident (``confidence >= CONFIDENCE_THRESHOLD``) AND the detected source
      differs from the target. Short, ambiguous Latin-script text ("hello",
      "hey") falls through to False.
    """
    original = (original or "").strip()
    translated = (translated or "").strip()
    if not translated or translated == original:
        return False

    norm_detected = _norm_lang(detected)
    norm_target = _norm_lang(target)
    if norm_detected and norm_detected == norm_target:
        return False

    text_script = _dominant_script(original)
    target_script = _script_of_lang(target)
    if text_script not in ("none", target_script):
        # Different writing system — reliably foreign on script alone.
        return True

    # Same writing system: trust only a confident, different-language detection.
    return (
        bool(norm_detected)
        and norm_detected != norm_target
        and confidence >= CONFIDENCE_THRESHOLD
    )


@lru_cache(maxsize=1)
def _load_prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


def _result(translated: str, detected: str) -> dict[str, str]:
    return {"translated": translated, "detected_source_lang": detected}


async def translate(
    text: str,
    target_lang: str,
    source_lang: str | None = None,
    *,
    uid: str | None = None,
) -> dict[str, str]:
    """Translate ``text`` into ``target_lang``, returning
    ``{"translated", "detected_source_lang"}``.

    ``source_lang`` is an optional hint; the model detects the real source and
    reports it in ``detected_source_lang``. When the detected source already
    equals the target the text is returned unchanged (no round-trip). Never
    raises and never blocks: an empty/over-long input or any model failure
    yields the original text with an empty ``detected_source_lang`` so the
    caller can simply show the original.
    """
    text = (text or "").strip()
    target_lang = (target_lang or "").strip()
    if not text or not target_lang:
        # Nothing to do / no target — hand the original straight back.
        return _result(text, "")
    if len(text) > MAX_TEXT_CHARS:
        text = text[:MAX_TEXT_CHARS]

    contents = (
        f"TARGET LANGUAGE: {target_lang}\n"
        f"SOURCE LANGUAGE: {(source_lang or '').strip()}\n"
        f"TEXT:\n{text}"
    )

    try:
        # Unified Brain (§13.10): the reader's chosen brain drives translation
        # (JSON); Muse Spark has json, so it is honoured, else Gemini. ``uid`` may
        # be None here (→ the env-flag default), which the resolver handles.
        provider = llm_provider.get_user_brain_provider(uid, "translate", needs="json")
        result = await provider.generate_json(
            contents,
            system_prompt=_load_prompt(),
            response_schema=_RESPONSE_SCHEMA,
            uid=uid,
            feature=token_ledger.FEATURE_DM_TRANSLATE,
            # Cap-exempt: translating what a match just said must not be gated
            # on the reader's credit balance. Still metered by generate_json.
            enforce_cap=False,
            temperature=0.2,
        )
    except Exception:  # noqa: BLE001 - translation is a nicety, never blocks
        logger.exception("dm translate generation failed")
        return _result(text, "")

    translated = ""
    detected = ""
    confidence = 0.0
    if isinstance(result, dict):
        if isinstance(result.get("translated"), str):
            translated = result["translated"].strip()
        if isinstance(result.get("detected_source_lang"), str):
            detected = result["detected_source_lang"].strip()
        confidence = _coerce_confidence(result.get("confidence"))
    # A model that returned no usable translation degrades to the original.
    if not translated:
        return _result(text, detected)
    # Only surface a translation when the message is CONFIDENTLY in a language
    # different from the target. Same-language text, ambiguous short Latin-script
    # messages, and low-confidence same-script guesses all fall back to the
    # original so the reader is never offered "Translate" on noise (§6.12).
    if not _should_surface_translation(
        text, translated, detected, confidence, target_lang
    ):
        return _result(text, detected)
    return _result(translated, detected)
