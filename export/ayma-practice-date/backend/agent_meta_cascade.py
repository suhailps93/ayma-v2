"""Practice Date voice cascade — the Meta "runs on Meta" additions (excerpt).

Hackathon Deliverable A (voice). This is a **clearly-marked excerpt** of the two
hackathon-new functions added to Ayma's private LiveKit voice-agent worker
(``functions/bootstrap/agent.py``): :func:`build_meta_cascade_session` and
:func:`relay_cascade_usage`. The surrounding worker (``entrypoint``,
``_run_session`` / ``_run_practice_session``, ``relay_practice_coach``, the room
seed plumbing, Gemini Live path, keepalive, idle watchdog, mute control, …) is
Ayma's private core and is **not included** — only the genuinely-new cascade
code is lifted here, verbatim, so it can be read in isolation.

The cascade lets a Practice Date **voice** session run end-to-end on Meta:

* **STT** Meta ``muse-voice-transcribe-1.0`` (``CONFIG.meta_transcribe_model``)
* **LLM** Meta Muse Spark ``muse-spark-1.3`` (``CONFIG.meta_chat_model``),
  ``reasoning_effort=minimal`` (Muse Spark is reasoning-only)
* **TTS** ``CONFIG.meta_cascade_tts_model`` (Inworld default) via the LiveKit
  Inference gateway
* **VAD** bundled Silero (``CONFIG.meta_cascade_vad_model``)

It is gated behind the ``voice`` surface flag ``LLM_PROVIDER_VOICE=meta``; the
default voice path stays Gemini Live, unchanged. A build failure (no key, plugin
missing) raises so the private worker falls back to Gemini Live — a flip can
never take voice down.

NOT RUNNABLE STANDALONE: this excerpt imports ``livekit-agents`` /
``livekit-plugins-openai`` and, in the full worker, Ayma-private helpers
(``voices.bcp47_hint``, the ``logger``). Its behaviour is exercised by the
cascade cases in ``tests/test_agent_cascade_reference.py`` (reference-only — see
that file's header). ``token_ledger`` here is Ayma's private lifetime-credit
ledger (documented-as-external; a minimal stand-in ships under ``_stubs/`` only
so the reference tests can import the module name).
"""

from __future__ import annotations

import logging
import os

from config import CONFIG

# --- External, NOT included (Ayma private core / third-party) --------------- #
# These resolve inside Ayma's private voice-agent worker + its requirements:
#   from livekit.agents import AgentSession, inference
#   from livekit.agents.metrics import LLMMetrics, MetricsCollectedEvent
#   import voices        # Ayma helper: voices.bcp47_hint(language) -> BCP-47 tag
#   import token_ledger  # Ayma lifetime-credit ledger
# They are imported lazily / at call time below exactly as in the private agent.
from livekit.agents import AgentSession  # type: ignore  # noqa: F401
from livekit.agents import MetricsCollectedEvent  # type: ignore

import token_ledger
import voices  # type: ignore  # noqa: F401 - Ayma private helper (not included)

logger = logging.getLogger("ayma.agent")


