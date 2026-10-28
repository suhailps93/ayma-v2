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

_RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "translated": {"type": "string"},
        "detected_source_lang": {"type": "string"},
    },
    "required": ["translated", "detected_source_lang"],
}


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
    if isinstance(result, dict):
        if isinstance(result.get("translated"), str):
            translated = result["translated"].strip()
        if isinstance(result.get("detected_source_lang"), str):
            detected = result["detected_source_lang"].strip()
    # A model that returned no usable translation degrades to the original.
    if not translated:
        return _result(text, detected)
    return _result(translated, detected)
