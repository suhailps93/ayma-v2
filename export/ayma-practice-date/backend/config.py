"""Configuration — the Meta Model API + per-surface LLM-provider slice.

Hackathon-new config (Deliverable A). This is an **extract** of Ayma's private
``functions/bootstrap/config.py``: only the Meta Model API fields and the
per-surface provider flags that the hackathon components read. The private
``Config`` has many more fields (Gemini, LiveKit, Firestore, billing, …); none
of them are included here because none of the extracted components need them.

Per Ayma's engineering rules, **every model id lives only in this file** — no
model name is hardcoded anywhere in the feature code. The ``META_API_KEY`` is a
SECRET and is never stored here: it is read from the environment (Secret Manager
→ Cloud Run) at the call site in ``llm_provider.py`` / the voice cascade. The
base URL is non-secret config.

Field semantics and defaults match the private module exactly, so the extracted
``llm_provider`` / voice-cascade code behaves identically.
"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    """The Meta + LLM-provider configuration surface (frozen, like production)."""

    # --- Meta Model API (OpenAI-compatible; Muse Spark / Muse Voice) --------- #
    meta_api_base_url: str
    """OpenAI-compatible base URL of the Meta Model API. Non-secret; the
    ``META_API_KEY`` secret authenticates against it. Override ``META_API_BASE_URL``."""

    meta_chat_model: str
    """Meta Muse Spark LLM id for the chat / matching / reports / practice
    surfaces when their ``LLM_PROVIDER_*`` flag is ``meta``. Override ``META_CHAT_MODEL``."""

    meta_open_weights_model: str
    """Open-weights Muse Spark id (Baseten-hostable; the ``Best Build on Meta Open
    Weight Models`` target). Override ``META_OPEN_WEIGHTS_MODEL``. Not wired into a
    surface — exposed so an eval or self-hosted deployment can select it without a
    hardcoded id."""

    meta_transcribe_model: str
    """Meta Muse Voice Transcribe (STT) id for the voice cascade (STT leg) when
    ``LLM_PROVIDER_VOICE=meta``. Override ``META_TRANSCRIBE_MODEL``."""

    meta_cascade_tts_model: str
    """TTS model for the Meta voice cascade, in LiveKit Inference
    ``provider/model[:voice]`` form. Default Inworld; Rime and Fish are documented
    A/B alternatives. The vendor lives here, not in the agent code, so the flag can
    reach it. Override ``META_CASCADE_TTS_MODEL``."""

    meta_cascade_tts_voice: str
    """Optional voice preset for ``meta_cascade_tts_model`` (empty = vendor
    default). Override ``META_CASCADE_TTS_VOICE``."""

    meta_cascade_vad_model: str
    """VAD model that segments speech for the Meta cascade (bundled Silero via
    ``livekit.agents.inference.VAD``). Override ``META_CASCADE_VAD_MODEL``."""

    meta_reasoning_effort: str
    """Reasoning budget for Muse Spark chat calls. Muse Spark is reasoning-only;
    the API floor is ``minimal`` (``none`` is rejected). Pinned ``minimal`` so
    conversational replies stay fast. Override ``META_REASONING_EFFORT``
    (minimal|low|medium|high|xhigh|max)."""

    # --- Per-surface provider switch (gemini | meta) ------------------------- #
    llm_provider_chat: str
    llm_provider_matching: str
    llm_provider_reports: str
    llm_provider_practice: str
    llm_provider_voice: str
    """Per-surface provider switch, ``gemini`` | ``meta``. Each surface flips and
    rolls back independently via ``LLM_PROVIDER_<SURFACE>``; ``LLM_PROVIDER`` sets
    the default for any surface whose own var is unset. ALL default to ``gemini`` —
    behaviour is unchanged until a surface is explicitly flipped. Read by
    ``llm_provider.get_llm_provider(surface)``."""

    llm_meta_fallback: bool
    """When a surface is routed to ``meta`` and the Meta call fails, retry once on
    Gemini. Default True — so a flip can never take a surface down.
    ``LLM_META_FALLBACK=false`` to disable (e.g. in an eval measuring Meta alone)."""


def _load() -> Config:
    """Build the config from the environment (defaults match production)."""
    return Config(
        meta_api_base_url=os.getenv(
            "META_API_BASE_URL", "https://api.meta.ai/v1"
        ).rstrip("/"),
        meta_chat_model=os.getenv("META_CHAT_MODEL", "muse-spark-1.3"),
        meta_open_weights_model=os.getenv(
            "META_OPEN_WEIGHTS_MODEL", "meta-models/muse-spark-open-1026"
        ),
        meta_transcribe_model=os.getenv(
            "META_TRANSCRIBE_MODEL", "muse-voice-transcribe-1.0"
        ),
        meta_cascade_tts_model=os.getenv(
            "META_CASCADE_TTS_MODEL", "inworld/inworld-tts-1"
        ),
        meta_cascade_tts_voice=os.getenv("META_CASCADE_TTS_VOICE", ""),
        meta_cascade_vad_model=os.getenv("META_CASCADE_VAD_MODEL", "silero"),
        meta_reasoning_effort=os.getenv("META_REASONING_EFFORT", "minimal"),
        llm_provider_chat=os.getenv(
            "LLM_PROVIDER_CHAT", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        llm_provider_matching=os.getenv(
            "LLM_PROVIDER_MATCHING", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        llm_provider_reports=os.getenv(
            "LLM_PROVIDER_REPORTS", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        llm_provider_practice=os.getenv(
            "LLM_PROVIDER_PRACTICE", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        llm_provider_voice=os.getenv(
            "LLM_PROVIDER_VOICE", os.getenv("LLM_PROVIDER", "gemini")
        ).strip().lower(),
        llm_meta_fallback=os.getenv("LLM_META_FALLBACK", "true").strip().lower()
        == "true",
    )


CONFIG = _load()