def build_meta_cascade_session(
    voice_name: str | None = None,
    voice_language: str | None = None,
) -> AgentSession:
    """Practice-voice Meta cascade (hackathon "runs on Meta"), behind
    ``LLM_PROVIDER_VOICE=meta`` — the default voice path stays Gemini Live.

    A LiveKit pipeline (cascade) ``AgentSession`` instead of a speech-to-speech
    ``RealtimeModel``:

    * **STT** — Meta ``muse-voice-transcribe-1.0`` (``CONFIG.meta_transcribe_model``)
      via ``livekit-plugins-openai`` pointed at the OpenAI-compatible Meta Model
      API (``CONFIG.meta_api_base_url`` + the ``META_API_KEY`` secret). The model
      is non-realtime, so the session wraps it with the VAD below.
    * **LLM** — Meta Muse Spark ``muse-spark-1.3`` (``CONFIG.meta_chat_model``) via
      the same openai plugin and base URL. Muse Spark is reasoning-only, so
      ``reasoning_effort`` is pinned to ``CONFIG.meta_reasoning_effort``
      (``minimal``) — without it replies come back empty.
    * **TTS** — ``CONFIG.meta_cascade_tts_model`` (Inworld by default) through the
      LiveKit Inference gateway (``inference.TTS``), authed with the worker's
      ``LIVEKIT_API_KEY``/``SECRET`` (LiveKit-credit covered). The vendor is
      config, never hardcoded here.
    * **VAD** — bundled Silero (``inference.VAD``), run locally in the worker to
      segment turns (the cascade has no server-side turn detection).

    Raises ``RuntimeError`` if ``META_API_KEY`` or ``livekit-plugins-openai`` is
    missing, so the caller falls back to Gemini Live and a flip can never take
    voice down. ``voice_language`` biases the STT language when given;
    ``voice_name`` (a Gemini voice preset) does not map to the TTS vendor's own
    voices, so the configured TTS voice governs.
    """
    api_key = os.getenv("META_API_KEY", "")
    if not api_key:
        raise RuntimeError(
            "META_API_KEY is not set — cannot run the Meta voice cascade "
            "(see docs/META_PROVIDER.md)"
        )
    try:
        from livekit.plugins import openai as lk_openai
    except ModuleNotFoundError as exc:  # pragma: no cover - dep in requirements
        raise RuntimeError(
            "livekit-plugins-openai is required for the Meta voice cascade"
        ) from exc
    from livekit.agents import inference

    base_url = CONFIG.meta_api_base_url
    stt_kwargs: dict[str, object] = {
        "model": CONFIG.meta_transcribe_model,
        "base_url": base_url,
        "api_key": api_key,
    }
    if voice_language:
        lang = voices.bcp47_hint(voice_language)
        if lang:
            stt_kwargs["language"] = lang
    stt = lk_openai.STT(**stt_kwargs)
    meta_llm = lk_openai.LLM(
        model=CONFIG.meta_chat_model,
        base_url=base_url,
        api_key=api_key,
        temperature=0.9,
        # Muse Spark is reasoning-only; the API floor is "minimal". The plugin
        # forwards this onto every chat completion — omitting it returns empty.
        reasoning_effort=CONFIG.meta_reasoning_effort,
    )
    tts_kwargs: dict[str, object] = {"model": CONFIG.meta_cascade_tts_model}
    if CONFIG.meta_cascade_tts_voice:
        tts_kwargs["voice"] = CONFIG.meta_cascade_tts_voice
    tts = inference.TTS(**tts_kwargs)
    vad = inference.VAD(model=CONFIG.meta_cascade_vad_model)
    return AgentSession(stt=stt, llm=meta_llm, tts=tts, vad=vad, allow_interruptions=True)


def relay_cascade_usage(
    session: AgentSession,
    uid: str,
    *,
    session_id: str = "",
    model: str = "",
) -> None:
    """Meter the Meta voice cascade's LLM turns against the user's token ledger.

    A cascade emits per-component ``LLMMetrics`` / ``STTMetrics`` / ``TTSMetrics``
    rather than the single ``RealtimeModelMetrics`` a Gemini Live session emits
    (which the private ``relay_token_usage`` records), so the lifetime credit cap
    would otherwise never see a Meta-cascade call. This records the Muse Spark LLM
    tokens under ``FEATURE_VOICE`` so the cap stays honest. Best-effort — a failed
    write never affects the call. (Real-dollar pricing for the Meta model is a
    separate Deliverable-A gap; tokens still drive the cap regardless.)"""
    if not uid:
        return
    from livekit.agents.metrics import LLMMetrics

    @session.on("metrics_collected")
    def _on_metrics(ev: MetricsCollectedEvent) -> None:
        m = ev.metrics
        if not isinstance(m, LLMMetrics):
            return
        in_tok = int(getattr(m, "prompt_tokens", 0) or 0)
        out_tok = int(getattr(m, "completion_tokens", 0) or 0)
        total = int(getattr(m, "total_tokens", 0) or 0) or (in_tok + out_tok)
        if total <= 0:
            return
        logger.info(
            "practice-cascade-usage uid=%s session=%s model=%s in=%d out=%d total=%d",
            uid, session_id or "?", model or "?", in_tok, out_tok, total,
        )
        token_ledger.add(
            uid,
            token_ledger.FEATURE_VOICE,
            total,
            input_tokens=in_tok,
            output_tokens=out_tok,
            model=model or None,
            session_id=session_id,
        )
