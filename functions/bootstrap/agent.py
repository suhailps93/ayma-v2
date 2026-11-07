"""Ayma LiveKit voice agent worker (ARCHITECTURE §1.1, §10.1, §1.7 step 3).

A separate Cloud Run deployable from the Main API (`main.py`). It holds an
outbound connection to LiveKit Cloud waiting for job dispatch; on dispatch it
joins the room and bridges the participant's audio to a Gemini Live session and
back.

Current scope:

* base persona instructions (shared `persona.md`, same character as `/chat`),
* default voice from `config.py`,
* Gemini Live's native (server-side) turn detection through the LiveKit
  Inference gateway — no client VAD; the gateway server-VAD silence/padding
  is env-overridable (see ``build_inference_realtime_model``),
* Step 15: native input/output transcription, relayed to the client as
  ``user_transcript`` / ``agent_transcript`` data-channel events (§1.6).
* "Shut up" muting: a mute-trigger phrase silences Ayma's auto-generated
  replies (no acknowledgment) until the caller says her name again — see
  ``relay_mute_control``.

Deferred to their own steps: wiki prompt seeding (§13.5, Step 24) and memory
extraction into ``wiki_pages`` (§2.3, Step 21).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import sys
import time
from dataclasses import dataclass, field
from typing import Awaitable, Callable

# Local dev only: load repo-root .env files before anything reads the
# environment (AGENTS.md §"Data & credentials"). Skipped under pytest and a
# no-op in the deployed container, which has no .env file.
if "pytest" not in sys.modules:  # pragma: no cover - dev/deploy only
    from pathlib import Path

    from dotenv import load_dotenv

    for _parent in Path(__file__).resolve().parents:
        if (_parent / ".env.local").exists() or (_parent / ".env").exists():
            load_dotenv(_parent / ".env.local")
            load_dotenv(_parent / ".env")
            break

from livekit.agents import (  # noqa: E402 - must follow the dotenv load
    Agent,
    AgentServer,
    AgentSession,
    AgentStateChangedEvent,
    ConversationItemAddedEvent,
    JobContext,
    JobProcess,
    JobRequest,
    MetricsCollectedEvent,
    RoomInputOptions,
    RoomOutputOptions,
    UserInputTranscribedEvent,
    WorkerOptions,
    cli,
    llm,
)
from livekit.agents.metrics import RealtimeModelMetrics  # noqa: E402
from livekit.agents.types import NOT_GIVEN, NotGivenOr  # noqa: E402

import context_opt  # noqa: E402
import emotion as emotion_mod  # noqa: E402
import feature_flags  # noqa: E402
from agent_keepalive import CallKeepAlive, KeepAliveServer  # noqa: E402
from idle_watchdog import IdleWatchdog  # noqa: E402
import llm_routing  # noqa: E402
import token_ledger  # noqa: E402
from config import CONFIG  # noqa: E402
from monitoring import capture_exception, capture_message, init_sentry  # noqa: E402

init_sentry("ayma-agent")  # no-op without SENTRY_DSN
from db import get_db  # noqa: E402
from livekit_token import room_env_mismatch, this_agent_serves_staging  # noqa: E402
from post_turn import persist_and_ingest  # noqa: E402
from prompt import (  # noqa: E402
    compose_system_prompt,
    load_practice_greeting,
    load_tour_tapped_kick,
    load_voice_session_seed,
    load_voice_tool_use,
    load_voice_verbatim_line,
    reconnect_back,
    voice_accent_directive,
    voice_swap_confirm,
    voice_swap_failed,
    voice_swap_note,
    voice_vocab_directive,
)
import schema  # noqa: E402
import skills  # noqa: E402
import voices  # noqa: E402
from tool_labels import NO_CHIP as _NO_CHIP  # noqa: E402
from tool_labels import GUIDED_TOUR_TOOLS as _GUIDED_TOUR_TOOLS  # noqa: E402
from tool_labels import NAV_CHIP_TOOLS as _NAV_CLAIM_TOOLS  # noqa: E402
from tool_labels import tool_label as _tool_label  # noqa: E402
from tool_labels import working_label as _working_label  # noqa: E402
from transcript import ROLE_AYMA, ROLE_USER, Turn  # noqa: E402

logger = logging.getLogger("ayma.agent")

# Data-channel topics the client listens on.
TOPIC_USER_TRANSCRIPT = "user_transcript"  # §1.6
TOPIC_AGENT_TRANSCRIPT = "agent_transcript"  # §1.6
TOPIC_AGENT_STATE = "agent_state"  # §1.3 — drives the client's speaking/barge-in UI
# A skill/tool call starting or finishing during a voice turn — the voice
# equivalent of the text chat's status -> reply kicker (gemini.py). Payload:
# {"name": tool name, "label": user-facing label, "phase": "start" | "end"}.
TOPIC_TOOL_USED = "tool_used"
# The agent is about to end the call itself, right before it disconnects —
# distinguishes a deliberate, graceful stop ("out_of_credits" §F3 mid-call
# credit cap, "idle_timeout", "user_goodbye") from an ordinary dropped
# connection so the client can show the right affordance (`cappedError` in
# `voice_session_controller.dart` for the credit cap) instead of a generic
# "connection dropped" error. Payload: {"reason": <reason>}.
TOPIC_CALL_ENDING = "call_ending"
# `call_ending` reason sent when there was no activity for the idle window
# (`CONFIG.voice_idle_timeout_seconds`).
REASON_IDLE_TIMEOUT = "idle_timeout"
# `call_ending` reason sent when the caller signed off ("goodbye Ayma") — a
# deliberate user hang-up, interpreted by the voice-actions skill.
REASON_USER_GOODBYE = "user_goodbye"
# Ayma was told to "shut up" (or called back by name) — published on every
# muted<->unmuted transition so the client can show an "Ayma is quiet" chip
# instead of a call that looks broken. Payload: {"muted": bool}. Also
# re-published whenever a participant (re)joins and in answer to every
# `agent_mute_control` message, so the client's view always matches.
TOPIC_AGENT_MUTE = "agent_mute"
# Client -> agent: the user tapped "Unmute" in the app (the quiet chip, the
# nav-bar orb, or the call notification's "Unmute Ayma" action). Payload:
# {"muted": false}. Only unmuting is accepted; muting stays a spoken command.
TOPIC_AGENT_MUTE_CONTROL = "agent_mute_control"
# Client -> agent: the user saved the voice settings mid-call ("Ayma's
# models" screen, §13.9). Payload: {"accent": free-text ayma_voice_accent,
# "language": saved ayma_voice_language label}; a missing key means unchanged,
# "" clears the accent back to the provider default. The agent hot-swaps the
# live session to it (``VoiceSwapper``) instead of waiting for the next call.
TOPIC_VOICE_ACCENT_CONTROL = "voice_accent_control"
# Client -> agent: the user tapped the guided tour's spotlighted control
# (§11.2b). Payload: {"index": int}. The agent turns it into a generate_reply
# so Ayma calls advance_guided_tour (consuming the already-written tour_event)
# and narrates the next step — the tap bridge that advances the tour without
# depending on a blocking advance_guided_tour being mid-wait at tap time.
TOPIC_TOUR_TAPPED = "tour_tapped"
# Practice Date voice (hackathon B): an out-of-character live coaching nudge to
# the USER as they talk to the simulated persona — shown as a side hint, never
# spoken by the persona (immersion is preserved). Payload: {"text", "is_final"}.
TOPIC_PRACTICE_COACH = "practice_coach"
# Honest open-weights voice status (§13.9). The open-weights cascade brain runs
# on a self-hosted, scale-to-zero Modal endpoint whose cold start is ~100s;
# published on session start so the client shows a specific "warming up — first
# reply can take a minute or two" instead of a silent "Listening…", and extends
# its no-first-response budget past the cold start (founder bug, 2026-11-02).
# Payload: {"state": "open_weights_warming"}.
TOPIC_VOICE_STATUS = "voice_status"
VOICE_STATUS_OPEN_WEIGHTS_WARMING = "open_weights_warming"
# A cascade TTS leg errored (e.g. an unknown-voice APIError): it produces no
# audio, and livekit only closes the session after several consecutive strikes,
# so the user would otherwise sit in silent "Listening…" until the ERROR-close
# fallback to Gemini Live fires. Signalled on the FIRST such error so the client
# shows an honest "the voice hit a snag, reconnecting…" instead of dead air
# (founder bug, staging 2026-11-03). Payload: {"state": "tts_error"}.
VOICE_STATUS_TTS_ERROR = "tts_error"
# User↔Ayma video + screen share (feedback item 13, 2026-11-06): the client
# publishes the user's camera / screen track into this same LiveKit room and
# the frames reach the model through the session's LiveKit video input
# (`RoomInputOptions(video_enabled=True)` in `_start_main_session` /
# `_start_main_cascade_session` — LiveKit-only inference, no new provider
# route). On session start the serving stack declares, on the same
# `voice_status` topic, whether it can actually perceive those frames:
# realtime models (Gemini Live) consume them natively and publish
# `vision_supported`; the cascade pipeline cannot consume video frames in
# livekit-agents 1.8.9 (`AgentActivity.push_video` forwards only to a
# realtime session), so it publishes `vision_unsupported` and the client
# never shows the toggles (founder rule: only models that support video
# perception expose the buttons). Payload: {"state": ...}.
VOICE_STATUS_VISION_SUPPORTED = "vision_supported"
VOICE_STATUS_VISION_UNSUPPORTED = "vision_unsupported"
# While a share is live the agent samples the user's video track (see
# `watch_vision_tracks`) and reports frame state on this topic. FLAG_SECURE
# surfaces (banking / password screens) arrive as pure-black frames:
# `secure_content` tells the client to show the honest notice, and Ayma's
# instructions (VISION_INSTRUCTIONS) carry the same rule for her speech —
# say she cannot see protected content, never guess at it. Payload:
# {"state": "secure_content" | "frames_flowing"}.
TOPIC_VISION_STATE = "vision_state"
VISION_STATE_SECURE_CONTENT = "secure_content"
VISION_STATE_FRAMES_FLOWING = "frames_flowing"
# Client → agent: the user toggled a vision source (the action-parity
# command names for the voice-call screen's Video / Screen share buttons).
# Payload: {"source": "camera" | "screen", "active": bool}. The agent's
# own track subscription stays the authoritative signal; this only clears
# stale secure-content state the moment a share ends.
TOPIC_VISION_CONTROL = "vision_control"

# Appended to the main-call instructions (both stacks) so Ayma's spoken
# behaviour matches the client UI for video / screen share.
VISION_INSTRUCTIONS = (
    "\n\n## Video and screen share\n"
    "During this call the user can turn on their camera or share their "
    "screen so you can see them or what they are looking at, and you may "
    "refer naturally to what you see while a share is live. If the video "
    "or shared screen is black or blank, that is protected content (a "
    "secure screen Android will not show you): say plainly that you "
    "cannot see protected content and ask the user to describe it or move "
    "to another screen — never guess, invent, or claim to see anything "
    "that is not actually in front of you. When no camera or screen share "
    "is on, do not claim to see the user or their screen."
)

#: Mean 0..255 luminance at or below this counts as a black frame — the
#: same threshold the co-pilot highlight build uses for FLAG_SECURE
#: detection (`kCopilotBlackLuminanceMax` / `BLACK_LUMINANCE_MAX` there),
#: so both features agree on what "Ayma cannot see this" means.
VISION_BLACK_LUMINANCE_MAX = 4.0

# Reused verbatim as the substance of Ayma's own spoken goodbye when credits
# run out mid-call (see `_end_call_out_of_credits`) — the same sentence the
# text-chat "out of credits" surfaces already use (`token_ledger.
# out_of_credits_message`), so voice and text read identically instead of a
# separately hand-typed line drifting from it over time.
_OUT_OF_CREDITS_LINE = token_ledger.out_of_credits_message(token_ledger.CONTEXT_CHAT)
_OUT_OF_CREDITS_INSTRUCTIONS = (
    "You've just run out of credits for this call and must stop talking with "
    "the caller after this. In your own warm voice, say one short sentence "
    "very close to: \"" + _OUT_OF_CREDITS_LINE + "\" Do not ask a question, "
    "do not invite more conversation, and do not say anything after it."
)
# How long to wait for that goodbye line to finish playing before giving up
# and ending the call anyway — a stuck TTS/network hiccup must never leave a
# broke user's call running indefinitely.
_OUT_OF_CREDITS_GOODBYE_TIMEOUT_SECONDS = 12


# --- Server-side turn detection (VAD) tuning --------------------------------
#
# Voice runs through the LiveKit Inference gateway, whose realtime protocol
# carries only server-VAD padding / silence. Both stay env-tunable on
# ayma-agent (no code deploy to adjust); the literal value "default" (or
# empty) leaves that field unset so the server default applies.
#
#   GEMINI_LIVE_PREFIX_PADDING_MS      int ms|default     default 300:
#       detected speech must persist ~0.3s before start-of-speech commits, so
#       a breath, click, or cough doesn't open (and bill) a turn.
#   GEMINI_LIVE_SILENCE_DURATION_MS    int ms|default     default 700:
#       ~0.7s of non-speech before end-of-speech commits — mid-sentence
#       thinking pauses no longer cut the caller off / commit an empty tail
#       turn, while replies still start well under a second after the caller
#       actually finishes. Raise toward 1000 if callers feel cut off; lower
#       toward 500 if Ayma feels slow to answer.


def _env_ms(name: str, default: int) -> int | None:
    """Read an integer-milliseconds env knob; None means leave it unset."""
    raw = os.getenv(name, str(default)).strip().lower()
    if raw in ("", "default"):
        return None
    try:
        value = int(raw)
        if value < 0:
            raise ValueError
        return value
    except ValueError:
        logger.warning("%s=%r is not a non-negative integer — using %d",
                       name, raw, default)
        return default


def build_inference_realtime_model(voice: str, model: str | None = None):
    """Gemini Live through LiveKit Inference — the ONLY voice path (founder
    rule 2026-11-04, permanent: no direct-Google voice).

    ``model`` overrides ``CONFIG.inference_live_model`` so a per-user realtime
    selection (§13.9, a non-Gemini/non-OpenAI realtime model from the live
    LiveKit catalog) runs on the same gateway path.

    ``inference.RealtimeModel`` speaks the OpenAI realtime protocol to the
    gateway, which fronts ``google/gemini-3.8-live``. Only the knobs that
    protocol carries are passed: the voice preset, and server-VAD padding /
    silence from the env tuning above. Live probes
    (docs/LIVEKIT_INFERENCE_MIGRATION.md section 1b) proved only
    ``silence_duration_ms`` is honoured; Gemini-specific options (temperature,
    start/end sensitivity, sliding-window context compression, affective
    dialog, proactivity, language hint) are silently ignored by the gateway,
    so none are passed.

    Needs ``livekit-agents`` >= 1.8 (``requirements-agent.txt`` pins 1.8.9);
    the credentials are the ``LIVEKIT_API_KEY`` / ``LIVEKIT_API_SECRET`` the
    worker already runs with.
    """
    from livekit.agents import inference

    realtime_cls = getattr(inference, "RealtimeModel", None)
    if realtime_cls is None:
        raise RuntimeError(
            "VOICE_PROVIDER=inference needs livekit-agents >= 1.8 "
            "(inference.RealtimeModel is missing from the installed version)"
        )
    from openai.types.realtime.realtime_audio_input_turn_detection import ServerVad

    vad: dict[str, object] = {"type": "server_vad"}
    prefix = _env_ms("GEMINI_LIVE_PREFIX_PADDING_MS", 300)
    silence = _env_ms("GEMINI_LIVE_SILENCE_DURATION_MS", 700)
    if prefix is not None:
        vad["prefix_padding_ms"] = prefix
    if silence is not None:
        vad["silence_duration_ms"] = silence
    return realtime_cls(
        model=model or CONFIG.inference_live_model,
        voice=voice,
        turn_detection=ServerVad(**vad),
    )


def build_realtime_model(
    voice_name: str | None = None,
    language: str | None = None,
    route: str | None = None,
):
    """Construct the Gemini Live model — always through LiveKit Inference
    (founder rule 2026-11-04, permanent: no direct-Google voice — see
    ``docs/DIRECT_GOOGLE_KILL_AUDIT.md`` item 8).

    The model id comes only from ``config.py`` (AGENTS.md); ``voice_name`` is
    the user's ``ayma_voice_name`` preference (§13.3) when set and valid, else
    the ``config.py`` default. ``language`` and ``route`` are kept so every
    existing call site keeps working unchanged: the gateway ignores the
    language hint and there is only one route.
    """
    import voices

    voice = voice_name if voice_name and voices.is_valid_voice(voice_name) \
        else CONFIG.gemini_live_voice
    return build_inference_realtime_model(voice)


def _cascade_tts_voice_for_gender(gender: str | None) -> str:
    """The cascade (Inworld) TTS voice preset for a persona ``gender``: the
    gender-matched config voice when set, else the configured default
    (``CONFIG.meta_cascade_tts_voice``). The vendor voice ids live in
    ``config.py`` (AGENTS.md: no voice ids in ``agent.py``); an unset gender
    voice falls back safely so a flip can never pick a broken voice."""
    g = (gender or "").strip().lower()
    if g in voices._FEMALE_GENDER_WORDS and CONFIG.meta_cascade_tts_voice_female:
        return CONFIG.meta_cascade_tts_voice_female
    if g in voices._MALE_GENDER_WORDS and CONFIG.meta_cascade_tts_voice_male:
        return CONFIG.meta_cascade_tts_voice_male
    return CONFIG.meta_cascade_tts_voice


# --- Open-weights (small-context) cascade: context cap (§13.9) ---------------
# The open-weights brain (Modal-hosted Llama-3.1-8B) has a HARD context window
# (vLLM ``--max-model-len`` in scripts/modal_open_weights.py). The AgentSession
# sends the full, growing chat context every turn, so once system + history + new
# turn exceed that window the server returns ``400 maximum context length``
# (retryable=False) → the turn fails → the voice sticks on "Listening" (founder
# bug, 2026-11-02). Large-context brains (Meta Muse Spark, Gemini Live) never
# hit this, so the cap is applied ONLY to the open-weights leg, keyed off its
# configured window, leaving every other brain untrimmed.
#
# Conservative token estimate: ~3 chars/token (English runs ~4, so this
# over-counts → the cap trims a little early and NEVER under-counts into a 400),
# plus a fixed per-message overhead for the role/format tokens the server adds
# around each message.
_OW_CHARS_PER_TOKEN = 3
_OW_PER_MESSAGE_OVERHEAD_TOKENS = 8


def _est_item_tokens(item) -> int:
    text = getattr(item, "text_content", None) or ""
    return len(text) // _OW_CHARS_PER_TOKEN + _OW_PER_MESSAGE_OVERHEAD_TOKENS


def cap_chat_ctx(chat_ctx: "llm.ChatContext | None", token_budget: int):
    """Trim ``chat_ctx`` to fit ``token_budget`` estimated tokens for a
    small-context cascade brain (sliding window).

    Keeps ALL leading system messages (the persona prompt + rolling summary ride
    there, not in the turn history) and the MOST-RECENT turns, dropping the
    OLDEST non-system turns first. Returns the original object unchanged when it
    already fits — so a large-context brain, given a large/zero budget, is never
    over-trimmed. Never leaves a dangling ``function_call_output`` whose matching
    call was trimmed away."""
    if chat_ctx is None or token_budget <= 0:
        return chat_ctx
    items = list(chat_ctx.items)
    # Leading system messages are always kept (persona + summary ride here).
    head = []
    idx = 0
    while idx < len(items) and getattr(items[idx], "role", None) == "system":
        head.append(items[idx])
        idx += 1
    rest = items[idx:]
    head_tokens = sum(_est_item_tokens(it) for it in head)
    budget_rest = token_budget - head_tokens
    if budget_rest <= 0:
        # System prompt alone already fills the budget: send system-only (still a
        # valid, non-400 request) — the system prompt is never dropped.
        return llm.ChatContext(head) if head and len(head) != len(items) else chat_ctx
    # Walk newest → oldest, keeping a contiguous recent suffix that fits.
    kept_rev: list = []
    used = 0
    for it in reversed(rest):
        tok = _est_item_tokens(it)
        if used + tok > budget_rest:
            break
        kept_rev.append(it)
        used += tok
    kept = list(reversed(kept_rev))
    # Don't begin the kept tail on an orphan tool output (its call was trimmed).
    while kept and getattr(kept[0], "type", None) == "function_call_output":
        kept.pop(0)
    if len(head) + len(kept) == len(items):
        return chat_ctx  # nothing dropped — fits already
    return llm.ChatContext(head + kept)


def _build_context_capped_open_weights_llm(
    *, model: str, base_url: str, api_key: str, token_budget: int
):
    """An ``lk_openai.LLM`` whose ``chat()`` trims the ChatContext to
    ``token_budget`` before every call, so the small-context open-weights server
    never receives more than its window (:func:`cap_chat_ctx`). lk_openai is
    imported lazily, and a missing plugin raises the same ``RuntimeError`` the
    caller catches to fall back to Gemini Live."""
    try:
        from livekit.plugins import openai as lk_openai
    except ModuleNotFoundError as exc:  # pragma: no cover - dep in requirements
        raise RuntimeError(
            "livekit-plugins-openai is required for the open-weights cascade brain"
        ) from exc

    class _ContextCappedLLM(lk_openai.LLM):
        _ctx_token_budget = token_budget

        def chat(self, *, chat_ctx, **kwargs):
            return super().chat(
                chat_ctx=cap_chat_ctx(chat_ctx, self._ctx_token_budget), **kwargs
            )

    return _ContextCappedLLM(
        model=model, base_url=base_url, api_key=api_key, temperature=0.9
    )


def _build_cascade_brain(brain_id: str):
    """Build the cascade LLM leg for ``brain_id`` (§13.9). Two routes:

    * ``meta`` — Meta Muse Spark via ``livekit-plugins-openai`` pointed at the
      OpenAI-compatible Meta Model API (``CONFIG.meta_api_base_url`` +
      ``META_API_KEY``). Muse Spark is reasoning-only, so ``reasoning_effort`` is
      pinned to ``CONFIG.meta_reasoning_effort`` (``minimal``) — without it
      replies come back empty.
    * ``open-weights`` — a self-hosted OpenAI-compatible server (e.g. a
      Modal-hosted ``Llama-3.1-8B``) via ``livekit-plugins-openai`` pointed at
      ``CONFIG.open_weights_api_base_url`` (env ``OPEN_WEIGHTS_BASE_URL``), with
      the optional ``OPEN_WEIGHTS_API_KEY``. Opt-in only; never a default.
    * ``inference`` — any LiveKit-Inference-hosted LLM (``inference.LLM``),
      LiveKit-credit covered, no extra key.

    Model ids come from ``voice_catalog.brain_route`` (which reads ``config.py``),
    never hardcoded here. Raises ``RuntimeError`` when the brain, its key or its
    plugin is missing, so :func:`build_cascade_session`'s caller falls back to
    Gemini Live and a selection can never take the main voice down."""
    import voice_catalog

    route_model = voice_catalog.brain_route(brain_id)
    if route_model is None:
        raise RuntimeError(f"unknown cascade brain {brain_id!r}")
    route, model = route_model
    if route == voice_catalog.ROUTE_META:
        api_key = os.getenv("META_API_KEY", "")
        if not api_key:
            raise RuntimeError(
                "META_API_KEY is not set — cannot run the Meta cascade brain "
                "(see docs/META_PROVIDER.md)"
            )
        try:
            from livekit.plugins import openai as lk_openai
        except ModuleNotFoundError as exc:  # pragma: no cover - dep in requirements
            raise RuntimeError(
                "livekit-plugins-openai is required for the Meta cascade brain"
            ) from exc
        return lk_openai.LLM(
            model=model,
            base_url=CONFIG.meta_api_base_url,
            api_key=api_key,
            temperature=0.9,
            reasoning_effort=CONFIG.meta_reasoning_effort,
        )
    if route == voice_catalog.ROUTE_OPEN_WEIGHTS:
        base_url = CONFIG.open_weights_api_base_url
        if not base_url:
            raise RuntimeError(
                "OPEN_WEIGHTS_BASE_URL is not set — cannot run the open-weights "
                "cascade brain"
            )
        if not model:
            raise RuntimeError(
                "OPEN_WEIGHTS_MODEL is not set — cannot run the open-weights "
                "cascade brain (config.py must provide it; no hardcoded default)"
            )
        # The self-hosted server may be keyless; the OpenAI client still needs a
        # non-empty api_key, so fall back to a sentinel (NOT a credential) when
        # OPEN_WEIGHTS_API_KEY is unset. A real key, when the server needs one,
        # comes only from the environment / Secret Manager.
        api_key = os.getenv("OPEN_WEIGHTS_API_KEY", "") or "not-needed"
        # Cap the sent context to the model's window minus a reply margin so the
        # small-context server never 400s on overflow (founder bug, 2026-11-02).
        token_budget = max(
            0,
            CONFIG.open_weights_max_context_tokens
            - CONFIG.open_weights_response_token_margin,
        )
        return _build_context_capped_open_weights_llm(
            model=model,
            base_url=base_url,
            api_key=api_key,
            token_budget=token_budget,
        )
    from livekit.agents import inference

    return inference.LLM(model=model)


def _provider_of(model_id: str) -> str:
    """``"cartesia/sonic-3"`` -> ``"cartesia"``; bare model -> ``""``."""
    return model_id.split("/", 1)[0] if "/" in model_id else ""


def _build_cartesia_stt(stt_id: str, language: str | None):
    """A grant-funded Cartesia Ink STT leg for a ``cartesia/*`` ``stt_id``,
    or ``None`` when inert — the id is not a Cartesia one,
    ``CARTESIA_API_KEY`` is unset, or ``livekit-plugins-cartesia`` is
    absent. ``None`` makes the caller keep the LiveKit Inference
    construction, so selecting Cartesia before the secret exists can never
    take voice down (the ``build_openai_realtime_model`` fail-soft
    pattern). The plugin model is the id's suffix (``ink-2`` primary,
    ``ink-whisper`` wide-language fallback — catalog ids, never
    hardcoded)."""
    if _provider_of(stt_id) != "cartesia":
        return None
    model = stt_id.split("/", 1)[1] if "/" in stt_id else ""
    if not model:
        logger.warning(
            "Cartesia STT id %r carries no model — "
            "using LiveKit Inference instead",
            stt_id,
        )
        return None
    key = os.getenv("CARTESIA_API_KEY", "")
    if not key:
        logger.warning(
            "Cartesia STT is selected but CARTESIA_API_KEY is unset — using "
            "LiveKit Inference instead (the founder must add the secret; see "
            "docs/FEATURE_FLAGS.md)"
        )
        return None
    try:
        from livekit.plugins import cartesia
    except ImportError:
        # ImportError (not just ModuleNotFoundError) so any plugin-import
        # failure — missing dep, broken install — fails soft, never the
        # call.
        logger.warning(
            "livekit-plugins-cartesia is required for the Cartesia STT "
            "leg — using LiveKit Inference instead"
        )
        return None
    kwargs: dict[str, object] = {"model": model, "api_key": key}
    if language:
        kwargs["language"] = language
    return cartesia.STT(**kwargs)


def _build_cartesia_tts(tts_id: str, voice: str, language: str | None):
    """A grant-funded Cartesia Sonic TTS leg for a ``cartesia/*`` ``tts_id``,
    or ``None`` when inert (same fail-soft contract as
    :func:`_build_cartesia_stt`). The plugin model is the PINNED flagship
    (``CONFIG.cartesia_tts_model``) — the catalog id stays
    ``cartesia/sonic-3``. ``voice`` is already validated for the provider
    (``voice_catalog.safe_tts_voice``); empty means the vendor default and
    is left unset so the plugin uses its own."""
    if _provider_of(tts_id) != "cartesia":
        return None
    key = os.getenv("CARTESIA_API_KEY", "")
    if not key:
        logger.warning(
            "Cartesia TTS is selected but CARTESIA_API_KEY is unset — using "
            "LiveKit Inference instead (the founder must add the secret; see "
            "docs/FEATURE_FLAGS.md)"
        )
        return None
    try:
        from livekit.plugins import cartesia
    except ImportError:
        # Same fail-soft widening as the STT leg above.
        logger.warning(
            "livekit-plugins-cartesia is required for the Cartesia TTS "
            "leg — using LiveKit Inference instead"
        )
        return None
    kwargs: dict[str, object] = {
        "model": CONFIG.cartesia_tts_model, "api_key": key,
    }
    if voice:
        kwargs["voice"] = voice
    if language:
        kwargs["language"] = language
    return cartesia.TTS(**kwargs)


def build_cascade_session(
    brain_id: str,
    stt_id: str,
    tts_id: str,
    tts_voice: str | None = None,
    voice_language: str | None = None,
) -> AgentSession:
    """A LiveKit pipeline (cascade) ``AgentSession`` — STT + brain(LLM) + TTS +
    VAD — with each component independently selected (§13.9), instead of a single
    speech-to-speech ``RealtimeModel``:

    * **STT** — ``stt_id`` through the LiveKit Inference gateway
      (``inference.STT``), LiveKit-credit covered. ``voice_language`` biases its
      language when given. A ``cartesia/*`` id rides the grant-funded plugin
      (``cartesia.STT``) when ``CARTESIA_API_KEY`` is present, else the same
      Inference construction.
    * **brain (LLM)** — :func:`_build_cascade_brain` for ``brain_id``.
    * **TTS** — ``tts_id`` through the same gateway (``inference.TTS``);
      ``tts_voice`` (else ``CONFIG.meta_cascade_tts_voice``, else the vendor
      default) picks the voice. A ``cartesia/*`` id rides the grant-funded
      plugin (``cartesia.TTS`` with the pinned ``CONFIG.cartesia_tts_model``)
      when the key is present, else the same Inference construction.
    * **VAD** — bundled Silero (``inference.VAD``), local turn segmentation (the
      cascade has no server-side turn detection).

    Raises ``RuntimeError`` (missing key/plugin/model) so the caller falls back
    to Gemini Live. Model ids come from the catalog/config, never hardcoded."""
    import voice_catalog

    # Brain first: its key/plugin checks fail fast (before any Inference call),
    # so an unavailable brain cleanly falls the caller back to Gemini Live.
    brain = _build_cascade_brain(brain_id)
    from livekit.agents import inference

    stt_kwargs: dict[str, object] = {"model": stt_id}
    stt_language: str | None = None
    if voice_language:
        lang = voices.bcp47_hint(voice_language)
        if lang:
            # Inference STT language is the primary subtag (e.g. "en"), not a
            # full BCP-47 region tag.
            stt_language = lang.split("-")[0]
            stt_kwargs["language"] = stt_language
    cartesia_stt = _build_cartesia_stt(stt_id, stt_language)
    if cartesia_stt is not None:
        stt = cartesia_stt
    else:
        stt = inference.STT(**stt_kwargs)
    tts_kwargs: dict[str, object] = {"model": tts_id}
    requested_tts_voice = (tts_voice or "").strip() or CONFIG.meta_cascade_tts_voice
    # The voice must be VALID for the active TTS provider. A cross-provider id
    # (e.g. the configured Fish Audio default carried onto an Inworld TTS by a
    # model-only deploy override) makes the gateway raise an unknown-voice
    # APIError and the call goes silent — so drop an unknown id to the vendor
    # default here (``voice_catalog.safe_tts_voice``) instead of handing it over.
    chosen_tts_voice = voice_catalog.safe_tts_voice(tts_id, requested_tts_voice)
    if requested_tts_voice and chosen_tts_voice != requested_tts_voice:
        logger.warning(
            "cascade TTS voice %r is not a valid voice for %s — using the vendor "
            "default instead (an invalid id would raise an unknown-voice error "
            "and leave the call silent)",
            requested_tts_voice, tts_id,
        )
    cartesia_tts = _build_cartesia_tts(tts_id, chosen_tts_voice, stt_language)
    if cartesia_tts is not None:
        tts = cartesia_tts
    else:
        if chosen_tts_voice:
            tts_kwargs["voice"] = chosen_tts_voice
        tts = inference.TTS(**tts_kwargs)
    vad = inference.VAD(model=CONFIG.meta_cascade_vad_model)
    session_kwargs: dict[str, object] = {
        "stt": stt,
        "llm": brain,
        "tts": tts,
        "vad": vad,
        "allow_interruptions": True,
    }
    # Open-weights brain only (§13.9): its LLM leg is a self-hosted, scale-to-zero
    # Modal endpoint whose cold start is ~100s. The AgentSession default LLM conn
    # options (timeout=10s × 4 attempts) can never survive that — every turn
    # times out and the call never replies (founder bug, 2026-11-02). Widen ONLY
    # this leg's timeout to cover the cold start and drop the wasteful fast-retry
    # churn against a cold endpoint; fire a warm-up ping now so the cold start is
    # already underway by the first turn. The Meta/Inference legs are untouched.
    route_model = voice_catalog.brain_route(brain_id)
    if route_model is not None and route_model[0] == voice_catalog.ROUTE_OPEN_WEIGHTS:
        from livekit.agents.types import APIConnectOptions
        from livekit.agents.voice.agent_session import SessionConnectOptions

        session_kwargs["conn_options"] = SessionConnectOptions(
            llm_conn_options=APIConnectOptions(
                timeout=CONFIG.open_weights_cold_start_timeout_s,
                max_retry=1,
                retry_interval=2.0,
            ),
        )
        _warm_open_weights_endpoint()
    return AgentSession(**session_kwargs)


def _voice_isolation_filter(provider: str | None = None):
    """Build the agent-side voice-isolation filter for a voice session.

    Founder rule (2026-11-06): where the selected stack supports LiveKit
    voice isolation and the LiveKit plan covers it, isolation is ON by
    default — the funded project is on Scale, whose included
    voice-isolation minutes cover Krisp VIVA and ai-coustics QUAIL_VF
    (verified 2026-11-06). ``CONFIG.voice_isolation`` picks the provider
    (``krisp`` / ``aicoustics``) or turns it ``off``; the user's model
    choice is never restricted by this. Applied ONLY here, in the agent
    (``RoomInputOptions.noise_cancellation`` on the user's inbound audio,
    before VAD/STT/turn detection) — never stacked with a frontend
    enhanced filter: the app client uses standard WebRTC capture only.

    Fail-open: a missing plugin or construction error logs loudly and
    returns None (plain audio) rather than killing the call.
    """
    provider = (
        provider if provider is not None else CONFIG.voice_isolation
    ).strip().lower()
    if provider == "off":
        return None
    try:
        if provider == "krisp":
            from livekit.plugins import krisp

            return krisp.voice_isolation()
        if provider == "aicoustics":
            from livekit.plugins import ai_coustics

            return ai_coustics.audio_enhancement(
                model=ai_coustics.EnhancerModel.QUAIL_VF_S
            )
    except Exception:
        logger.exception(
            "voice isolation filter unavailable (provider=%s); "
            "continuing without it",
            provider,
        )
    return None


def _room_input_options(video_enabled: bool = False) -> RoomInputOptions:
    """Room input options for a voice session: the user's inbound audio
    runs through the voice-isolation filter (when enabled) before it
    reaches VAD, STT, turn detection, or a realtime model. The two main
    session starts also pass video_enabled=True (feedback item 13) so
    the user's camera / screen tracks flow to the realtime model."""
    return RoomInputOptions(
        video_enabled=video_enabled,
        noise_cancellation=_voice_isolation_filter(),
    )


def build_meta_cascade_session(
    voice_name: str | None = None,
    voice_language: str | None = None,
    tts_voice: str | None = None,
) -> AgentSession:
    """The default Meta cascade (Deliverable A / Practice Date voice): Muse Spark
    brain + ``CONFIG.meta_cascade_stt_model`` STT + ``CONFIG.meta_cascade_tts_model``
    TTS. A thin wrapper over :func:`build_cascade_session` kept for the practice
    path; the voice-engine picker calls ``build_cascade_session`` directly with
    per-user component ids. ``voice_name`` (a Gemini preset) is unused here."""
    import voice_catalog

    return build_cascade_session(
        voice_catalog.BRAIN_META,
        CONFIG.meta_cascade_stt_model,
        CONFIG.meta_cascade_tts_model,
        tts_voice,
        voice_language,
    )


def build_openai_realtime_model(voice: str | None = None):
    """OpenAI Realtime speech-to-speech model for REALTIME mode (§13.9), or
    ``None`` when inert — the flag ``voice_openai_realtime_enabled`` is off, the
    ``OPENAI_API_KEY`` secret is missing, or ``livekit-plugins-openai`` is
    absent. ``None`` makes the caller fall back to Gemini Live, so selecting
    OpenAI Realtime before the secret exists can never take the main voice down.
    The model id is ``CONFIG.openai_realtime_model`` (config, per AGENTS.md)."""
    if not CONFIG.voice_openai_realtime_enabled:
        return None
    key = os.getenv("OPENAI_API_KEY", "")
    if not key:
        logger.warning(
            "OpenAI Realtime is enabled but OPENAI_API_KEY is unset — the "
            "founder must add the secret (see docs/FEATURE_FLAGS.md)"
        )
        return None
    try:
        from livekit.plugins import openai as lk_openai
    except ModuleNotFoundError:  # pragma: no cover - dep in requirements
        logger.warning("livekit-plugins-openai is required for OpenAI Realtime")
        return None
    kwargs: dict[str, object] = {"model": CONFIG.openai_realtime_model, "api_key": key}
    v = (voice or "").strip()
    if v:
        kwargs["voice"] = v
    return lk_openai.realtime.RealtimeModel(**kwargs)


def relay_cascade_usage(
    session: AgentSession,
    uid: str,
    *,
    session_id: str = "",
    model: str = "",
    on_credits_exhausted: Callable[[], Awaitable[None]] | None = None,
) -> None:
    """Meter the Meta voice cascade's LLM turns against the user's token ledger.

    A cascade emits per-component ``LLMMetrics`` / ``STTMetrics`` / ``TTSMetrics``
    rather than the single ``RealtimeModelMetrics`` a Gemini Live session emits
    (which :func:`relay_token_usage` records), so the lifetime credit cap would
    otherwise never see a Meta-cascade call. This records the Muse Spark LLM
    tokens under ``FEATURE_VOICE`` so the cap stays honest. Best-effort — a
    failed write never affects the call. (Real-dollar pricing for the Meta model
    is a separate Deliverable-A gap; tokens still drive the cap regardless.)

    ``on_credits_exhausted``, when given (the MAIN voice cascade passes it;
    Practice leaves it unset), mirrors :func:`relay_token_usage`'s §F3 mid-call
    credit-cap stop: right after each turn's usage is recorded, re-read the live
    balance via ``token_ledger.check`` and fire the callback once the moment it
    comes back exhausted, so a cascade call can no longer run unbounded past
    zero."""
    if not uid:
        return
    from livekit.agents.metrics import LLMMetrics

    # Guards the callback to fire at most once (see relay_token_usage).
    cap_triggered = {"done": False}

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
            "cascade-usage uid=%s session=%s model=%s in=%d out=%d total=%d",
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

        if on_credits_exhausted is None or cap_triggered["done"]:
            return
        try:
            token_ledger.check(uid)
        except token_ledger.TokenCapExceeded:
            cap_triggered["done"] = True
            asyncio.create_task(on_credits_exhausted())
        except Exception:  # noqa: BLE001 - a failed check must not kill the call
            logger.exception("mid-call credit check failed for %s", uid)


def _publish_transcript(
    ctx: JobContext, topic: str, text: str, is_final: bool
) -> None:
    """Fire-and-forget a transcript segment onto the room data channel."""
    text = text.strip()
    if not text:
        return
    payload = json.dumps({"text": text, "is_final": is_final}).encode()

    async def _send() -> None:
        try:
            await ctx.room.local_participant.publish_data(
                payload, reliable=True, topic=topic
            )
        except Exception:  # noqa: BLE001 - a dropped segment must not kill the call
            logger.exception("failed to publish %s segment", topic)

    asyncio.create_task(_send())


def _publish_tool_event(
    ctx: JobContext, phase: str, name: str, label: str | None = None
) -> None:
    """Fire-and-forget a ``tool_used`` event onto the room data channel — the
    voice equivalent of the text chat's status -> reply kicker (gemini.py).
    ``phase`` is ``"start"`` (live, present-progressive label) or ``"end"``
    (persistent, past-tense label) so the client can swap one for the other,
    matching ``generate_reply_events``'s status -> reply pattern. ``label``
    (end only) is the outcome label when the tool's chip depends on what it
    did (``tool_labels.outcome_label``)."""
    if phase == "start":
        label = _working_label(name)
    elif label == _NO_CHIP:
        # The tool ran but did not do the visible thing its chip would claim
        # (e.g. the app never navigated). An empty end-label clears the live
        # "…ing" indicator on the client and queues no settled chip.
        label = ""
    else:
        label = label or _tool_label(name)
    payload = json.dumps({"name": name, "label": label, "phase": phase}).encode()

    async def _send() -> None:
        try:
            await ctx.room.local_participant.publish_data(
                payload, reliable=True, topic=TOPIC_TOOL_USED
            )
        except Exception:  # noqa: BLE001 - a dropped event must not kill the call
            logger.exception("failed to publish tool_used event for %s", name)

    asyncio.create_task(_send())


async def _publish_call_ending(ctx: JobContext, reason: str) -> None:
    """Tell the client *why* the room is about to close (§F3) — awaited
    directly, not fire-and-forget, so the signal is sent (best-effort) before
    the caller goes on to actually end the session. A dropped delivery still
    must not block the shutdown it's warning about."""
    payload = json.dumps({"reason": reason}).encode()
    try:
        await ctx.room.local_participant.publish_data(
            payload, reliable=True, topic=TOPIC_CALL_ENDING
        )
    except Exception:  # noqa: BLE001 - the call must still end
        logger.exception("failed to publish call_ending (%s)", reason)


async def _publish_voice_status(ctx: JobContext, state: str) -> None:
    """Tell the client an honest, voice-stack-specific status (§13.9) — used so
    far only for the open-weights cold start (``open_weights_warming``), so the
    UI shows "warming up, first reply can take a minute or two" instead of a
    silent "Listening…". Awaited best-effort; a dropped signal never affects the
    call."""
    payload = json.dumps({"state": state}).encode()
    try:
        await ctx.room.local_participant.publish_data(
            payload, reliable=True, topic=TOPIC_VOICE_STATUS
        )
    except Exception:  # noqa: BLE001 - a dropped status must not kill the call
        logger.exception("failed to publish voice_status (%s)", state)


async def _publish_vision_state(ctx: JobContext, state: str) -> None:
    """Tell the client the state of the frames arriving from the user's
    video / screen share (see [TOPIC_VISION_STATE]). Best-effort like
    [_publish_voice_status]: a dropped signal never affects the call."""
    payload = json.dumps({"state": state}).encode()
    try:
        await ctx.room.local_participant.publish_data(
            payload, reliable=True, topic=TOPIC_VISION_STATE
        )
    except Exception:  # noqa: BLE001 - a dropped signal must not kill the call
        logger.exception("failed to publish vision_state (%s)", state)


def vision_frame_is_black(rgb: bytes) -> bool:
    """True when a raw RGB24 frame is (near-)pure black — how a FLAG_SECURE
    surface arrives through a screen share. The mean over all channel bytes
    approximates mean luminance closely enough at the black end, where the
    secure-content decision lives (see [VISION_BLACK_LUMINANCE_MAX]). An
    empty frame is not evidence of anything and reads as not black."""
    if not rgb:
        return False
    return (sum(rgb) / len(rgb)) <= VISION_BLACK_LUMINANCE_MAX


def watch_vision_tracks(ctx: JobContext, *, vision_supported: bool) -> None:
    """Sample the user's published video tracks during a main Ayma call and
    report FLAG_SECURE black frames to the client (feedback item 13).

    One sampler per subscribed remote video track (camera or screen share —
    the check is identical): frames are pulled as RGB24 at the stream's own
    pace and luminance-checked at most once a second. A black frame flips
    the share to `secure_content` (the client shows the honest notice; the
    model itself only receives black, and [VISION_INSTRUCTIONS] tells Ayma
    to say she cannot see protected content rather than guess); the first
    real frame after that flips it back to `frames_flowing`. Nothing is
    recorded or persisted — frames are inspected in memory and dropped.

    The watcher also answers the client's `vision_query` on the vision-
    control topic by re-publishing this session's capability declaration
    ([vision_supported] — the same verdict the starter published at
    session start): the one-shot publish can race the client's listener
    registration, and a missed declaration must not leave the toggles in
    their fallback state for the whole call.
    """
    from livekit import rtc

    samplers: dict[str, asyncio.Task] = {}
    secure = {"active": False}

    async def _sample(track: rtc.Track) -> None:
        stream = rtc.VideoStream(track, format=rtc.VideoBufferType.RGB24)
        last_check = 0.0
        try:
            async for event in stream:
                now = asyncio.get_running_loop().time()
                if now - last_check < 1.0:
                    continue
                last_check = now
                black = vision_frame_is_black(bytes(event.frame.data))
                if black and not secure["active"]:
                    secure["active"] = True
                    await _publish_vision_state(ctx, VISION_STATE_SECURE_CONTENT)
                elif not black and secure["active"]:
                    secure["active"] = False
                    await _publish_vision_state(ctx, VISION_STATE_FRAMES_FLOWING)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - a sampler must never kill the call
            logger.exception("vision track sampler failed")
        finally:
            await stream.aclose()

    def _on_track_subscribed(
        track: rtc.Track,
        publication: rtc.RemoteTrackPublication,
        participant: rtc.RemoteParticipant,
    ) -> None:
        if track.kind != rtc.TrackKind.KIND_VIDEO:
            return
        if publication.sid in samplers:
            return
        samplers[publication.sid] = asyncio.create_task(_sample(track))

    def _on_track_unsubscribed(
        track: rtc.Track,
        publication: rtc.RemoteTrackPublication,
        participant: rtc.RemoteParticipant,
    ) -> None:
        task = samplers.pop(publication.sid, None)
        if task is not None:
            task.cancel()
        # The share ended: no stale secure-content state survives it.
        if secure["active"] and not samplers:
            secure["active"] = False
            asyncio.create_task(
                _publish_vision_state(ctx, VISION_STATE_FRAMES_FLOWING)
            )

    def _on_data(packet) -> None:  # noqa: ANN001 - rtc.DataPacket
        if getattr(packet, "topic", None) != TOPIC_VISION_CONTROL:
            return
        try:
            payload = json.loads(bytes(packet.data).decode("utf-8"))
        except Exception:  # noqa: BLE001 - a malformed control is dropped
            return
        if not isinstance(payload, dict):
            return
        if payload.get("type") == "vision_query":
            asyncio.create_task(
                _publish_voice_status(
                    ctx,
                    VOICE_STATUS_VISION_SUPPORTED
                    if vision_supported
                    else VOICE_STATUS_VISION_UNSUPPORTED,
                )
            )
            return
        logger.info(
            "vision_control: source=%s active=%s",
            payload.get("source"),
            payload.get("active"),
        )
        if payload.get("active") is False and secure["active"]:
            secure["active"] = False
            asyncio.create_task(
                _publish_vision_state(ctx, VISION_STATE_FRAMES_FLOWING)
            )

    ctx.room.on("track_subscribed", _on_track_subscribed)
    ctx.room.on("track_unsubscribed", _on_track_unsubscribed)
    ctx.room.on("data_received", _on_data)


def _warm_open_weights_endpoint() -> None:
    """Kick the open-weights (self-hosted Modal) endpoint awake at session setup
    so its ~100s scale-to-zero cold start begins now — in parallel with STT/room
    setup — instead of on the first user turn (founder bug, 2026-11-02: a cold
    Modal + the 10s default LLM timeout meant the call never replied). A tiny,
    fire-and-forget ``GET /models`` ping is enough to start the container.
    Best-effort: a failed or slow warm-up never affects the call, and nothing
    keeps Modal warm persistently (``$100`` credit — warm-on-use only)."""
    base_url = CONFIG.open_weights_api_base_url
    if not base_url:
        return

    async def _ping() -> None:
        try:
            import httpx

            headers: dict[str, str] = {}
            key = os.getenv("OPEN_WEIGHTS_API_KEY", "")
            if key:
                headers["Authorization"] = f"Bearer {key}"
            timeout = CONFIG.open_weights_cold_start_timeout_s
            async with httpx.AsyncClient(timeout=timeout) as client:
                await client.get(f"{base_url}/models", headers=headers)
            logger.info("open-weights warm-up ping completed")
        except Exception:  # noqa: BLE001 - warm-up is best-effort
            logger.info("open-weights warm-up ping failed (non-fatal)", exc_info=True)

    try:
        asyncio.get_running_loop()
    except RuntimeError:
        # No running loop (a sync/unit-test context) — skip the warm-up task.
        return
    asyncio.create_task(_ping())


class SessionFlush:
    """Exactly-once guard around :func:`post_turn.persist_and_ingest` for one
    voice session (§1.7 step 8, §F3). Shared between two call sites: the
    normal ``ctx.add_shutdown_callback`` path (every ordinary disconnect —
    clean hang-up, dropped network, app backgrounded/killed) and an explicit
    call from :func:`end_call_out_of_credits` (so the memory write lands
    *before* Ayma's spoken goodbye, not just afterwards as a side effect of
    shutdown — founder ask, 2026-09-21). Without this guard a graceful
    out-of-credits stop would call ``persist_and_ingest`` twice — once
    explicitly, once again when its own ``ctx.shutdown()`` runs the shutdown
    callback — double-spending real Gemini tokens on the exact same
    wiki-ingest content for no benefit (``wiki_ingest.ingest_or_defer`` is a
    fresh LLM call each time, not a no-op replay)."""

    def __init__(
        self,
        db,
        uid: str,
        session_id: str,
        window: list[Turn],
        seeded_turn_count: int = 0,
        voice_provider: str | None = None,
    ) -> None:
        self._voice_provider = voice_provider
        self._db = db
        self._uid = uid
        self._session_id = session_id
        self._window = window
        # How many turns `window` already held at seed time (from
        # `/bootstrap`'s `recent_turns`, already-persisted history) — used to
        # tell "nothing was actually said in this room" apart from "this room
        # happens to have history". See `_has_new_turns`.
        self._seeded_turn_count = seeded_turn_count
        self.done = False
        self._task: asyncio.Task[None] | None = None

    def start(self) -> None:
        """Begin the flush in the background without waiting for it — called
        the moment the AgentSession closes (caller hung up, dropped, or the
        app ended the call), so the work overlaps LiveKit's ~20 s room
        departure wait instead of starting only when the job's shutdown
        callbacks run against ``shutdown_process_timeout``. Production logs
        (2026-10-25) showed the process killed mid-flush on that deadline."""
        if self._task is None and self._should_flush():
            self.done = True
            self._task = asyncio.create_task(self._flush())

    async def run(self) -> None:
        """Run the flush once and wait for it. Every caller — the
        session-close trigger, an explicit idle/out-of-credits stop, the
        shutdown callback — awaits the same in-flight task, so the shutdown
        callback can never return (and let the process exit) while an
        earlier-started flush is still writing."""
        self.start()
        if self._task is not None:
            await asyncio.shield(self._task)

    async def _flush(self) -> None:
        started = time.monotonic()
        logger.info(
            "session-flush start uid=%s session=%s turns=%d",
            self._uid, self._session_id, len(self._window),
        )
        try:
            await persist_and_ingest(
                self._db, self._uid, self._session_id, list(self._window),
                voice_provider=self._voice_provider,
            )
        except Exception:  # noqa: BLE001 - shutdown must still complete
            logger.exception(
                "session flush failed for %s/%s", self._uid, self._session_id
            )
        logger.info(
            "session-flush end uid=%s session=%s duration_ms=%d",
            self._uid, self._session_id,
            int((time.monotonic() - started) * 1000),
        )

    def _should_flush(self) -> bool:
        if not self._uid or not self._session_id or not self._window:
            return False
        if not _has_new_turns(self._window, self._seeded_turn_count):
            # A common shape for a client that never finished connecting
            # (e.g. the WebRTC/ICE handshake timing out, or the caller
            # retrying after an earlier failed attempt) rather than a real,
            # if short, conversation. `window` still holds whatever
            # `/bootstrap` seeded it with (already-persisted history from a
            # prior session), so without this guard every such abandoned job
            # would re-run `persist_and_ingest` on shutdown against turns
            # that were ingested once already: a wasted Gemini call charged
            # to the user's token ledger for zero new information, on every
            # single failed/retried voice-connect attempt.
            return False
        return True


async def end_call_out_of_credits(
    ctx: JobContext,
    session: AgentSession,
    uid: str,
    flush: Callable[[], Awaitable[None]],
) -> None:
    """§F3 graceful mid-call credit-cap stop (founder ask, 2026-09-21): never
    an abrupt cutoff. Sequence: flush the session's memory write first
    (``flush`` — so the turn that just tipped the balance to zero is never
    lost, same guarantee every other disconnect path already gets), have Ayma
    speak a short in-character goodbye and let it finish playing, tell the
    client why right as we're about to disconnect, THEN end the job —
    ``ctx.shutdown()`` still runs the normal shutdown-callback chain (which
    also calls ``flush``), so a :class:`SessionFlush`-backed ``flush`` makes
    that second call a no-op rather than a wasteful repeat ingest."""
    logger.info("voice out-of-credits stop for %s", uid)
    try:
        await flush()
    except Exception:  # noqa: BLE001 - the call must still end
        logger.exception("out-of-credits memory flush failed for %s", uid)
    try:
        handle = session.generate_reply(
            instructions=_OUT_OF_CREDITS_INSTRUCTIONS,
            allow_interruptions=False,
        )
        await asyncio.wait_for(
            handle, timeout=_OUT_OF_CREDITS_GOODBYE_TIMEOUT_SECONDS
        )
    except Exception:  # noqa: BLE001 - the goodbye line is best-effort
        logger.exception("out-of-credits goodbye failed for %s", uid)
    # Sent last, right before disconnect: tells the client this was a
    # deliberate credit-cap stop (so it shows the "reload" affordance) rather
    # than a dropped connection, without flipping the UI out of "live call"
    # while Ayma's goodbye line above was still playing.
    await _publish_call_ending(ctx, "out_of_credits")
    ctx.shutdown(reason="out_of_credits")


async def end_call_idle(
    ctx: JobContext, uid: str, flush: Callable[[], Awaitable[None]]
) -> None:
    """Inactivity stop: nobody has spoken (and Ayma has said nothing) for
    ``CONFIG.voice_idle_timeout_seconds``, so end the call to stop billing
    LiveKit participant-minutes. Same shape as :func:`end_call_out_of_credits`
    minus the spoken goodbye: flush the memory write, tell the client why,
    delete the room (disconnects the user participant) and shut the job down
    (shutdown callbacks log the token-ledger totals)."""
    logger.info("voice idle-timeout stop for %s", uid)
    try:
        await flush()
    except Exception:  # noqa: BLE001 - the call must still end
        logger.exception("idle-timeout memory flush failed for %s", uid)
    await _publish_call_ending(ctx, REASON_IDLE_TIMEOUT)
    try:
        await ctx.delete_room()
    except Exception:  # noqa: BLE001 - shutdown below still drops the agent
        logger.exception("idle-timeout room delete failed for %s", uid)
    ctx.shutdown(reason=REASON_IDLE_TIMEOUT)


async def end_call_goodbye(
    ctx: JobContext, uid: str, flush: Callable[[], Awaitable[None]]
) -> None:
    """User-hang-up stop: the caller signed off ("goodbye Ayma", interpreted
    by the voice-actions skill — see :func:`relay_voice_commands`), so end
    the call exactly the honest way :func:`end_call_idle` does: flush the
    memory write, tell the client why, delete the room (disconnects the user
    participant) and shut the job down (shutdown callbacks log the
    token-ledger totals). No spoken sign-off — the model's own "bye!" may or
    may not beat the disconnect; either way the call ends cleanly."""
    logger.info("voice user-goodbye stop for %s", uid)
    try:
        await flush()
    except Exception:  # noqa: BLE001 - the call must still end
        logger.exception("user-goodbye memory flush failed for %s", uid)
    await _publish_call_ending(ctx, REASON_USER_GOODBYE)
    try:
        await ctx.delete_room()
    except Exception:  # noqa: BLE001 - shutdown below still drops the agent
        logger.exception("user-goodbye room delete failed for %s", uid)
    ctx.shutdown(reason=REASON_USER_GOODBYE)


def watch_for_idle(
    ctx: JobContext,
    session: AgentSession,
    uid: str,
    flush: Callable[[], Awaitable[None]],
    timeout_seconds: float | None = None,
    start_now: bool = True,
) -> IdleWatchdog | None:
    """Start the inactivity watchdog for this session (see
    :class:`idle_watchdog.IdleWatchdog`). Activity = user speech (any
    transcript or speaking state), the agent speaking or thinking, a tool call
    (via the returned watchdog's ``touch``), or a data message from the user.
    "Shut up" muting is not activity, so a muted forgotten call still times
    out. Returns None when the timeout is disabled.
    
    ``start_now=False`` registers handlers but defers starting the timer until
    you call ``watchdog.start()`` later (used to avoid measurement lag where
    the timer counts down during session setup)."""
    timeout = (
        CONFIG.voice_idle_timeout_seconds
        if timeout_seconds is None
        else timeout_seconds
    )
    if timeout <= 0:
        return None
    watchdog = IdleWatchdog(timeout, lambda: end_call_idle(ctx, uid, flush))

    @session.on("user_input_transcribed")
    def _on_user_input(ev) -> None:  # noqa: ANN001 - UserInputTranscribedEvent
        watchdog.touch()

    @session.on("user_state_changed")
    def _on_user_state(ev) -> None:  # noqa: ANN001 - UserStateChangedEvent
        watchdog.touch()

    @session.on("agent_state_changed")
    def _on_agent_state(ev: AgentStateChangedEvent) -> None:
        watchdog.set_agent_state(ev.new_state)

    ctx.room.on("data_received", lambda _packet: watchdog.touch())

    async def _stop() -> None:
        watchdog.stop()

    ctx.add_shutdown_callback(_stop)
    
    if start_now:
        watchdog.start()
    
    return watchdog


# Registered tool/function names (§13.6) — used only to recognise a leaked
# tool-call artifact in _strip_leaked_tool_artifact below, never to run them.
def _known_tool_names() -> frozenset[str]:
    from skills import app_control, recall

    return frozenset(
        {s.name for s in skills.all_skills()}
        | {s.name for s in app_control.VOICE_SKILLS}
        # The flag-gated recall tool (context_opt Phase 3) is recognised
        # unconditionally: a leaked "recall{...}" artifact must be stripped
        # even right after the flag is flipped off mid-fleet.
        | {recall.SKILL.name}
    )


# Matches one glued, snake_case-shaped "word" (no whitespace) at the very
# start of a string, at least this long — real spoken English never opens
# with an unbroken run this long.
_LEADING_GLUED_TOKEN_RE = re.compile(r"^[a-z][a-z0-9_]{17,}(?=[\s]|$)")

# A second leaked-artifact shape: Gemini Live narrating its own structured
# function-call/response instead of speaking plain text (a real example:
# "response:set_voice_preference{output:saved default voice:Ah, okay! My
# ears are playing tricks on me..." — Ayma's real reply starts right at
# "Ah,"). Unlike the glued-word case above, this one is punctuated with the
# response's own ":"/"{"/"}" syntax rather than being one unbroken word, so
# it needs its own pattern: everything up to a ":" that's immediately
# followed by a capital letter — no space between them, which real written/
# spoken sentences never do ("thing: Value" always has a space after the
# colon; only this artifact's compressed key:value narration doesn't).
# Bounded to a short prefix and barred from containing sentence-ending
# punctuation so it can never eat into a genuine reply that happens to
# contain a colon.
_LEADING_STRUCTURED_ARTIFACT_RE = re.compile(r"^([^.!?\n]{1,120}?):(?=[A-Z])")


def _strip_leaked_tool_artifact(text: str) -> str:
    """Defensive filter for a leaked tool-call artifact seen at the very start
    of Gemini Live's own ``output_transcription`` — the audio track it
    describes is what the model actually spoke, so this is a defect in the
    upstream model/transcription pipeline we cannot prevent upstream. Two
    known shapes, both requiring shape + evidence (a real registered tool
    name inside the matched prefix) so genuine spoken text — never glued,
    never containing a raw tool identifier — is never touched:

    1. A glued snake_case run, e.g. ``"activalerts_read_dm_threadactivation
       speech Ah, you know, my voice is more for talking..."`` — the glued
       run contains ``read_dm_thread`` verbatim.
    2. A structured "key:value" narration, e.g. ``"response:set_voice_
       preference{output:saved default voice:Ah, okay!..."`` — see
       :data:`_LEADING_STRUCTURED_ARTIFACT_RE`.
    """
    stripped = text.lstrip()
    match = _LEADING_GLUED_TOKEN_RE.match(stripped)
    if match:
        leaked = match.group(0)
        if any(name in leaked for name in _known_tool_names()):
            return stripped[match.end():].lstrip()
    match = _LEADING_STRUCTURED_ARTIFACT_RE.match(stripped)
    if match:
        leaked = match.group(1)
        if any(name in leaked for name in _known_tool_names()):
            return stripped[match.end():].lstrip()
    return text


class TourNarrationGate:
    """Per-voice-session latch marking that the NEXT assistant turn is Ayma-DRIVEN
    tour narration (§11.2b) — ephemeral step guidance that must NOT be relayed to
    the client transcript nor recorded in the ``raw_turns`` window, so it never
    persists as a chat turn (founder/Scout, 2026-11-03). Set when a guided-tour
    tool runs (``_session_tools`` ``_on_call``), consumed by the next assistant
    ``conversation_item_added`` (``relay_transcripts`` ``_on_item``), and reset on
    a new user turn so a tool that produced no narration can't leak the latch
    forward. One gate is created per call build and passed to both."""

    def __init__(self) -> None:
        self.pending = False


def relay_transcripts(
    ctx: JobContext,
    session: AgentSession,
    collector: list[Turn] | None = None,
    tour_gate: "TourNarrationGate | None" = None,
) -> None:
    """Relay Gemini Live's native transcription to the client as
    ``user_transcript`` / ``agent_transcript`` data-channel events (§1.6), and
    (when ``collector`` is given) record each finalized turn for the session's
    ``raw_turns`` persistence on shutdown (§1.7 step 8).

    The framework's built-in transcription forwarding is turned off in
    ``session.start`` so the client has exactly one delivery path to parse
    (§1.7 step 12). ``conversation_item_added`` text passes through
    :func:`_strip_leaked_tool_artifact` first — see that function's docstring
    — so a leaked artifact never reaches the client transcript nor
    ``raw_turns`` (which would otherwise reseed a future session's context via
    ``recent_turns``), even though it can't undo audio already spoken for the
    one turn it happened on.
    """

    @session.on("user_input_transcribed")
    def _on_user(ev: UserInputTranscribedEvent) -> None:
        _publish_transcript(
            ctx, TOPIC_USER_TRANSCRIPT, ev.transcript, ev.is_final
        )
        if ev.is_final and tour_gate is not None:
            # A new user turn: whatever Ayma says next is a fresh reply, not the
            # pending tour narration — reset the latch so it can't leak forward.
            tour_gate.pending = False
        if collector is not None and ev.is_final and ev.transcript.strip():
            collector.append(Turn(ROLE_USER, ev.transcript.strip()))

    @session.on("conversation_item_added")
    def _on_item(ev: ConversationItemAddedEvent) -> None:
        if getattr(ev.item, "role", None) != "assistant":  # handoffs/tool calls have no role
            return
        text = _strip_leaked_tool_artifact(
            (ev.item.text_content or "").strip()
        ).strip()
        if tour_gate is not None and tour_gate.pending:
            # Ayma-driven tour step narration — ephemeral guidance, not a chat
            # turn (§11.2b). Consume the latch and drop it: neither relay it to
            # the client transcript nor record it in the raw_turns window, so it
            # never persists (founder/Scout, 2026-11-03).
            tour_gate.pending = False
            return
        _publish_transcript(ctx, TOPIC_AGENT_TRANSCRIPT, text, True)
        if collector is not None and text:
            collector.append(Turn(ROLE_AYMA, text))


def relay_agent_state(ctx: JobContext, session: AgentSession) -> None:
    """Publish the agent's speaking/listening/thinking state to the client
    (§1.3). This is the authoritative signal for the client's "Ayma is
    speaking" indicator and its barge-in playback stop (§1.7 step 10): when
    Gemini Live's native turn-detection interrupts a reply, the state leaves
    ``speaking`` and the client clears buffered agent audio at once. No custom
    VAD anywhere — interruption is entirely Gemini Live's (§1.7 step 9)."""

    @session.on("agent_state_changed")
    def _on_state(ev: AgentStateChangedEvent) -> None:
        payload = json.dumps({"state": ev.new_state}).encode()

        async def _send() -> None:
            try:
                await ctx.room.local_participant.publish_data(
                    payload, reliable=True, topic=TOPIC_AGENT_STATE
                )
            except Exception:  # noqa: BLE001
                logger.exception("failed to publish agent_state")

        asyncio.create_task(_send())


# --- "shut up" muting (founder request, 2026-09-20) ------------------------
#
# Gemini Live's native/server-side turn detection means the SDK's documented
# no-reply hook — `Agent.on_user_turn_completed` raising `StopResponse` — is
# unreachable for this session and cannot be used here. Verified directly
# against the installed `livekit-agents` source
# (voice/agent_activity.py `_user_turn_completed_task`): for a
# `llm.RealtimeModel` it checks `self._rt_turn_detection_enabled` and
# returns immediately if true, *before* ever calling
# `self._agent.on_user_turn_completed(...)`. `_rt_turn_detection_enabled`
# resolves to `True` for our exact setup (gateway `RealtimeModel`,
# `capabilities.turn_detection=True`,
# `capabilities.can_disable_turn_detection=False`, no client VAD and server
# turn detection left ON) — see
# `AgentActivity._resolve_rt_turn_detection_enabled`. So `StopResponse`
# would simply never fire; it is not used below.
#
# The real, working hook is the `speech_created` session event. When the
# realtime model auto-generates a reply, `AgentActivity._on_generation_created`
# creates the `SpeechHandle` and emits `speech_created` *before* scheduling
# the task that streams audio to the room. Calling `speech_handle.interrupt()`
# synchronously from that event handler marks the handle interrupted before
# its task starts; `_realtime_generation_task_impl` then takes its
# "nothing was played" branch (`if speech_handle.interrupted: ... return`),
# forwards zero audio frames, and calls `RealtimeSession.interrupt()` to
# truncate the still-generating server-side response — the same primitive
# the SDK already uses for ordinary barge-in interruption. No assistant
# `conversation_item_added` fires either, so a suppressed turn never leaks
# into the transcript relay or the `raw_turns` persistence window.
#
# Trigger detection runs off the same `user_input_transcribed` final
# transcript `relay_transcripts` already relays, so the mute state updates
# before the corresponding `speech_created` (the model only starts a reply
# once the user's turn — and its transcription — has closed out).

# Short, imperative "make Ayma stop talking" phrases. Deliberately NOT a
# single word like "quiet" or "enough" (too likely inside an unrelated
# sentence); every entry here is a phrase distinctive enough that it's
# very rarely part of normal conversation. `silence` alone is the one
# genuinely single-word entry — the founder named it explicitly as a
# trigger — so it leans on the word-count cap below to avoid catching an
# unrelated sentence like "there was an awkward silence at dinner."
_MUTE_TRIGGER_RE = re.compile(
    r"\b("
    r"shut up|shush|shh+|hush|zip it|"
    r"be quiet|stay quiet|quiet please|"
    r"stop talking|stop speaking|stop responding|"
    r"go silent|silence"
    r")\b",
    re.IGNORECASE,
)

# Reject a trigger phrase found inside a long, unrelated sentence — e.g.
# "I told him to shut up but he wouldn't listen" recounts someone else's
# words rather than commanding Ayma. A short, imperative-shaped utterance
# is what a real "be quiet" command to Ayma looks like; capping the word
# count is a simple, robust proxy for that without needing real parsing.
_MUTE_TRIGGER_MAX_WORDS = 8


def _is_mute_trigger(text: str) -> bool:
    """True if ``text`` (a finalized user turn) is a short command telling
    Ayma to stop talking. See the block comment above for the reasoning."""
    stripped = text.strip()
    if not stripped or not _MUTE_TRIGGER_RE.search(stripped):
        return False
    return len(stripped.split()) <= _MUTE_TRIGGER_MAX_WORDS


# Any direct mention of "Ayma" while muted is treated as calling her out —
# not requiring vocative/first-word position. Erring broad here (rather than
# requiring "Ayma" to lead the sentence) matches the founder's literal ask
# ("until the user specifically call out Ayma") better than a stricter
# position rule would: real call-outs are often phrased "okay Ayma, you can
# talk now" or "sorry, Ayma, are you there?" with the name mid-sentence. The
# false-positive risk (talking *about* Ayma to someone else, not to her)
# exists but only matters while already muted, where a missed call-out
# (staying silent) is a worse outcome than an extra unmute.
# Gemini Live's input transcription routinely garbles the name (pronounced
# AY-muh), so the matcher also accepts the common near-misses: aima/aimma/
# aymma/aymar/aimar/ayema/ayuma/amya/eyma, split forms ("a ima", "ay ma",
# "hey ima") and the sound-alikes emma/ema/amma. Whole words only, so "aim",
# "image" and "aymara" never match.
_AYMA_CALLOUT_RE = re.compile(
    r"\b(?:"
    r"a[iy]m{1,2}[ae]r?"
    r"|a[iy][eu]m[ae]"
    r"|[ae]ym[ae]"
    r"|amya"
    r"|a\s+ima"
    r"|a[iy]\s+ma"
    r"|ima"
    r"|emma|amma|ema"
    r")\b",
    re.IGNORECASE,
)


def _addresses_ayma(text: str) -> bool:
    """True if ``text`` (a finalized user turn) names Ayma directly."""
    return bool(_AYMA_CALLOUT_RE.search(text.strip()))


@dataclass
class MuteState:
    """Session-scoped "shut up" flag — one per LiveKit room/call, exactly
    like the ``window: list[Turn]`` turn buffer in ``entrypoint`` (§1.7 step
    8): plain in-memory state threaded through via a closure, no Firestore
    persistence. A fresh call is a fresh room/session/``AgentSession``, so
    there's nothing to reset between calls; if a call ends while still
    muted, the flag simply goes away with the session."""

    muted: bool = False


def _publish_mute_state(ctx: JobContext, muted: bool) -> None:
    """Fire-and-forget the current mute flag onto the room data channel."""
    payload = json.dumps({"muted": muted}).encode()

    async def _send() -> None:
        try:
            await ctx.room.local_participant.publish_data(
                payload, reliable=True, topic=TOPIC_AGENT_MUTE
            )
        except Exception:  # noqa: BLE001 - a dropped event must not kill the call
            logger.exception("failed to publish agent_mute")

    asyncio.create_task(_send())


def relay_mute_control(
    session: AgentSession, state: MuteState, ctx: JobContext | None = None
) -> None:
    """Wire the "shut up" mute flow onto ``session`` (see the block comment
    above for why this — not ``on_user_turn_completed``/``StopResponse`` —
    is the real hook):

    * On each finalized user turn: while unmuted, a mute-trigger phrase
      mutes; while muted, a direct "Ayma" call-out unmutes (and that same
      turn is allowed to reply — no ``StopResponse``/skip needed, since it's
      already unmuted by the time ``speech_created`` fires for it).
    * On every ``speech_created`` (an auto-generated reply about to run):
      while muted, interrupt the handle before it plays anything.

    Normal (never-muted) sessions see no behavior change at all — this only
    ever touches replies while ``state.muted`` is true.

    When ``ctx`` is given, every mute transition is also published on the
    ``agent_mute`` topic so the client can show that Ayma is deliberately quiet,
    and the state stays authoritative for the whole call:

    * an ``agent_mute_control`` message ``{"muted": false}`` from the app (the
      user tapped Unmute) unmutes, and the current state is always echoed back;
    * a participant (re)joining the room gets the current state re-published,
      so a reconnect or a fresh client never shows a stale chip.

    The voice hot swap (``VoiceSwapper``) keeps this same ``AgentSession`` and
    ``state``, so a muted call stays muted across it.
    """

    def _set_muted(muted: bool) -> None:
        state.muted = muted
        if ctx is not None:
            _publish_mute_state(ctx, muted)

    if ctx is not None:

        def _on_data(packet) -> None:  # noqa: ANN001 - rtc.DataPacket
            if getattr(packet, "topic", None) != TOPIC_AGENT_MUTE_CONTROL:
                return
            try:
                wanted = json.loads(bytes(packet.data).decode())["muted"]
            except (ValueError, KeyError, TypeError, UnicodeDecodeError):
                logger.warning("malformed agent_mute_control payload dropped")
                return
            if wanted is not False:
                logger.warning("agent_mute_control only accepts muted=false")
            else:
                state.muted = False
            _publish_mute_state(ctx, state.muted)

        ctx.room.on("data_received", _on_data)
        ctx.room.on(
            "participant_connected",
            lambda _p: _publish_mute_state(ctx, state.muted),
        )

    @session.on("user_input_transcribed")
    def _on_user_final(ev: UserInputTranscribedEvent) -> None:
        if not ev.is_final:
            return
        transcript = ev.transcript.strip()
        if not transcript:
            return
        if state.muted:
            if _addresses_ayma(transcript):
                _set_muted(False)
        elif _is_mute_trigger(transcript):
            _set_muted(True)

    @session.on("speech_created")
    def _on_speech_created(ev) -> None:  # noqa: ANN001 - SpeechCreatedEvent
        if state.muted:
            ev.speech_handle.interrupt(force=True)


# --- deterministic pre-model voice commands (text-lane backstop) -----------------
#
# The text lane executes a clear stack-switch / navigation command BEFORE the
# model (main._prepare_chat → detect_stack_command / detect_app_command), so it
# works regardless of which brain is active. Voice had no such backstop — every
# in-call action depended on the realtime model emitting the tool call, which it
# sometimes refuses to do (founder, prod 2284: no Practice Date / Agent Date
# launch, no guided-tour start, no brain or voice switch from the call). The
# matcher below runs the same detection on each finalized user turn in the
# LiveKit agent and executes matches through the session's own tools, so these
# actions fire deterministically in-call exactly as they do in text. A handled
# turn is claimed in the call's VoiceTurnDedupe first, so the model's own
# same-turn call to that tool replays the result instead of executing the side
# effect a second time (the voice counterpart to "a handled text turn never
# reaches the model").
_STACK_TOOL_KWARGS = {
    "set_brain": "brain",
    "set_voice_brain": "brain",
    "set_voice_mode": "mode",
    "set_realtime_model": "model",
    "set_stt": "engine",
    "set_tts": "engine",
}


def detect_voice_command(transcript: str) -> tuple[str, dict] | None:
    """``(tool_name, kwargs)`` for a deterministic voice command, else ``None``.

    Same detection the text lane runs before the model, in the same order
    (stack switch, then navigation, then launch, then guided-tour start) and
    with the same strictness, so ordinary in-call chat is never intercepted.
    The kwargs are the ones the model itself would pass for the match — a
    partner-less launch carries ``{"name": ""}`` and the relay answers it
    with the "who with?" clarification instead of launching."""
    text = (transcript or "").strip()
    if not text:
        return None
    stack_cmd = skills.set_model_stack.detect_stack_command(text)
    if stack_cmd is not None:
        name, value = stack_cmd
        kwarg = _STACK_TOOL_KWARGS.get(name)
        if kwarg is not None:
            return name, {kwarg: value}
        logger.warning("voice command: unknown stack tool %r", name)
    if skills.app_control.detect_go_back_command(text):
        return "go_back", {}
    app_dest = skills.app_control.detect_app_command(text)
    if app_dest is not None:
        return "open_screen", {"screen": app_dest}
    photo_cmd = skills.app_control.detect_photo_command(text)
    if photo_cmd is not None:
        op, index = photo_cmd
        return "show_profile_photo", {"op": op, "index": index or 0}
    launch_cmd = skills.app_control.detect_launch_command(text)
    if launch_cmd is not None:
        name, partner = launch_cmd
        return name, {"name": partner or ""}
    tour_tool = skills.guided_tour.detect_tour_command(text)
    if tour_tool is not None:
        return tour_tool, {}
    return None


def _tools_by_name(tools: list) -> dict:
    """``{tool name: tool}`` for the deterministic dispatcher, keyed by each
    tool's livekit info name (the Skill name it was built from)."""
    by_name = {}
    for tool in tools:
        name = getattr(getattr(tool, "info", None), "name", None)
        if name:
            by_name[name] = tool
    return by_name


# The settled result of a skill-interpreted goodbye turn. No model tool
# awaits it (there is no "end_call" tool); it exists so the claim has a
# value like every other command family's.
_GOODBYE_RESULT = "call ended: the user said goodbye."


# --- ack-gated spoken claims -------------------------------------------------
#
# The app-command tools have always known whether the app actually did what
# was asked: a queued command waits (bounded) for the client's ack and
# reports "the app did NOT navigate" when none comes (skills/app_control).
# But the *spoken* narration belongs to the realtime model, and it can claim
# success anyway (founder, 2026-11-03, 22:03 call: "I've opened the models
# page" for a navigation that never happened — the page never even built;
# the command had died unacked at a call-segment boundary). The client's
# chips were already outcome-gated on the same results
# (tool_labels.outcome_label -> NO_CHIP); speech was not. The gate below is
# the speech counterpart, scoped to exactly the ack-gated navigation tools
# (tool_labels.NAV_CHIP_TOOLS) and to the one outcome that must never be
# narrated as success: a queued command the app never confirmed.
#
# The same gate carries a second, quieter latch for ``reconnect_voice``
# (founder, 2026-11-03, later that night): once a reconnect is queued the
# client tears the session down, and the model's "reconnecting now…"
# narration was cut off mid-sentence. While the silence latch is set the
# model's speech is interrupted exactly as above, but the gate speaks NO
# line of its own — the confirmation is the continuation session's one
# "I'm back" line (``_open_main_call``), spoken once it is actually live.

#: The one line the agent itself speaks when an ack-gated command goes
#: unconfirmed — short, truthful, and free of any success claim. Spoken via
#: ``session.say`` (the literal words, not a model paraphrase) while the
#: gate suppresses the model's own narration for the rest of the turn.
_COMMAND_NOT_CONFIRMED_LINE = (
    "Sorry, that didn't go through — the app didn't confirm it, "
    "so nothing changed on your screen."
)


def _command_unconfirmed(name: str, result: object) -> bool:
    """True when ``result`` is an ack-gated navigation tool's "queued but
    never confirmed" outcome: the honest ack-timeout lines, or a bounded
    tool timeout's ``error:`` string. Every other result — a ``navigated:``
    success, a couldn't-find, a clarification — is a specific, truthful
    outcome the model may narrate itself, so the gate leaves it alone."""
    if name not in _NAV_CLAIM_TOOLS or not isinstance(result, str):
        return False
    return (
        result == skills.app_control._NOT_NAVIGATED
        or result == skills.app_control._NOT_APPLIED
        or result.startswith("error:")
    )


def _reconnect_queued(name: str, result: object) -> bool:
    """True when ``result`` is ``reconnect_voice``'s queued outcome: the
    client acked a live call and is about to tear this session down and
    re-establish it on the saved stack. Every other outcome — the cooldown
    refusal, the no-live-call line — is spoken in a session that stays up,
    so the gate leaves them to the model."""
    return (
        name == "reconnect_voice"
        and isinstance(result, str)
        and result == skills.set_model_stack._RECONNECT_QUEUED_RESULT
    )


class _CommandClaimGate:
    """Per-session latch behind the ack-gated spoken claims (see the block
    comment above). Fed every session-tool result through
    :attr:`skills.VoiceTurnDedupe.outcome_observer` — the one funnel the
    deterministic execution, a same-turn replay and a fresh model call all
    pass through — plus the deterministic dispatcher's own execution and
    failure paths. While latched, the model's auto-generated speech for the
    rest of the user turn is interrupted at ``speech_created`` (the
    primitive :func:`relay_mute_control` uses) so the unconfirmed action is
    never narrated as done; the next finalized user turn re-arms it. The
    ``silenced`` latch is the same suppression for a queued reconnect (see
    :meth:`note_silence`), except the gate speaks no line at all."""

    def __init__(self, session: AgentSession) -> None:
        self._session = session
        self.failed = False
        self.silenced = False
        self._announced = False

    def note_turn(self) -> None:
        """A new finalized user turn started: re-arm."""
        self.failed = False
        self.silenced = False
        self._announced = False

    def note_failure(self) -> None:
        """An ack-gated command went unconfirmed this turn: latch, and
        speak the honest line once — from the agent, not the model."""
        self.failed = True
        if self._announced:
            return
        self._announced = True
        try:
            self._session.say(_COMMAND_NOT_CONFIRMED_LINE)
        except Exception:  # noqa: BLE001 - the gate must never break the call
            # say() cannot run on a realtime session with no TTS whose
            # model does not support it (Gemini Live, supports_say False) -
            # the honest line then rides generate_reply under a
            # say-exactly-this instruction, fire-and-forget exactly like
            # the say() above (its handle is likewise unchecked here).
            try:
                self._session.generate_reply(
                    instructions=load_voice_verbatim_line(
                        _COMMAND_NOT_CONFIRMED_LINE
                    )
                )
            except Exception:  # noqa: BLE001 - never break the call
                logger.exception(
                    "command claim gate could not speak its line"
                )

    def note_silence(self) -> None:
        """A reconnect was queued this turn: latch the suppression WITHOUT
        speaking a line of the gate's own. The client is tearing this
        session down, so anything said now is cut off mid-sentence
        (founder, 2026-11-03); the confirmation belongs to the
        continuation session (see ``_open_main_call``)."""
        self.silenced = True

    def observe(self, name: str, result: object) -> None:
        """``VoiceTurnDedupe.outcome_observer``: latch on an unconfirmed
        ack-gated result, latch the silence on a queued reconnect, ignore
        everything else."""
        if _command_unconfirmed(name, result):
            self.note_failure()
        elif _reconnect_queued(name, result):
            self.note_silence()


def relay_voice_commands(
    session: AgentSession,
    tools: list,
    dedupe: skills.VoiceTurnDedupe,
    *,
    end_call: Callable[[], Awaitable[None]] | None = None,
    interpret: Callable | None = None,
    get_context: Callable[[], object] | None = None,
    on_emotion: Callable | None = None,
    uid: str = "",
    session_id: str = "",
) -> None:
    """Run the voice-command backstop on ``session``: on each finalized user
    turn, execute a stack / navigation / launch / tour-start / hang-up match
    through the session's own tool (so its guard, timeout and ``tool_used``
    events apply exactly as for a model call). Non-command turns pass through
    untouched. The execution is claimed in ``dedupe`` first, so the model's
    own same-turn call to that tool replays the result instead of running the
    action twice. A partner-less launch (``name`` empty) claims the launch
    tool the same way but settles the "who with?" clarification instead of
    executing it — nothing launches, and the model's same-turn call replays
    the clarification rather than a "couldn't find someone" error.

    The interpreter is the voice-actions skill (``interpret`` +
    ``get_context``, wired by both main-session starters): its verdict maps
    to a command via ``skills.voice_actions.verdict_to_command``. Only a
    skill failure (outage / gateway / timeout) falls back to the
    deterministic :func:`detect_voice_command` net, which stays in place
    untouched as the interim backstop; an authoritative ``none`` verdict
    stays conversational with no net call. A "goodbye Ayma" sign-off
    (``"end_call"``, not a
    session tool) runs ``end_call`` — the call's own teardown — claimed the
    same way, exactly once per call: a duplicated finalized transcript must
    not tear the call down twice. Without ``interpret`` the relay runs the
    deterministic net alone, exactly as before.

    ``on_emotion`` (emotion matching, 2026-11-06) receives the emotion
    read folded into the skill's verdict on every finalized turn — the
    same single model pass, so emotion costs no extra gateway call."""
    tools_by_name = _tools_by_name(tools)
    # Ack-gated spoken claims: the gate observes every result the dedupe
    # wrapper settles (this dispatcher's executions and the model's own
    # calls alike) and owns the turn's narration when an ack-gated command
    # goes unconfirmed.
    gate = _CommandClaimGate(session)
    dedupe.outcome_observer = gate.observe
    # The teardown latch: ``note_turn`` retires the "end_call" claim on every
    # finalized turn, so a duplicated sign-off transcript would claim (and
    # run teardown) again — this keeps it to once per call, full stop.
    goodbye_done = {"fired": False}

    async def _run(name: str, kwargs: dict, tool, transcript: str) -> None:
        fut = dedupe.claim(name)
        if fut is None:
            return
        partnerless = not (kwargs.get("name") or "").strip()
        if name in ("open_practice_date", "open_date_sim") and partnerless:
            if not fut.done():
                fut.set_result(skills.app_control.launch_clarification(name))
            return
        try:
            result = await tool(**kwargs)
        except Exception as exc:  # noqa: BLE001 - a failed command must not kill the call
            dedupe.drop(name)
            if not fut.done():
                fut.set_exception(exc)
                fut.exception()  # mark retrieved: no warning when the model never calls
            if name in _NAV_CLAIM_TOOLS:
                # The execution itself blew up: nothing was confirmed, so
                # the turn's narration is the gate's, not the model's.
                gate.note_failure()
            logger.exception("deterministic voice command failed: %r", transcript)
            return
        if _command_unconfirmed(name, result):
            # Queued but never confirmed by the app: the gate owns this
            # turn's narration (the dedupe observer reports the same
            # result; note_failure is idempotent).
            gate.note_failure()
        if not fut.done():
            fut.set_result(result)

    async def _run_goodbye(transcript: str) -> None:
        fut = dedupe.claim("end_call")
        if fut is None:
            return
        if goodbye_done["fired"]:
            if not fut.done():
                fut.set_result(_GOODBYE_RESULT)
            return
        goodbye_done["fired"] = True
        if end_call is None:
            logger.warning(
                "voice goodbye %r has no teardown callback; "
                "turn left to the model",
                transcript,
            )
            dedupe.drop("end_call")
            if not fut.done():
                fut.set_result(_GOODBYE_RESULT)
            return
        try:
            await end_call()
        except Exception:  # noqa: BLE001 - teardown already logs; settle below
            dedupe.drop("end_call")
            logger.exception("voice goodbye teardown failed: %r", transcript)
        if not fut.done():
            fut.set_result(_GOODBYE_RESULT)

    def _dispatch(match: tuple[str, dict] | None, transcript: str) -> None:
        if match is None:
            return
        name, kwargs = match
        if name == "end_call":
            asyncio.create_task(_run_goodbye(transcript))
            return
        tool = tools_by_name.get(name)
        if tool is None:
            logger.warning(
                "voice command %r has no session tool; turn left to the model",
                transcript,
            )
            return
        asyncio.create_task(_run(name, kwargs, tool, transcript))

    async def _run_skill_first(transcript: str) -> None:
        try:
            context = (
                await asyncio.to_thread(get_context)
                if get_context is not None
                else None
            )
            verdict = await interpret(
                transcript, context, uid=uid, session_id=session_id
            )
            # Emotion fold-in (2026-11-06): the SAME verdict carries the
            # turn's emotion read — hand it to the session's emotion
            # wiring (state + Cartesia delivery). A failure here must
            # never cost the command dispatch below.
            if on_emotion is not None:
                read = getattr(verdict, "emotion", None)
                if read is not None:
                    try:
                        on_emotion(read)
                    except Exception:  # noqa: BLE001 - emotion is additive
                        logger.exception("emotion wiring failed")
            match = skills.voice_actions.verdict_to_command(verdict)
        except Exception:  # noqa: BLE001 - the net below is the fallback
            logger.exception(
                "voice-actions skill failed; falling back to the net: %r",
                transcript,
            )
            match = detect_voice_command(transcript)
        # An authoritative skill verdict — including ``none`` — never
        # consults the net: the turn stays conversational with no
        # ``detect_voice_command`` call.
        _dispatch(match, transcript)

    @session.on("user_input_transcribed")
    def _on_user_final(ev: UserInputTranscribedEvent) -> None:
        if not ev.is_final:
            return
        transcript = (ev.transcript or "").strip()
        if not transcript:
            return
        dedupe.note_turn()
        gate.note_turn()
        if interpret is None:
            _dispatch(detect_voice_command(transcript), transcript)
            return
        asyncio.create_task(_run_skill_first(transcript))

    @session.on("speech_created")
    def _on_speech_created_gate(ev) -> None:  # noqa: ANN001 - SpeechCreatedEvent
        # While the claim gate is latched, the model does not get to narrate
        # this turn at all — its version could claim an unconfirmed action
        # succeeded. The gate's own line (spoken at latch time) is the
        # turn's only narration; on the silence latch there is no line at
        # all — the turn ends quietly and the continuation session speaks
        # once the reconnect lands.
        if gate.failed or gate.silenced:
            ev.speech_handle.interrupt(force=True)


@dataclass
class RoomSeed:
    system_prompt: str
    chat_ctx: "llm.ChatContext | None" = None
    uid: str = ""
    session_id: str = ""
    seed_turns: list[Turn] = field(default_factory=list)
    voice_name: str = ""
    voice_language: str = ""
    # The user's dedicated free-text ACCENT (``ayma_voice_accent``, §13.9) — HOW
    # Ayma should sound, separate from ``voice_language`` (WHICH language). Fed
    # into the session instructions on an accent-capable provider (at boot, and
    # live through the hot-swap on Gemini); fixed-voice providers ignore it
    # (``voice_catalog.provider_supports_accent``). Empty = the default accent.
    voice_accent: str = ""
    # Per-user MAIN-voice STACK selection (§13.9), resolved in
    # ``main._voice_engine_seed`` from the saved preference. ``voice_mode`` empty
    # → use the deploy-time ``CONFIG.llm_provider_voice_main`` default (unchanged
    # behaviour). "realtime" → ``realtime_model_id``; "cascade" → ``brain_id`` /
    # ``stt_id`` / ``tts_id``. ``tts_voice`` is the chosen non-Gemini-preset voice
    # id (cascade TTS or OpenAI realtime; "" = the provider default).
    voice_mode: str = ""
    realtime_model_id: str = ""
    brain_id: str = ""
    stt_id: str = ""
    tts_id: str = ""
    tts_voice: str = ""
    # When set, the agent speaks first with these instructions (the pre-sign-in
    # "welcome" room). Empty for a normal session where the caller opens.
    greeting_instructions: str = ""
    # Practice Date voice (hackathon B): when True this room is a simulated-match
    # practice session — ``system_prompt`` is the persona prompt, and the agent
    # runs the practice path (no Ayma tools, no memory flush, a side-channel
    # live coach) instead of a normal Ayma call. ``persona_name`` / ``target_uid``
    # drive the live coach + practice-transcript persistence without the worker
    # ever re-reading the target's profile.
    practice: bool = False
    persona_name: str = ""
    # The simulated match's profile gender ("woman"/"man"/"non-binary"/…). Drives
    # the gender-matched practice TTS voice and the live coach's pronouns; empty
    # falls back to the session default voice and they/them.
    persona_gender: str = ""
    target_uid: str = ""


def relay_token_usage(
    session: AgentSession,
    uid: str,
    *,
    session_id: str = "",
    ctx: JobContext | None = None,
    on_credits_exhausted: Callable[[], Awaitable[None]] | None = None,
    inference: bool = False,
) -> None:
    """Add each Gemini Live turn's token count to the user's token ledger
    (`users/{uid}.token_usage.features.voice`) — the same lifetime cap the
    text side meters — and log the raw per-turn / per-session numbers so voice
    spend can be reconciled against the Cloud billing export. Also persists
    the input/output split (`token_usage.input`/`.output`) for cost audits
    (PLAN.md F1/F2): livekit's ``RealtimeModelMetrics`` reports these cleanly
    separated for the Gemini Live native-audio session (`input_tokens`/
    `output_tokens`, each already inclusive of audio), unlike some other
    realtime providers it also supports — no fabricated split. Also persists
    the running real-dollar `token_usage.cost_usd` (founder request
    2026-09-16) via `token_ledger.cost_usd_for`, using the audio-rate Gemini
    Live pricing in `token_ledger._MODEL_PRICING`. Each turn's write also
    lands one `users/{uid}/spend_events` doc tagged with this `session_id`
    (via `token_ledger.add`), so the Credits screen's "Real money" tab can
    show what this exact call cost (founder request 2026-09-26). Best-effort;
    a write failure never affects the call.

    §F3 (founder cost-bug report, 2026-09-21): credits used to be checked only
    once, at ``/bootstrap`` (session token mint) — a call that started with
    balance left ran unbounded once it crossed into zero/negative mid-call,
    since nothing during the live session ever checked again. ``on_credits_
    exhausted`` closes that gap: right after each turn's usage is recorded
    (the same natural "after each turn" point the ledger write already runs
    on), re-read the user's live balance via ``token_ledger.check`` — the same
    check/helper every other credit-gated call site already uses, not a new
    one — and fire the callback (once) the moment it comes back exhausted."""
    if not uid:
        return

    voice_provider = (
        token_ledger.PROVIDER_LIVEKIT_INFERENCE if inference
        else token_ledger.provider_for(token_ledger.FEATURE_VOICE)
    )
    tally = {"turns": 0, "input": 0, "output": 0, "total": 0}
    # Guards the callback to fire at most once — several `metrics_collected`
    # events can land in quick succession (e.g. overlapping turns) while the
    # async graceful-stop sequence is still in flight for the first one.
    cap_triggered = {"done": False}

    @session.on("metrics_collected")
    def _on_metrics(ev: MetricsCollectedEvent) -> None:
        m = ev.metrics
        if not isinstance(m, RealtimeModelMetrics):
            return
        in_tok = int(getattr(m, "input_tokens", 0) or 0)
        out_tok = int(getattr(m, "output_tokens", 0) or 0)
        total = int(getattr(m, "total_tokens", 0) or 0) or (in_tok + out_tok)
        if total <= 0:
            return
        tally["turns"] += 1
        tally["input"] += in_tok
        tally["output"] += out_tok
        tally["total"] += total
        # Per-turn breakdown — the number is whatever Gemini Live reports for
        # this response (livekit emits one metric per generation, not a running
        # sum). Grep `voice-usage` to reconcile against billing. The model is
        # the ACTUAL Live model this session runs (token_ledger.live_model_id
        # — the same selection build_realtime_model makes), threaded into the
        # cost computation so the ledger prices real traffic, not the Vertex
        # default it may not be using (pre-2026-09-26 accuracy bug).
        model = token_ledger.live_model_id()
        logger.info(
            "voice-usage turn uid=%s session=%s model=%s in=%d out=%d total=%d",
            uid, session_id or "?", model, in_tok, out_tok, total,
        )
        # One ledger write per Live turn — token_ledger.add is the exact same
        # write this handler used to compose inline (total/features.voice/
        # input/output/cost_usd Increments), plus the real-money ledger: it
        # also bumps token_usage.real_money_usd and appends a spend event
        # carrying this session's id, so the Credits screen can show each
        # voice call's real dollar cost (founder request 2026-09-26). add()
        # is best-effort by contract — a write failure never affects the call.
        token_ledger.add(
            uid,
            token_ledger.FEATURE_VOICE,
            total,
            input_tokens=in_tok,
            output_tokens=out_tok,
            model=model,
            session_id=session_id,
            provider=voice_provider,
        )

        if on_credits_exhausted is None or cap_triggered["done"]:
            return
        try:
            token_ledger.check(uid)
        except token_ledger.TokenCapExceeded:
            cap_triggered["done"] = True
            asyncio.create_task(on_credits_exhausted())
        except Exception:  # noqa: BLE001 - a failed check must not kill the call
            logger.exception("mid-call credit check failed for %s", uid)

    if ctx is not None:
        async def _log_session_total() -> None:
            logger.info(
                "voice-usage session uid=%s session=%s turns=%d "
                "in=%d out=%d total=%d",
                uid, session_id or "?", tally["turns"],
                tally["input"], tally["output"], tally["total"],
            )
        ctx.add_shutdown_callback(_log_session_total)


def relay_world_state(
    session: AgentSession, uid: str
) -> "skills.world_state.WorldStateRefresher | None":
    """Per-turn live-context refresh (founder, 2026-11-03): keep the model's
    picture of the world — the screen the user is on right now, and the
    outcomes of async work launched during the call (agent dates, match
    reports) — current on EVERY turn, instead of only when the model
    happens to call ``current_screen``. Without it she answers from
    whatever the screen was when the call started and keeps saying "let's
    see when the report comes through" about reports that already
    finished. Silent context maintenance (see ``skills.world_state``):
    the refresher only replaces one tagged item in the chat context; it
    never speaks. Wired on both main voice paths next to
    ``relay_voice_commands``, hanging off the same final-transcript event
    the mute gate and the command relay use."""
    if not uid:
        return None
    refresher = skills.world_state.WorldStateRefresher(
        db_factory=get_db,
        uid=uid,
        get_agent=lambda: session.current_agent,
    )

    @session.on("user_input_transcribed")
    def _on_user_final(ev: UserInputTranscribedEvent) -> None:
        if ev.is_final:
            refresher.poke()

    return refresher


def _read_room_seed(ctx: JobContext) -> RoomSeed:
    """Pull the system prompt, recent-turns window and persistence ids that
    ``POST /bootstrap`` left on the room metadata (§1.4, §1.5, §1.7 step 8).
    Falls back to the base persona and no history when metadata is absent or
    unreadable."""
    raw = (ctx.room.metadata or "").strip()
    if not raw:
        return RoomSeed(system_prompt=compose_system_prompt(variant="voice"))
    try:
        seed = json.loads(raw)
    except ValueError:
        logger.warning("unparseable room metadata; using base persona")
        return RoomSeed(system_prompt=compose_system_prompt(variant="voice"))

    turns = [
        Turn(role=str(t.get("role", "")), text=str(t.get("text", "")))
        for t in seed.get("recent_turns", [])
        if str(t.get("text", "")).strip()
    ]
    system_prompt = seed.get("system_prompt") or compose_system_prompt(
        recent_turns=turns, variant="voice"
    )

    chat_ctx: llm.ChatContext | None = None
    if turns:
        # Phase 2 voice seed diet (cost program 2026-09-26): the Live session
        # re-bills every seeded message on every turn of the call, so at
        # level >= 2 only the last few raw turns are seeded into the model's
        # chat context (the rolling summary travels inside the system prompt
        # /bootstrap composed). `seed_turns` below still carries the FULL
        # window — that's the raw_turns persistence base, which must never
        # shrink just because the model's view did.
        ctx_turns = turns
        if context_opt.voice_seed_diet_enabled():
            ctx_turns = turns[-context_opt.voice_tail_turns():]
        chat_ctx = llm.ChatContext.empty()
        for turn in ctx_turns:
            chat_ctx.add_message(
                role="assistant" if turn.role == ROLE_AYMA else "user",
                content=turn.text,
            )
    return RoomSeed(
        system_prompt=system_prompt,
        chat_ctx=chat_ctx,
        uid=str(seed.get("uid", "")),
        session_id=str(seed.get("session_id", "")),
        seed_turns=turns,
        voice_name=str(seed.get("voice_name", "")),
        voice_language=str(seed.get("voice_language", "")),
        voice_accent=str(seed.get("voice_accent", "")),
        voice_mode=str(seed.get("voice_mode", "")),
        realtime_model_id=str(seed.get("realtime_model_id", "")),
        brain_id=str(seed.get("brain_id", "")),
        stt_id=str(seed.get("stt_id", "")),
        tts_id=str(seed.get("tts_id", "")),
        tts_voice=str(seed.get("tts_voice", "")),
        greeting_instructions=str(seed.get("greeting_instructions", "")),
        practice=bool(seed.get("practice", False)),
        persona_name=str(seed.get("persona_name", "")),
        persona_gender=str(seed.get("persona_gender", "")),
        target_uid=str(seed.get("target_uid", "")),
    )


# A dispatched agent job can start racing the backend's `update_room_metadata`
# call — LiveKit auto-dispatches on room creation, and the SDK's local `Room`
# object metadata is refreshed asynchronously over its own signaling
# connection, so it can still read empty a beat after the backend's call
# already completed. That empty read falls back to uid="" -> zero session
# tools (no `current_screen`, no navigation, no raw_turns persistence) even
# though the real seed lands moments later. Poll briefly before accepting that
# fallback; ~0.9s worst case, paid only when the race actually happens.
_METADATA_RETRIES = 6
_METADATA_RETRY_DELAY_SECONDS = 0.15


async def _await_room_seed(ctx: JobContext) -> RoomSeed:
    """Like :func:`_read_room_seed`, but rides out the metadata-arrival race
    described above instead of taking a single point-in-time read."""
    for attempt in range(_METADATA_RETRIES):
        seed = _read_room_seed(ctx)
        if seed.uid:
            return seed
        if attempt < _METADATA_RETRIES - 1:
            await asyncio.sleep(_METADATA_RETRY_DELAY_SECONDS)
    if not seed.uid:
        logger.warning(
            "room metadata still empty after %.1fs — falling back to base "
            "persona with no uid/tools/history",
            _METADATA_RETRIES * _METADATA_RETRY_DELAY_SECONDS,
        )
    return seed


_MISHEARD_TOOL_REFUSAL = (
    "Not done: the user's last line looks like a misheard fragment, not a "
    "request. Don't act on it; ask them to say it again."
)


def misheard_fragment_guard(
    window: list[Turn], seeded: int, preference: Callable[[], str]
) -> Callable[[], str | None]:
    """A ``make_livekit_tools`` guard: refuse a tool call when the newest line
    in the call is the caller's and looks like speech recognition mishearing
    them (``voices.is_misheard_fragment``, founder test 2026-10-26: "el
    número" / "murió"). Only lines spoken in this call count (``seeded`` is
    the window length at call start), and only when that line is the latest
    turn, so a reply Ayma already gave since then lifts it. ``preference``
    returns the caller's current speaking language (it can change mid-call)."""
    import voices

    def _guard() -> str | None:
        if len(window) <= seeded:
            return None
        last = window[-1]
        if last.role == ROLE_USER and voices.is_misheard_fragment(
            last.text, preference()
        ):
            logger.info("tool call refused: misheard fragment %r", last.text)
            return _MISHEARD_TOOL_REFUSAL
        return None

    return _guard


def _session_tools(
    ctx: JobContext,
    uid: str,
    on_activity: Callable[[], None] | None = None,
    on_voice_change: Callable[[str | None, str], tuple[bool, str]] | None = None,
    voice_pref: object | None = None,
    guard: Callable[[], str | None] | None = None,
    session_id: str = "",
    window: list[Turn] | None = None,
    tour_gate: "TourNarrationGate | None" = None,
    dedupe: skills.VoiceTurnDedupe | None = None,
) -> list:
    """The shared skills registry (§13.6), bound to this session and wrapped as
    livekit-agents tools. Every call publishes a ``tool_used`` start/end event
    (§1.7 step 3) so the client can show what Ayma is doing mid-call, the way
    the text chat's status -> reply kicker already does. ``guard`` (see
    :func:`misheard_fragment_guard`) can refuse a call before it runs.
    ``session_id`` and ``window`` (the call's live turn list) let
    ``send_dm_message`` keep its pending send and check the caller's own yes.
    ``voice_pref`` (a ``voice_catalog.RuntimeVoices``) makes
    ``set_voice_preference`` stack-aware on a cascade / non-Gemini realtime call
    (the Gemini path uses ``on_voice_change`` instead). ``dedupe`` (the call's
    :class:`skills.VoiceTurnDedupe`) replays a same-turn deterministic command
    instead of running it twice — see :func:`relay_voice_commands`."""
    if not uid:
        return []

    def _on_call(phase: str, name: str, label: str | None) -> None:
        if on_activity is not None:
            on_activity()
        # A guided-tour tool ran this turn → the assistant turn it produces is
        # ephemeral tour narration; latch it so relay_transcripts drops it
        # (§11.2b). Set on start, so it's armed before the narration is spoken.
        if tour_gate is not None and phase == "start" and name in _GUIDED_TOUR_TOOLS:
            tour_gate.pending = True
        _publish_tool_event(ctx, phase, name, label)

    return skills.make_livekit_tools(
        get_db(), uid, on_call=_on_call, on_voice_change=on_voice_change,
        voice_pref=voice_pref, guard=guard, session_id=session_id,
        turns=(lambda: list(window)) if window is not None else None,
        dedupe=dedupe,
    )


# Mid-call voice switch (founder request 2026-10-25): Gemini Live fixes the
# voice (and the speech-language hint) when the Live session is set up, so a
# change during the call reconnects it. Before the reconnect Ayma says a short
# heads-up in the old voice; we wait for that to finish playing, bounded by
# these timeouts so a heads-up that never comes (muted, or the model skipped
# it) costs at most _HEADS_UP_START_TIMEOUT of extra gap.
_HEADS_UP_START_TIMEOUT = 2.0
_HEADS_UP_END_TIMEOUT = 8.0
# How long the new Live session is left to settle before the confirmation is
# requested. A reply asked for the instant the new session has been set up
# (instructions, history, tools) is lost on the LiveKit Inference gateway: it
# acknowledges the response (response.created) and then sends nothing, ever,
# and the turn queue stays blocked behind it, so the call sits on "Listening"
# (founder test 2026-10-26; reproduced live without a room: 24 of 27 immediate
# replies hung, 0 of 17 after a 0.5-2 s settle).
_SWAP_SETTLE_SECONDS = 1.0
# The new session must start speaking (the confirmation, or a reply to the
# caller) within this long after the settle, or it is treated as dead.
_SWAP_VERIFY_SECONDS = 6.0
# Fresh sessions built for one switch before giving up and restoring the
# previous voice.
_SWAP_ATTEMPTS = 2


async def _await_heads_up(
    session: AgentSession,
    start_timeout: float = _HEADS_UP_START_TIMEOUT,
    end_timeout: float = _HEADS_UP_END_TIMEOUT,
) -> None:
    """Return once the agent has spoken (and finished) its heads-up line, or
    once it is clear none is coming."""
    started = asyncio.Event()
    finished = asyncio.Event()

    def _on_state(ev: AgentStateChangedEvent) -> None:
        if ev.new_state == "speaking":
            started.set()
        elif started.is_set():
            finished.set()

    session.on("agent_state_changed", _on_state)
    try:
        if session.agent_state == "speaking":
            started.set()
        try:
            await asyncio.wait_for(started.wait(), timeout=start_timeout)
        except asyncio.TimeoutError:
            return
        try:
            await asyncio.wait_for(finished.wait(), timeout=end_timeout)
        except asyncio.TimeoutError:
            logger.warning("voice-swap heads-up still playing after %.0fs", end_timeout)
    finally:
        session.off("agent_state_changed", _on_state)


class VoiceSwapError(RuntimeError):
    """A mid-call voice switch whose new Live session never spoke (reported
    to Sentry with the session id and provider)."""


class SwappedVoiceAgent(Agent):
    """The same Ayma agent rebuilt on a new Live model after a mid-call voice
    switch. Its first line is a one-shot reply (the confirmation in the new
    voice, or the honest "couldn't switch" after a restore), requested once
    the new session has settled (see ``_SWAP_SETTLE_SECONDS``); there is no
    opener or greeting on this path."""

    def __init__(
        self, *, confirm_instructions: str, settle_seconds: float, **kwargs
    ) -> None:
        super().__init__(**kwargs)
        self._confirm_instructions = confirm_instructions
        self._settle_seconds = settle_seconds

    async def on_enter(self) -> None:
        try:
            await asyncio.sleep(self._settle_seconds)
            await self.session.generate_reply(instructions=self._confirm_instructions)
        except Exception:  # noqa: BLE001 - a missed confirmation shouldn't kill the call
            logger.exception("voice-swap confirmation failed")


class VoiceSwapper:
    """Applies a mid-call ``set_voice_preference`` change to the running call.

    The swap is an ``AgentSession.update_agent`` handoff to a
    :class:`SwappedVoiceAgent` whose ``llm`` is a freshly built realtime model
    (same builder, same provider route, new voice / language hint / accent):
    the framework closes the old Live session and opens a new one on the same
    room, seeded with the conversation so far. The ``AgentSession`` itself
    stays, so everything wired onto it — transcript relay into the raw_turns
    window, mute control, agent-state relay, token metering, the idle watchdog
    — carries on untouched. Function-call items are dropped from the carried
    history (their ids belong to the closed Live session); the spoken turns,
    the instructions (system prompt with wiki memory) and the tools carry over
    as they were.

    The dedicated free-text accent (``ayma_voice_accent``, §13.9) hot-swaps
    the same way: a new effective language (explicit language first, else the
    BCP-47 hint of the accent — the same derivation boot uses) reaches the
    rebuilt model, and the accent instruction block is rebuilt for the new
    accent instead of replaying the old one.

    Each new session is verified: it must start speaking within
    ``_SWAP_VERIFY_SECONDS`` of settling. One that doesn't is interrupted and
    rebuilt (up to ``_SWAP_ATTEMPTS`` sessions); if none speaks, the previous
    voice is restored and Ayma says honestly that she couldn't switch. Every
    step is logged and every failure goes to Sentry tagged with the session id
    and provider. While Ayma is muted ("shut up") the confirmation is
    suppressed by design, so silence is not counted as a failure then."""

    def __init__(
        self,
        session: AgentSession,
        *,
        system_prompt: str,
        route: str,
        voice_name: str = "",
        voice_language: str = "",
        voice_accent: str = "",
        accent_block: Callable[[str], str] | None = None,
        model_factory: Callable[..., object] | None = None,
        session_id: str = "",
        provider: str = "",
        is_muted: Callable[[], bool] = lambda: False,
        settle_seconds: float = _SWAP_SETTLE_SECONDS,
        verify_seconds: float = _SWAP_VERIFY_SECONDS,
    ) -> None:
        self._session = session
        # The RAW system prompt (no accent block): the block is composed per
        # accent at handoff time (``_base_prompt``) so an accent change
        # rebuilds the instructions instead of replaying the boot accent.
        self._system_prompt = system_prompt
        self._accent_block = accent_block or (lambda _a: "")
        self._route = route
        self._factory = model_factory or build_realtime_model
        self._session_id = session_id
        self._provider = provider or route
        self._is_muted = is_muted
        self._settle = settle_seconds
        self._verify = verify_seconds
        self.tools: list = []
        self._voice = (
            voice_name if voices.is_valid_voice(voice_name) else CONFIG.gemini_live_voice
        )
        self._language = voice_language
        self._accent = voice_accent
        # What the running Live session was actually built with.
        self._live_voice, self._live_language = self._voice, voice_language
        self._live_accent = voice_accent
        self._task: asyncio.Task | None = None
        self._closed = False
        session.on("close", self._on_close)

    def _on_close(self, _ev) -> None:  # noqa: ANN001 - CloseEvent
        self._closed = True

    @property
    def language(self) -> str:
        """The caller's current speaking-language preference (updated by a
        mid-call ``set_voice_preference``)."""
        return self._language

    @property
    def _live(self) -> tuple[str, str | None]:
        return self._live_voice, self._hint(self._live_language, self._live_accent)

    def _hint(self, language: str, accent: str = "") -> str | None:
        # The LiveKit Inference gateway (the only voice route) ignores the
        # language hint (see build_inference_realtime_model), so this is
        # always None today; the precedence below is kept for the message
        # wording: the explicit language, else the BCP-47 hint derived from
        # the free-text accent.
        if self._route == "inference" or (not language and not accent):
            return None
        return voices.bcp47_hint(language or voices.bcp47_hint(accent) or "")

    def _base_prompt(self, accent: str) -> str:
        """The handoff instructions' base: raw system prompt plus the accent
        block for ``accent`` ("" when the provider ignores accents)."""
        block = self._accent_block(accent)
        return f"{self._system_prompt}\n\n{block}" if block else self._system_prompt

    def _describe(self, voice: str, language: str, accent: str = "") -> str:
        desc = voices.VOICE_PRESETS.get(voice, "")
        text = f"the {voice} voice" + (f" ({desc})" if desc else "")
        if language:
            text += f", speaking: {language}"
        if accent:
            text += f", accent: {accent}"
        return text

    def request(
        self, preset: str | None, accent_language: str,
        *, voice_accent: str | None = None,
    ) -> tuple[bool, str]:
        """The ``set_voice_preference`` live hook: record the new target and,
        when it needs a new Live session, schedule the reconnect. Returns
        ``(reconnecting, detail)`` — ``detail`` says truthfully what changes.

        ``voice_accent`` (the dedicated ``ayma_voice_accent``) is ``None`` when
        no accent change was asked for; ``""`` clears back to the provider's
        default accent. An accent change always reconnects — even where the
        BCP-47 hint is unchanged — because the accent instructions can only
        reach the running session through the rebuild.

        Never blocks: the tool returns straight away (its result is what makes
        the model say the heads-up), and the reconnect runs as its own task
        that waits for that heads-up, so the tool call and the swap can never
        wait on each other."""
        parts: list[str] = []
        if preset:
            same = preset == self._voice
            parts.append(
                f"voice → {preset} ({voices.VOICE_PRESETS[preset]})"
                + (" — that is already the current voice" if same else "")
            )
            self._voice = preset
        if accent_language:
            self._language = accent_language
            hint = self._hint(accent_language, self._accent)
            parts.append(
                f"accent/language → {accent_language}: Gemini Live has no accent "
                + (
                    f"setting, so the speech-language hint is set to {hint} and "
                    if hint
                    else "setting, so "
                )
                + "you speak that way yourself from now on"
            )
        if voice_accent is not None:
            new_accent = voice_accent.strip()[:200]
            if new_accent == self._accent:
                parts.append(
                    f"accent → {new_accent or 'default'}"
                    " — that is already the current accent"
                )
            else:
                self._accent = new_accent
                hint = self._hint(self._language, new_accent)
                if not new_accent:
                    parts.append("accent → default (cleared)")
                elif hint:
                    parts.append(
                        f"accent → {new_accent}: the speech-language hint is "
                        f"set to {hint} and you speak that way yourself "
                        "from now on"
                    )
                else:
                    parts.append(
                        f"accent → {new_accent}: no speech-language hint for "
                        "that accent, so you speak that way yourself "
                        "from now on"
                    )
        reconnecting = (
            self._voice, self._hint(self._language, self._accent), self._accent
        ) != (*self._live, self._live_accent)
        if reconnecting:
            self._task = asyncio.get_running_loop().create_task(
                self._swap(self._task)
            )
        return reconnecting, "; ".join(parts)

    def _report(self, exc: BaseException) -> None:
        capture_exception(
            exc,
            tags={
                "voice_swap": "failed",
                "session_id": self._session_id or "?",
                "voice_provider": self._provider,
            },
        )

    async def _swap(self, previous: asyncio.Task | None) -> None:
        if previous is not None:
            # Serialise back-to-back requests; each one already logged its
            # own failure.
            await asyncio.gather(previous, return_exceptions=True)
        voice, language, accent = self._voice, self._language, self._accent
        if (voice, self._hint(language, accent), accent) == (
            *self._live, self._live_accent
        ):
            return
        old_voice, old_language, old_accent = (
            self._live_voice, self._live_language, self._live_accent
        )
        change = self._describe(voice, language, accent)
        logger.info(
            "voice-swap start session=%s provider=%s voice=%s->%s hint=%s",
            self._session_id or "?", self._provider, old_voice, voice,
            self._hint(language, accent),
        )
        try:
            await _await_heads_up(self._session)
            handed_off = False
            for attempt in range(1, _SWAP_ATTEMPTS + 1):
                step = f"attempt {attempt}"
                try:
                    if await self._handoff(
                        voice, language, accent,
                        confirm=voice_swap_confirm(change),
                        instructions=(
                            f"{self._base_prompt(accent)}\n\n"
                            f"{voice_swap_note(change)}"
                        ),
                        step=step,
                    ):
                        self._live_voice = voice
                        self._live_language = language
                        self._live_accent = accent
                        return
                    handed_off = True
                    self._report(
                        VoiceSwapError(
                            f"voice swap {step} produced no audio within "
                            f"{self._verify:.0f}s"
                        )
                    )
                except Exception as exc:  # noqa: BLE001 - try again, then restore
                    self._report(exc)
                    logger.exception("voice-swap %s failed", step)
                if self._closed:
                    logger.info("voice-swap abandoned: the call ended")
                    return
            # Back to the voice the call was on, and say so. The saved default
            # (already written by the tool) stays, so the next call uses it.
            if (self._voice, self._language, self._accent) == (
                voice, language, accent
            ):
                self._voice, self._language, self._accent = (
                    old_voice, old_language, old_accent
                )
            if handed_off:
                restored = await self._handoff(
                    old_voice, old_language, old_accent,
                    confirm=voice_swap_failed(change),
                    instructions=self._base_prompt(old_accent),
                    step="restore",
                )
                if not restored:
                    self._report(VoiceSwapError("voice swap restore produced no audio"))
                    logger.error(
                        "voice-swap restore failed session=%s provider=%s",
                        self._session_id or "?", self._provider,
                    )
            else:
                # No new session was ever handed the call: the original one
                # is still live, so say it there.
                self._session.generate_reply(instructions=voice_swap_failed(change))
        except Exception as exc:  # noqa: BLE001 - keep the call on the old voice
            self._report(exc)
            logger.exception("voice swap failed; staying on the current voice")

    async def _handoff(
        self,
        voice: str,
        language: str,
        accent: str,
        *,
        confirm: str,
        instructions: str,
        step: str,
    ) -> bool:
        """Hand the call to a new Live session on ``voice``/``language`` (+ the
        free-text ``accent`` when no explicit language is set) and return
        whether it started speaking in time. A silent one is interrupted so
        its stuck reply no longer blocks the turn queue. The builder derives
        the BCP-47 hint itself, exactly as at boot."""
        model = self._factory(voice, language or accent, route=self._route)
        history = self._session.current_agent.chat_ctx.copy(
            exclude_function_call=True,
            exclude_instructions=True,
            exclude_empty_message=True,
            exclude_handoff=True,
            exclude_config_update=True,
        )
        new_agent = SwappedVoiceAgent(
            confirm_instructions=confirm,
            settle_seconds=self._settle,
            instructions=instructions,
            tools=self.tools,
            chat_ctx=history,
            llm=model,
        )
        spoke = asyncio.Event()

        def _on_state(ev: AgentStateChangedEvent) -> None:
            if ev.new_state == "speaking" and self._session.current_agent is new_agent:
                spoke.set()

        self._session.on("agent_state_changed", _on_state)
        started = time.monotonic()
        try:
            self._session.update_agent(new_agent)
            logger.info(
                "voice-swap %s handoff session=%s provider=%s voice=%s hint=%s items=%d",
                step, self._session_id or "?", self._provider, voice,
                self._hint(language, accent), len(history.items),
            )
            try:
                await asyncio.wait_for(spoke.wait(), timeout=self._settle + self._verify)
            except asyncio.TimeoutError:
                if self._is_muted():
                    logger.info(
                        "voice-swap %s unverified: Ayma is muted session=%s",
                        step, self._session_id or "?",
                    )
                    return True
                logger.warning(
                    "voice-swap %s silent after %.1fs session=%s provider=%s",
                    step, time.monotonic() - started, self._session_id or "?",
                    self._provider,
                )
                await self._interrupt()
                return False
            logger.info(
                "voice-swap %s speaking after %.1fs session=%s provider=%s",
                step, time.monotonic() - started, self._session_id or "?",
                self._provider,
            )
            return True
        finally:
            self._session.off("agent_state_changed", _on_state)

    async def _interrupt(self) -> None:
        try:
            await asyncio.wait_for(self._session.interrupt(force=True), timeout=2.0)
        except Exception:  # noqa: BLE001 - the next handoff closes it anyway
            logger.warning("voice-swap interrupt of the silent reply failed", exc_info=True)


def voice_accent_control_handler(
    swapper: VoiceSwapper,
) -> Callable[[object], None]:
    """The ``voice_accent_control`` data listener: the settings screen saved
    mid-call, so hot-swap the live session to the saved accent/language
    (§13.9). A missing key means unchanged, ``""`` clears the accent back to
    the provider default; anything malformed is dropped, and an unchanged
    save is a no-op inside :meth:`VoiceSwapper.request`, so a voice-only save
    never rebuilds the session."""

    def _on_data(packet) -> None:  # noqa: ANN001 - rtc.DataPacket
        if getattr(packet, "topic", None) != TOPIC_VOICE_ACCENT_CONTROL:
            return
        try:
            payload = json.loads(bytes(packet.data).decode())
        except (ValueError, TypeError, UnicodeDecodeError):
            logger.warning("malformed voice_accent_control payload dropped")
            return
        if not isinstance(payload, dict):
            logger.warning("malformed voice_accent_control payload dropped")
            return
        accent = payload.get("accent")
        language = payload.get("language")
        reconnecting, detail = swapper.request(
            None,
            language.strip()[:200] if isinstance(language, str) else "",
            voice_accent=accent.strip()[:200] if isinstance(accent, str) else None,
        )
        if reconnecting:
            logger.info("voice-accent control hot-swap: %s", detail)

    return _on_data


def tour_tapped_handler(session: AgentSession) -> Callable[[object], None]:
    """The ``tour_tapped`` data listener (§11.2b): the user tapped the guided
    tour's spotlighted control, so drive Ayma to advance. Fires one
    ``generate_reply`` with the tour-tap instruction, which makes the model call
    ``advance_guided_tour`` — already in the session's tool set — that consumes
    the client's already-written ``tour_event`` doc and narrates the next step.
    This is the bridge that advances the tour on a tap regardless of whether a
    blocking ``advance_guided_tour`` happened to be mid-wait (founder/Scout,
    2026-11-03). Malformed payloads are dropped; the sync handler schedules the
    coroutine so it never blocks the data-channel callback."""

    def _on_data(packet) -> None:  # noqa: ANN001 - rtc.DataPacket
        if getattr(packet, "topic", None) != TOPIC_TOUR_TAPPED:
            return
        try:
            asyncio.create_task(
                session.generate_reply(instructions=load_tour_tapped_kick())
            )
        except Exception:  # noqa: BLE001 - never crash the data callback
            logger.exception("tour_tapped generate_reply failed to schedule")

    return _on_data


def _has_new_turns(window: list[Turn], seeded_turn_count: int) -> bool:
    """True once ``window`` (the session's running turn collector, seeded from
    `/bootstrap`'s ``recent_turns`` and appended to live by
    :func:`relay_transcripts`) holds at least one turn beyond what it was
    seeded with — i.e. something was actually said in this room, as opposed
    to a job that was dispatched (§ room creation triggers LiveKit's
    automatic dispatch) but never heard from a connected caller."""
    return len(window) > seeded_turn_count


async def entrypoint(ctx: JobContext) -> None:
    """Join the dispatched room and run one Gemini Live voice session.

    The call's keep-alive (``agent_keepalive``) starts first, before the room
    connect, so Cloud Run sees this instance as busy for the whole call and
    its end-of-call flush; the job's shutdown callback releases it."""
    keepalive = CallKeepAlive.for_job(ctx.job.id)
    keepalive.start()
    ctx.add_shutdown_callback(keepalive.release)
    try:
        await _run_session(ctx, keepalive)
    except Exception as exc:
        capture_exception(exc)
        raise


async def _run_session(ctx: JobContext, keepalive: CallKeepAlive) -> None:
    await ctx.connect()
    seed = await _await_room_seed(ctx)

    # Practice Date voice (hackathon B): a simulated-match room runs an entirely
    # separate, deliberately smaller path — no Ayma tools, no memory flush/wiki
    # ingest (a simulation must never touch the user's real data), a
    # side-channel live coach. Gated strictly on the room-metadata flag so every
    # normal voice call below is untouched.
    if seed.practice:
        await _run_practice_session(ctx, seed)
        return

    # The full session window = the turns carried in from /bootstrap plus every
    # finalized voice turn from here on. Persisted to raw_turns AND folded into
    # the wiki on shutdown — the room can close for any reason (a clean hang
    # up, but also out-of-credits mid-call, a dropped network, or the app
    # being killed/backgrounded), and this is the one hook guaranteed to run
    # regardless, so it must not rely on a later client `/post-turn` call that
    # may never come (see `post_turn.persist_and_ingest`'s docstring for the
    # real conversation this was root-caused against).
    window: list[Turn] = list(seed.seed_turns)
    # Provider decided ONCE per call and threaded to the model, the session
    # record and the ledger. Always LiveKit Inference (founder rule
    # 2026-11-04 — no direct-Google voice); the route plumbing is kept so the
    # threading shape stays intact.
    route = llm_routing.route_for("voice", uid=seed.uid)
    use_inference = route == "inference"
    voice_provider = (
        token_ledger.PROVIDER_LIVEKIT_INFERENCE if use_inference
        else token_ledger.provider_for(token_ledger.FEATURE_VOICE)
    )
    logger.info(
        "voice-provider uid=%s session=%s provider=%s",
        seed.uid, seed.session_id or "?", voice_provider,
    )
    flush = SessionFlush(
        get_db(), seed.uid, seed.session_id, window,
        seeded_turn_count=len(window), voice_provider=voice_provider,
    )
    ctx.add_shutdown_callback(flush.run)
    keepalive.hold_for(flush.run)

    # MAIN voice STACK selection (§13.9). The user's saved ``voice_mode`` wins
    # over the deploy-time default; empty keeps exactly today's behaviour
    # (``CONFIG.llm_provider_voice_main``: ``meta`` → cascade, else Gemini Live).
    #
    #  * CASCADE → STT + brain(LLM) + TTS as selected
    #    (:func:`build_cascade_session`). Two fallbacks keep it from ever taking
    #    the main voice down: a cascade that can't be *built* (no key, missing
    #    plugin) falls through to Gemini Live here, and one that dies at *runtime*
    #    switches to a fresh Gemini Live session on the same room
    #    (:func:`_arm_main_cascade_fallback`).
    #  * REALTIME → one native-audio model: Gemini Live (the LOCKED model, the
    #    default) or OpenAI Realtime (:func:`build_openai_realtime_model`, inert
    #    without the flag + ``OPENAI_API_KEY`` — falls back to Gemini Live).
    # Every path shares the one ``flush``/``window`` so memory is never doubled.
    from llm_provider import PROVIDER_META
    import voice_catalog

    mode = seed.voice_mode
    if not mode:
        mode = (
            voice_catalog.MODE_CASCADE
            if CONFIG.llm_provider_voice_main == PROVIDER_META
            else voice_catalog.MODE_REALTIME
        )

    if mode == voice_catalog.MODE_CASCADE:
        brain_id = seed.brain_id or voice_catalog.BRAIN_META
        stt_id = seed.stt_id or CONFIG.meta_cascade_stt_model
        tts_id = seed.tts_id or CONFIG.meta_cascade_tts_model
        try:
            session = build_cascade_session(
                brain_id, stt_id, tts_id, seed.tts_voice, seed.voice_language
            )
        except Exception as exc:  # noqa: BLE001 - never take the main voice down
            logger.warning(
                "cascade voice unavailable (%s: %s) — falling back to Gemini Live",
                type(exc).__name__, exc,
            )
            capture_exception(exc)
        else:
            logger.info(
                "main-voice cascade uid=%s session=%s brain=%s stt=%s tts=%s",
                seed.uid, seed.session_id or "?", brain_id, stt_id, tts_id,
            )
            _arm_main_cascade_fallback(
                ctx, seed, session,
                flush=flush, window=window, route=route,
                use_inference=use_inference, voice_provider=voice_provider,
            )
            await _start_main_cascade_session(
                ctx, seed, session, flush=flush, window=window,
            )
            return
    elif seed.realtime_model_id == voice_catalog.REALTIME_OPENAI:
        realtime = build_openai_realtime_model(seed.tts_voice)
        if realtime is not None:
            logger.info(
                "main-voice OpenAI Realtime uid=%s session=%s model=%s",
                seed.uid, seed.session_id or "?", CONFIG.openai_realtime_model,
            )
            await _start_main_gemini_session(
                ctx, seed,
                flush=flush, window=window, route=route,
                use_inference=use_inference, voice_provider=voice_provider,
                llm=realtime, enable_hot_swap=False,
            )
            return
        logger.warning(
            "OpenAI Realtime selected but unavailable (flag/OPENAI_API_KEY) — "
            "falling back to Gemini Live",
        )
    elif seed.realtime_model_id and seed.realtime_model_id != voice_catalog.REALTIME_GEMINI:
        # A non-canonical realtime model from the live LiveKit catalog — run it
        # on the Inference gateway. Any failure falls back to Gemini Live below.
        try:
            realtime = build_inference_realtime_model(
                seed.tts_voice or seed.voice_name, model=seed.realtime_model_id
            )
        except Exception as exc:  # noqa: BLE001 - never take the main voice down
            logger.warning(
                "inference realtime %s unavailable (%s) — falling back to "
                "Gemini Live", seed.realtime_model_id, exc,
            )
        else:
            logger.info(
                "main-voice inference realtime uid=%s session=%s model=%s",
                seed.uid, seed.session_id or "?", seed.realtime_model_id,
            )
            await _start_main_gemini_session(
                ctx, seed,
                flush=flush, window=window, route=route,
                use_inference=use_inference, voice_provider=voice_provider,
                llm=realtime, enable_hot_swap=False,
            )
            return

    await _start_main_gemini_session(
        ctx, seed,
        flush=flush, window=window, route=route,
        use_inference=use_inference, voice_provider=voice_provider,
    )


def _reconnect_setup_label(seed: RoomSeed, *, cascade: bool) -> str:
    """The user-facing name of the stack a session is running, for the
    post-reconnect "I'm back" line: the brain on the cascade path, the
    realtime model on the realtime path. Static labels for the canonical
    options (the same labels the models screen shows); any other id names
    itself, exactly as the catalog lists it."""
    import voice_catalog

    if cascade:
        brain_id = seed.brain_id or voice_catalog.BRAIN_META
        if brain_id == voice_catalog.BRAIN_META:
            return "Meta Muse Spark"
        if brain_id == voice_catalog.BRAIN_OPEN_WEIGHTS:
            return "Llama 3.1 8B (open weights)"
        return brain_id
    model_id = seed.realtime_model_id
    if model_id == voice_catalog.REALTIME_OPENAI:
        return "OpenAI Realtime"
    if model_id and model_id != voice_catalog.REALTIME_GEMINI:
        return model_id
    return "Gemini Live"


async def _open_main_call(
    session: AgentSession,
    seed: RoomSeed,
    *,
    window: list[Turn],
    opener_chat_ctx: NotGivenOr[object] = NOT_GIVEN,
    seed_user_turn: bool = False,
) -> None:
    """Open a started main voice call the same way on both the Gemini Live and
    Meta cascade paths: a pre-sign-in "welcome" room has Ayma greet first; every
    other call lets Ayma open only if the caller stays silent
    (:func:`maybe_open_conversation`), which — when there is prior context —
    greets and offers the choice to continue or switch rather than resuming the
    old topic (founder behaviour, 2026-10-28).

    ``opener_chat_ctx`` is forwarded to the silent-caller opener as a secondary
    guard scoping the opener's generation context (the cascade passes a
    history-free context); NOT_GIVEN leaves it against the agent's full context
    for Gemini Live / every other path.

    ``seed_user_turn`` is set only on the cascade (text-LLM) path: an
    agent-initiated greeting/opener on a chat LLM must carry at least one user
    turn, or the OpenAI-compatible gateway (incl. LiveKit Inference) rejects the
    system-only message list with HTTP 400. A benign synthetic user turn
    (:func:`load_voice_session_seed`) is seeded so the opener generates normally.
    Realtime models (Gemini Live / Inference RealtimeModel) never hit that path,
    so they leave it False."""
    brain = seed.brain_id or seed.realtime_model_id or "gemini-live"
    if seed.uid and await asyncio.to_thread(
        skills.set_model_stack.claim_reconnect_announcement, get_db(), seed.uid
    ):
        # Post-reconnect confirmation (founder, 2026-11-03): this session is
        # the continuation of a user-requested reconnect. The OLD session
        # stayed silent (the claim gate's silence latch), so this "I'm back"
        # line — one sentence, naming the stack now running — is the only
        # word spoken about the switch, and it is spoken only now that the
        # new session is actually live on it. The claim is one-shot, so a
        # fresh call (or a fallback re-open on this room) never repeats it;
        # it replaces the generic opener below rather than stacking on it.
        setup = _reconnect_setup_label(seed, cascade=seed_user_turn)
        reply_kwargs: dict = {"instructions": reconnect_back(setup)}
        if seed_user_turn:
            reply_kwargs["user_input"] = load_voice_session_seed()
        logger.info(
            "voice opener FIRED kind=reconnect setup=%s brain=%s session=%s "
            "— awaiting generate_reply",
            setup, brain, seed.session_id or "?",
        )
        try:
            await session.generate_reply(**reply_kwargs)
        except Exception:  # noqa: BLE001 - a missed line shouldn't kill the call
            logger.exception(
                "reconnect announcement generate_reply ERRORED brain=%s "
                "session=%s",
                brain, seed.session_id or "?",
            )
        else:
            logger.info(
                "voice opener generate_reply COMPLETED kind=reconnect "
                "brain=%s session=%s",
                brain, seed.session_id or "?",
            )
        return
    if seed.greeting_instructions:
        reply_kwargs: dict = {"instructions": seed.greeting_instructions}
        if seed_user_turn:
            reply_kwargs["user_input"] = load_voice_session_seed()
        logger.info(
            "voice opener FIRED kind=greeting brain=%s session=%s — awaiting "
            "generate_reply", brain, seed.session_id or "?",
        )
        try:
            await session.generate_reply(**reply_kwargs)
        except Exception:  # noqa: BLE001 - a missed greeting shouldn't kill the call
            logger.exception(
                "welcome greeting generate_reply ERRORED brain=%s session=%s",
                brain, seed.session_id or "?",
            )
        else:
            logger.info(
                "voice opener generate_reply COMPLETED kind=greeting brain=%s "
                "session=%s", brain, seed.session_id or "?",
            )
    else:
        await maybe_open_conversation(
            session, seed, window=window, opener_chat_ctx=opener_chat_ctx,
            seed_user_turn=seed_user_turn,
        )


def _voice_vocab(
    *,
    mode: str,
    realtime_model_id: str = "",
    tts_id: str = "",
    current_voice_id: str = "",
):
    """The running stack's voice vocabulary and the instruction block injected
    so the agent reports the voices/current voice of the stack it is ACTUALLY
    running, not the Gemini presets (§13.9). Returns ``(runtime_voices,
    directive)``: the directive is appended to the session instructions, and
    ``runtime_voices`` (``None`` on the Gemini hot-swap path, which keeps its
    preset tool) makes ``set_voice_preference`` resolve within the active set."""
    import voice_catalog

    rv = voice_catalog.runtime_voices(
        mode=mode,
        realtime_model_id=realtime_model_id,
        tts_id=tts_id,
        current_voice_id=current_voice_id,
    )
    directive = voice_vocab_directive(
        voice_catalog.current_label(rv),
        voice_catalog.vocab_lines(rv),
        rv.hot_swap,
    )
    return rv, directive


def _accent_block(rv, accent: str) -> str:
    """The ACCENT instruction for this session, or ``""`` (§13.9) — used at
    boot and rebuilt on every hot-swapped session.

    Routed ONLY to an accent-capable provider (``rv.supports_accent`` — Gemini
    Live / OpenAI Realtime): the saved ``ayma_voice_accent`` becomes a style
    instruction so the voice speaks that way from the first word and never
    reverts to the provider's default accent. A fixed-voice provider (every
    cascade TTS here) gets ``""`` and ignores the accent gracefully — nothing is
    passed to it, so there is no crash and no wrong-accent effect."""
    accent = (accent or "").strip()
    if not accent or rv is None or not rv.supports_accent:
        return ""
    return voice_accent_directive(accent)


def _compose_instructions(
    system_prompt: str, accent_block: str, vocab: str
) -> str:
    """The session instructions: the composed system prompt, then the boot-time
    accent block (when the provider supports accent), then the stack-aware voice
    vocabulary, then the voice tool-use directive — skipping any empty part.

    The tool-use directive (``prompts/voice_tool_use.md`` via
    :func:`load_voice_tool_use`) rides on BOTH main voice paths: it forces
    call-before-confirm tool use on the Meta cascade, whose chat LLM is
    probabilistic and would otherwise narrate an app action as done without
    ever firing the tool (founder voice bug, 2026-10-28), and Gemini Live
    gets the same discipline (founder, prod 2284)."""
    return "\n\n".join(
        p for p in (system_prompt, accent_block, vocab, load_voice_tool_use())
        if p
    )


def _cascade_seed_chat_ctx(chat_ctx):
    """The seeded history for a MAIN cascade session, with any trailing run of
    USER turns dropped (founder bug, 2026-10-27).

    At session start the whole seeded ``chat_ctx`` is prior-session history
    (``/bootstrap``'s ``recent_turns``) — every genuinely new turn arrives live
    through STT, never through the seed. On the Meta cascade, a trailing
    *unanswered* user message left in the model's context makes the pipeline
    answer that STALE turn (or fire a tool on it) the instant the call connects,
    before the caller says anything — the exact bug reported. Gemini Live does
    not (its realtime context only replies on server-side turn detection), so its
    path keeps the full history unchanged. Dropping only the trailing user
    message(s) for the cascade leaves all prior context intact (and the full
    window is still persisted / summarised), so the cascade now greets via the
    normal opener and waits for real input instead of acting on history."""
    if chat_ctx is None:
        return None
    items = list(chat_ctx.items)
    while items and getattr(items[-1], "role", None) == "user":
        items.pop()
    if len(items) == len(chat_ctx.items):
        return chat_ctx
    return llm.ChatContext(items)


async def _start_main_gemini_session(
    ctx: JobContext,
    seed: RoomSeed,
    *,
    flush: SessionFlush,
    window: list[Turn],
    route: str,
    use_inference: bool,
    voice_provider: str,
    llm: object | None = None,
    enable_hot_swap: bool = True,
) -> None:
    """Build and start the normal (default) Ayma voice call on a native-audio
    realtime model.

    Default: Gemini Live (the LOCKED model) — the unchanged main-voice path, also
    reused as the cascade runtime fallback (:func:`_arm_main_cascade_fallback`),
    reusing the caller's ``flush``/``window`` so a fallback never double-persists.
    ``llm`` overrides the model (OpenAI Realtime, §13.9); ``enable_hot_swap``
    False disables the mid-call Gemini voice swap (``VoiceSwapper``), which only
    rebuilds Gemini Live, so a non-Gemini realtime model keeps the right voice."""
    # allow_interruptions defaults on; stated here so the "no custom VAD, native
    # turn-detection only" decision (§1.7 step 9) is visible at the call site.
    # Boot-time accent for native-audio realtime (§13.9, founder bug 2026-11-01):
    # Gemini Live native audio IGNORES the prompt-text accent for pronunciation —
    # the only locale lever it honours is the BCP-47 ``language`` passed here.
    # Prefer the explicit saved ``voice_language``; otherwise derive the locale
    # from the free-text accent ("indian" -> "en-IN", via voices.bcp47_hint) so a
    # bare accent still reaches the model. The prompt-text accent directive below
    # stays untouched; this just ALSO feeds the real lever.
    effective_language = seed.voice_language or voices.bcp47_hint(seed.voice_accent)
    session = AgentSession(
        llm=llm or build_realtime_model(
            seed.voice_name, effective_language, route=route
        ),
        allow_interruptions=True,
    )
    tour_gate = TourNarrationGate()
    dedupe = skills.VoiceTurnDedupe()
    relay_transcripts(ctx, session, collector=window, tour_gate=tour_gate)
    # Session closed = the conversation is over (no more turns can arrive):
    # start the memory write now rather than at job shutdown (see
    # SessionFlush.start).
    session.on("close", lambda _ev: flush.start())
    relay_agent_state(ctx, session)
    mute = MuteState()
    relay_mute_control(session, mute, ctx)
    relay_token_usage(
        session,
        seed.uid,
        session_id=seed.session_id,
        ctx=ctx,
        inference=use_inference,
        on_credits_exhausted=lambda: end_call_out_of_credits(
            ctx, session, seed.uid, flush.run
        ),
    )
    # Create idle watchdog but don't start timer yet (to avoid measurement lag
    # during session setup — bugfix for F1 warm-call early fires).
    # Timer will be started after session.start() completes.
    watchdog = watch_for_idle(
        ctx, session, seed.uid, flush.run, start_now=False
    )
    # Stack-aware voice vocabulary (§13.9): ``llm is None`` is the Gemini Live
    # realtime path (also the cascade build/runtime fallback — which is why the
    # vocabulary correctly reflects Gemini then); any other ``llm`` is a
    # non-Gemini realtime model whose voices are its own. The current voice is
    # resolved exactly as the model builder picks it.
    import voice_catalog

    if llm is None:
        realtime_model_id = voice_catalog.REALTIME_GEMINI
        current_voice_id = (
            seed.voice_name
            if seed.voice_name and voices.is_valid_voice(seed.voice_name)
            else CONFIG.gemini_live_voice
        )
    else:
        realtime_model_id = seed.realtime_model_id
        current_voice_id = seed.tts_voice or seed.voice_name
    rv, vocab = _voice_vocab(
        mode=voice_catalog.MODE_REALTIME,
        realtime_model_id=realtime_model_id,
        current_voice_id=current_voice_id,
    )
    # Boot-time accent (§13.9): fed into the instructions only on an accent-capable
    # realtime provider (Gemini Live / OpenAI Realtime). The hot-swapper gets
    # the RAW prompt plus the boot accent and the same builder, so a mid-call
    # accent change rebuilds the instructions for the NEW accent instead of
    # replaying the boot one.
    accent_block = _accent_block(rv, seed.voice_accent)
    _instructions = _compose_instructions(seed.system_prompt, accent_block, vocab)
    # Video / screen share behaviour (feedback item 13) — both main stacks.
    _instructions += VISION_INSTRUCTIONS
    # Mid-call voice hot-swap (``VoiceSwapper``) only rebuilds Gemini Live, so it
    # is wired only on the Gemini path; a non-Gemini realtime model
    # (``enable_hot_swap=False``) just saves the preference for the next call,
    # resolving it within that model's own voices (``voice_pref``).
    swapper = (
        VoiceSwapper(
            session,
            system_prompt=seed.system_prompt,
            route=route,
            voice_name=seed.voice_name,
            voice_language=seed.voice_language,
            voice_accent=seed.voice_accent,
            accent_block=lambda a: _accent_block(rv, a),
            session_id=seed.session_id,
            provider=voice_provider,
            is_muted=lambda: mute.muted,
        )
        if enable_hot_swap
        else None
    )
    tools = _session_tools(
        ctx,
        seed.uid,
        on_activity=watchdog.touch if watchdog else None,
        on_voice_change=swapper.request if swapper else None,
        voice_pref=None if swapper else rv,
        guard=misheard_fragment_guard(
            window, len(window),
            (lambda: swapper.language) if swapper else (lambda: seed.voice_language),
        ),
        session_id=seed.session_id,
        window=window,
        tour_gate=tour_gate,
        dedupe=dedupe,
    )
    async def _goodbye() -> None:
        await end_call_goodbye(ctx, seed.uid, flush.run)

    # Voice-actions skill first, deterministic net as the interim backstop: a
    # clear command in a finalized user turn executes through the session's
    # own tools, exactly as in the text lane.
    relay_voice_commands(
        session, tools, dedupe,
        end_call=_goodbye,
        interpret=skills.voice_actions.interpret_voice_action,
        get_context=lambda: skills.voice_actions.read_call_context(
            get_db(), seed.uid, window
        ),
        uid=seed.uid,
        session_id=seed.session_id,
    )
    relay_world_state(session, seed.uid)
    if swapper:
        swapper.tools = tools
        # A settings save mid-call arrives on the data channel (§13.9).
        ctx.room.on("data_received", voice_accent_control_handler(swapper))
    # A guided-tour tap arrives on the data channel (§11.2b) — drive the advance.
    ctx.room.on("data_received", tour_tapped_handler(session))
    agent_kwargs: dict = {"instructions": _instructions, "tools": tools}
    if seed.chat_ctx is not None:
        agent_kwargs["chat_ctx"] = seed.chat_ctx
    agent = Agent(**agent_kwargs)
    await session.start(
        agent=agent,
        room=ctx.room,
        # Video input ON (feedback item 13): the user's camera / screen
        # tracks, published into this room by the client, flow to the
        # realtime model through the existing LiveKit vision path.
        room_input_options=_room_input_options(video_enabled=True),
        room_output_options=RoomOutputOptions(transcription_enabled=False),
    )
    # Declare vision support from the ONE catalog source of truth
    # (``RuntimeVoices.supports_video`` — feedback item 13): a realtime
    # model on a video-capable provider (Gemini Live, OpenAI Realtime)
    # genuinely perceives the frames, so the client enables the Video /
    # Screen share toggles; anything else is declared unsupported and the
    # client shows them disabled. Watch the tracks either way for
    # FLAG_SECURE black frames.
    _vision_ok = voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_REALTIME,
        realtime_model_id=seed.realtime_model_id,
    ).supports_video
    await _publish_voice_status(
        ctx,
        VOICE_STATUS_VISION_SUPPORTED
        if _vision_ok
        else VOICE_STATUS_VISION_UNSUPPORTED,
    )
    watch_vision_tracks(ctx, vision_supported=_vision_ok)
    session_live_ts = time.monotonic()
    logger.info("voice session LIVE: ts=%.3f uid=%s session=%s", 
                session_live_ts, seed.uid, seed.session_id or "?")
    
    # Start idle timer NOW that session is truly live (handlers were already
    # registered before session.start, so no events are lost)
    if watchdog:
        watchdog.start()
        logger.info("idle watchdog ARMED post-live for session %s", seed.session_id or "?")
    
    await _open_main_call(session, seed, window=window)


# --- Emotion matching (founder directive, 2026-11-06; emotion.py) ----------


def _emotion_matching_on(uid: str) -> bool:
    """The ``emotion_matching`` flag for this call's user. Any failure
    resolves OFF — emotion is additive and must never break a call."""
    try:
        value, _source = feature_flags.resolve("emotion_matching", uid=uid or None)
        return bool(value)
    except Exception:  # noqa: BLE001 - flags must never break a call
        logger.warning("emotion_matching flag read failed", exc_info=True)
        return False


class _EmotionAgent(Agent):
    """A cascade ``Agent`` that injects the session's current emotion
    context into each turn's generation.

    ``on_user_turn_completed`` receives a TEMPORARY copy of the chat
    context for the current generation only (livekit-agents 1.8.9,
    ``AgentActivity``), so the injected line colours this one reply and
    is never persisted into the conversation history. The state it reads
    is updated by the voice-actions pass running in parallel on the same
    finalized transcript — so the line reflects the latest settled read
    (usually the previous turn's; emotional state is sticky by design,
    see ``emotion.EmotionState``). Realtime sessions never use this
    class: their turn detection is server-side and the hook is
    unreachable there (see the mute-control block comment above); the
    realtime path gets the standing guidance through the session seed
    instead, plus Gemini 3.8 Live's always-on native affective dialogue.
    """

    def __init__(
        self, *, emotion_state: emotion_mod.EmotionState, **kwargs
    ) -> None:
        super().__init__(**kwargs)
        self._emotion_state = emotion_state

    async def on_user_turn_completed(self, turn_ctx, new_message) -> None:  # noqa: ANN001 - SDK hook signature
        line = emotion_mod.context_line(self._emotion_state)
        if line:
            turn_ctx.add_message(role="system", content=line)


def _apply_cartesia_emotion(session: AgentSession, state: emotion_mod.EmotionState) -> None:
    """Push the state's Cartesia delivery (emotion + speed) onto the
    session's TTS leg when that leg is the Cartesia plugin.

    The plugin's ``update_options`` is the documented dynamic control:
    replies synthesised afterwards use the new settings. Duck-typed so
    every other TTS leg (LiveKit Inference TTS has no emotion control)
    is a silent no-op — those legs get emotion only through the reply
    text the brain shapes under the injected guidance. A ``(None, None)``
    mapping (neutral) leaves the current settings untouched: Sonic's
    own text-inferred delivery is the neutral behaviour."""
    emo, speed = emotion_mod.cartesia_delivery(state)
    if emo is None and speed is None:
        return
    tts_obj = getattr(session, "tts", None)
    update = getattr(tts_obj, "update_options", None)
    if not callable(update):
        return
    kwargs: dict[str, object] = {}
    if emo is not None:
        kwargs["emotion"] = [emo]
    if speed is not None:
        kwargs["speed"] = speed
    try:
        update(**kwargs)
        logger.info("emotion: cartesia delivery set emotion=%s speed=%s", emo, speed)
    except Exception:  # noqa: BLE001 - delivery is additive, never fatal
        logger.exception("emotion: cartesia update_options failed")


async def _start_main_cascade_session(
    ctx: JobContext,
    seed: RoomSeed,
    session: AgentSession,
    *,
    flush: SessionFlush,
    window: list[Turn],
) -> None:
    """Start the normal Ayma voice call on the Meta cascade (Deliverable A).

    Wires the same session-agnostic relays the Gemini Live path uses — transcript
    relay into the raw_turns ``window`` (so memory persistence, barge-in, the
    idle watchdog, mute control, keepalive and the greeting/opener behave exactly
    as on a normal call) — and meters usage through :func:`relay_cascade_usage`
    (the cascade emits ``LLMMetrics``, not ``RealtimeModelMetrics``), passing the
    same §F3 mid-call credit-cap stop as Gemini Live. Tools are kept so Ayma can
    still drive the app; mid-call voice hot-swap (``VoiceSwapper``) is Gemini
    Live-only, so ``set_voice_preference`` here saves the preference for the next
    call rather than reconnecting (``on_voice_change`` is unset). The memory
    flush is NOT started on an ERROR close here — the runtime fallback continues
    the call on a fresh Gemini Live session on the same window, which flushes at
    its own close."""
    tour_gate = TourNarrationGate()
    dedupe = skills.VoiceTurnDedupe()
    relay_transcripts(ctx, session, collector=window, tour_gate=tour_gate)
    session.on("close", _flush_on_non_error_close(flush))
    _arm_cascade_tts_error_status(ctx, seed, session)
    relay_agent_state(ctx, session)
    mute = MuteState()
    relay_mute_control(session, mute, ctx)
    relay_cascade_usage(
        session,
        seed.uid,
        session_id=seed.session_id,
        model=CONFIG.meta_chat_model,
        on_credits_exhausted=lambda: end_call_out_of_credits(
            ctx, session, seed.uid, flush.run
        ),
    )
    # Create idle watchdog but don't start timer yet (same fix as Gemini path)
    watchdog = watch_for_idle(ctx, session, seed.uid, flush.run, start_now=False)
    # Stack-aware voice vocabulary (§13.9): the active TTS provider's voices and
    # the real current voice, resolved exactly as ``build_cascade_session``
    # picked them (``seed.tts_voice`` else the configured default). This is what
    # replaces the Gemini-preset knowledge on a cascade (e.g. fishaudio → list
    # fishaudio voices, current = Hannah).
    import voice_catalog

    tts_id = seed.tts_id or CONFIG.meta_cascade_tts_model
    # The voice the session was ACTUALLY built with: an id invalid for this TTS
    # provider was dropped to the vendor default in ``build_cascade_session``, so
    # resolve it the same way here — otherwise "which voice are you on" would name
    # a voice that is not the one speaking.
    current_voice_id = voice_catalog.safe_tts_voice(
        tts_id, (seed.tts_voice or "").strip() or CONFIG.meta_cascade_tts_voice
    )
    rv, vocab = _voice_vocab(
        mode=voice_catalog.MODE_CASCADE,
        tts_id=tts_id,
        current_voice_id=current_voice_id,
    )
    # Boot-time accent (§13.9): on the cascade this is normally "" — the TTS
    # providers here ship fixed voices (``rv.supports_accent`` False), so the
    # accent is not routed to them and the voice is unaffected. Honoured only if
    # a cascade TTS is ever marked accent-capable in config.
    accent_block = _accent_block(rv, seed.voice_accent)
    tools = _session_tools(
        ctx,
        seed.uid,
        on_activity=watchdog.touch if watchdog else None,
        voice_pref=rv,
        guard=misheard_fragment_guard(
            window, len(window), lambda: seed.voice_language
        ),
        session_id=seed.session_id,
        window=window,
        tour_gate=tour_gate,
        dedupe=dedupe,
    )
    async def _goodbye() -> None:
        await end_call_goodbye(ctx, seed.uid, flush.run)

    # Emotion matching (2026-11-06): a session-scoped state fed by the
    # emotion read folded into the voice-actions verdict (on_emotion
    # below). It drives the per-turn context injection (_EmotionAgent)
    # and the Cartesia TTS delivery (_apply_cartesia_emotion). Flag-off:
    # no state, no callback, no agent subclass — behaviour identical to
    # before the feature.
    emotion_on = _emotion_matching_on(seed.uid)
    emotion_state = emotion_mod.EmotionState() if emotion_on else None

    def _on_emotion(read: emotion_mod.EmotionRead) -> None:
        if emotion_state is None:
            return
        emotion_state.update(read)
        logger.info(
            "emotion: read label=%s intensity=%s distress=%s session=%s",
            read.label, read.intensity, read.distress, seed.session_id or "?",
        )
        _apply_cartesia_emotion(session, emotion_state)

    # Voice-actions skill first, deterministic net as the interim backstop: a
    # clear command in a finalized user turn executes through the session's
    # own tools, exactly as in the text lane.
    relay_voice_commands(
        session, tools, dedupe,
        end_call=_goodbye,
        interpret=skills.voice_actions.interpret_voice_action,
        get_context=lambda: skills.voice_actions.read_call_context(
            get_db(), seed.uid, window
        ),
        on_emotion=_on_emotion if emotion_on else None,
        uid=seed.uid,
        session_id=seed.session_id,
    )
    relay_world_state(session, seed.uid)
    agent_kwargs: dict = {
        # The voice tool-use directive rides in the instructions (via
        # _compose_instructions) on both main voice paths: Meta Muse Spark's
        # tool-calling is probabilistic in voice and would otherwise narrate
        # an app action as done without ever firing the tool (founder voice
        # bug, 2026-10-28); Gemini Live gets the same call-before-confirm
        # discipline (founder, prod 2284).
        "instructions": _compose_instructions(
            seed.system_prompt, accent_block, vocab
        )
        + VISION_INSTRUCTIONS,
        "tools": tools,
    }
    # A guided-tour tap arrives on the data channel (§11.2b) — drive the advance.
    ctx.room.on("data_received", tour_tapped_handler(session))
    # A trailing stale user turn in the seeded history is dropped here so the
    # cascade greets/waits (like Gemini Live) instead of immediately answering a
    # message from the previous conversation (founder bug, 2026-10-27).
    cascade_ctx = _cascade_seed_chat_ctx(seed.chat_ctx)
    if cascade_ctx is not None:
        agent_kwargs["chat_ctx"] = cascade_ctx
    if emotion_on and emotion_state is not None:
        agent = _EmotionAgent(emotion_state=emotion_state, **agent_kwargs)
    else:
        agent = Agent(**agent_kwargs)
    await session.start(
        agent=agent,
        room=ctx.room,
        room_input_options=_room_input_options(video_enabled=True),
        room_output_options=RoomOutputOptions(transcription_enabled=False),
    )
    # Declare vision support from the ONE catalog source of truth
    # (``RuntimeVoices.supports_video`` — feedback item 13): a cascade
    # pipeline cannot consume video frames in livekit-agents 1.8.9, so this
    # resolves False and the client shows the Video / Screen share toggles
    # disabled with the reason — it never lets the user publish video into
    # a session whose model cannot perceive it. The track watcher still
    # runs, so secure-content detection stays correct if a share ever
    # reaches this room.
    _vision_ok = voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_CASCADE,
        tts_id=seed.tts_id,
    ).supports_video
    await _publish_voice_status(
        ctx,
        VOICE_STATUS_VISION_SUPPORTED
        if _vision_ok
        else VOICE_STATUS_VISION_UNSUPPORTED,
    )
    watch_vision_tracks(ctx, vision_supported=_vision_ok)

    # Start idle timer NOW that session is truly live (cascade path, same fix)
    if watchdog:
        watchdog.start()
    
    # Honest open-weights status (§13.9): the open-weights brain's LLM leg is a
    # scale-to-zero Modal endpoint whose first reply can take ~100s on a cold
    # start. Tell the client NOW (the room is joined) so it shows "warming up —
    # first reply can take a minute or two" and extends its no-first-response
    # budget, instead of a silent "Listening…" that looks broken.
    if (seed.brain_id or voice_catalog.BRAIN_META) == voice_catalog.BRAIN_OPEN_WEIGHTS:
        await _publish_voice_status(ctx, VOICE_STATUS_OPEN_WEIGHTS_WARMING)
    # Cold-start opener (founder behaviour, 2026-10-28): when there is prior
    # context the opener GREETS and OFFERS A CHOICE ("pick up where we left off
    # about X, or something else?") instead of resuming the old topic. That is
    # driven by the opener instruction + the has-prior/last-topic-hint signal in
    # :func:`maybe_open_conversation` (the real fix — an earlier attempt that only
    # passed an empty chat_ctx here still continued the topic, because the rolling
    # summary rides in the SYSTEM PROMPT, not chat_ctx, and the old opener prompt
    # told Ayma to "pick the thread back up"). The empty ``chat_ctx`` below stays
    # as a secondary guard so the chat LLM has no previous-turn object to answer
    # the instant it opens; the agent's own ``chat_ctx`` keeps the full window for
    # every later real turn, so "yeah, continue" still works. Gemini Live is left
    # NOT_GIVEN and gets the same greet+choice from the opener instruction.
    await _open_main_call(
        session, seed, window=window, opener_chat_ctx=llm.ChatContext.empty(),
        seed_user_turn=True,
    )


def _flush_on_non_error_close(flush: SessionFlush) -> Callable[[object], None]:
    """A session ``close`` handler that starts ``flush`` on every close EXCEPT an
    ERROR one. On an ERROR close the main-voice Meta cascade hands off to a fresh
    Gemini Live session on the same ``window`` (:func:`_arm_main_cascade_fallback`),
    so starting the flush now would snapshot a half-finished conversation; the
    fallback session flushes at its own close (and the job's shutdown callback is
    the final backstop)."""
    from livekit.agents.voice.events import CloseReason

    def _on_close(ev: object) -> None:
        if getattr(ev, "reason", None) == CloseReason.ERROR:
            return
        flush.start()

    return _on_close


def _arm_cascade_tts_error_status(
    ctx: JobContext, seed: RoomSeed, session: AgentSession
) -> None:
    """Publish an honest ``voice_status`` the FIRST time a cascade TTS leg errors,
    so the call never sits in silent dead air (§13.9).

    A cascade TTS error (e.g. an unknown-voice ``APIError``) yields no audio, and
    livekit only closes the session after several consecutive unrecoverable
    strikes (``max_unrecoverable_errors``). Until then — or forever, for an error
    the plugin flags recoverable — the user hears nothing while the UI shows
    "Listening…" (founder bug, staging 2026-11-03). On the first TTS-source error
    we tell the client ``VOICE_STATUS_TTS_ERROR`` so it shows an honest
    "reconnecting the voice" status; the runtime ERROR-close fallback
    (:func:`_arm_main_cascade_fallback`) still recovers the call to Gemini Live.
    Fires at most once (a stream of per-utterance errors must not spam the
    client)."""
    fired = False

    @session.on("error")
    def _on_error(ev) -> None:  # noqa: ANN001 - ErrorEvent
        nonlocal fired
        err = getattr(ev, "error", None)
        if fired or getattr(err, "type", "") != "tts_error":
            return
        fired = True
        logger.warning(
            "main-voice cascade TTS error uid=%s session=%s (%s) — signalling "
            "honest status; the ERROR-close fallback recovers the call",
            seed.uid, seed.session_id or "?", getattr(err, "error", err),
        )
        asyncio.create_task(_publish_voice_status(ctx, VOICE_STATUS_TTS_ERROR))


def _arm_main_cascade_fallback(
    ctx: JobContext,
    seed: RoomSeed,
    session: AgentSession,
    *,
    flush: SessionFlush,
    window: list[Turn],
    route: str,
    use_inference: bool,
    voice_provider: str,
) -> None:
    """Fall a *running* main-voice Meta cascade back to Gemini Live if it dies
    mid-call (same pattern as :func:`_arm_practice_cascade_fallback`).

    A leg (STT/LLM/TTS) can still fail at runtime — e.g. the Meta LLM 404s — and
    livekit-agents then closes the session with ``CloseReason.ERROR``, which
    would otherwise leave the caller in dead air. On that close we rebuild the
    full Gemini Live main session on the SAME room, reusing the shared
    ``flush``/``window`` so the conversation so far carries into its persistence.
    Fires at most once: a Gemini fallback that also errors just closes."""
    from livekit.agents.voice.events import CloseReason

    fired = False

    @session.on("close")
    def _on_close(ev) -> None:  # noqa: ANN001 - CloseEvent
        nonlocal fired
        if fired or getattr(ev, "reason", None) != CloseReason.ERROR:
            return
        fired = True
        err = getattr(ev, "error", None)
        logger.warning(
            "main-voice fallback uid=%s session=%s — Meta cascade failed at "
            "runtime (%s), switching to Gemini Live",
            seed.uid, seed.session_id or "?",
            getattr(err, "error", err),
        )
        if err is not None:
            capture_exception(getattr(err, "error", err))

        async def _switch() -> None:
            try:
                await _start_main_gemini_session(
                    ctx, seed,
                    flush=flush, window=window, route=route,
                    use_inference=use_inference, voice_provider=voice_provider,
                )
            except Exception as exc:  # noqa: BLE001 - fallback must not crash the job
                logger.exception("main-voice Gemini Live fallback failed")
                capture_exception(exc)

        asyncio.create_task(_switch())


def relay_practice_coach(
    ctx: JobContext,
    session: AgentSession,
    *,
    uid: str,
    session_id: str,
    persona_name: str,
    persona_gender: str,
    target_uid: str,
) -> None:
    """Practice Date voice live coach (hackathon B).

    As the user talks to the simulated persona, surface an out-of-character
    coaching nudge to the USER over the data channel (``practice_coach``) — a
    side text hint the client shows separately, never spoken by the persona, so
    the roleplay immersion is preserved. Each finalized turn is also appended to
    the practice session store so the end-of-call debrief
    (``POST /practice/debrief``) has the transcript.

    Reuses ``practice_date.coach_hint`` (best-effort, never raises). The coach
    context is rebuilt from ``persona_name`` / ``persona_gender`` alone via
    ``persona_context_for_coach`` — the worker never re-reads the target's
    profile, so no never-load data path is opened here. The gender is carried so
    the coach refers to the match with the right pronouns (founder bug
    2026-10-27: a she/her persona was coached as "him"). Imports ``practice_core``
    (not ``practice_date``) because the agent worker's runtime carries no
    fastapi — the core holds the practice primitives with no web-stack deps."""
    import practice_core

    db = get_db()
    coach_ctx = practice_core.persona_context_for_coach(
        persona_name, target_uid, persona_gender
    )
    turns: list[dict] = []

    def _persist(turn: dict) -> None:
        if not (uid and session_id):
            return
        try:
            practice_core.append_turns(db, uid, session_id, [turn])
        except Exception:  # noqa: BLE001 - persistence is best-effort
            logger.warning("practice voice: append turn failed", exc_info=True)

    @session.on("user_input_transcribed")
    def _on_user(ev: UserInputTranscribedEvent) -> None:
        text = (ev.transcript or "").strip()
        if not ev.is_final or not text:
            return
        turn = {"role": practice_core.ROLE_USER, "text": text}
        turns.append(turn)

        async def _coach() -> None:
            await asyncio.to_thread(_persist, turn)
            hint = await practice_core.coach_hint(coach_ctx, list(turns), uid=uid)
            if hint:
                _publish_transcript(ctx, TOPIC_PRACTICE_COACH, hint, True)

        asyncio.create_task(_coach())

    @session.on("conversation_item_added")
    def _on_item(ev: ConversationItemAddedEvent) -> None:
        if getattr(ev.item, "role", None) != "assistant":
            return
        text = (ev.item.text_content or "").strip()
        if not text:
            return
        turn = {"role": practice_core.ROLE_MATCH, "text": text}
        turns.append(turn)
        asyncio.create_task(asyncio.to_thread(_persist, turn))


async def _run_practice_session(ctx: JobContext, seed: RoomSeed) -> None:
    """One Practice Date voice session (hackathon B).

    The room was seeded by ``POST /practice/voice/start`` with a persona system
    prompt built ONLY from the match's viewer-visible profile
    (``practice_date.build_persona_context`` — the same query-level never-load
    exclusions as the text path). The persona speaks as that person and deflects
    extraction in-character. Deliberately smaller than a normal Ayma call:

    * No session tools — the persona cannot drive the app or run Ayma's skills.
    * No ``SessionFlush`` — a simulated conversation is never persisted to the
      user's ``raw_turns`` nor ingested into their wiki memory.
    * A side-channel live coach (:func:`relay_practice_coach`) nudges the user
      out-of-character and persists the transcript for the debrief.

    Voice model path: Gemini Live by default. When ``LLM_PROVIDER_VOICE=meta``
    (``CONFIG.llm_provider_voice``) the session instead runs as a LiveKit
    **Meta cascade** — LiveKit Inference STT -> Meta Muse Spark LLM (OpenAI-
    compatible Meta Model API) -> Inworld TTS via the LiveKit Inference gateway,
    with local Silero VAD (:func:`build_meta_cascade_session`). (Meta serves no
    working REST STT, so only the LLM leg runs on Meta — the hackathon "runs on
    Meta" story.) Two fallbacks keep a flip from ever taking practice voice
    down: if the cascade can't be *built* (no ``META_API_KEY``, missing plugin)
    the session starts on Gemini Live instead; and if a built cascade dies at
    *runtime* (an STT/LLM/TTS error closes it) it switches to a fresh Gemini
    Live session on the same room (:func:`_arm_practice_cascade_fallback`). The
    default voice behaviour is unchanged, and only the persona/coaching CONTENT
    comes from the practice module.

    The simulated match greets first on both paths — they "pick up the phone"
    and open in character (``prompts/practice_greeting.md``) rather than waiting
    for the user. Voice tokens are metered either way (Gemini Live via
    :func:`relay_token_usage`, the cascade LLM via :func:`relay_cascade_usage`)."""
    from llm_provider import PROVIDER_META

    if CONFIG.llm_provider_voice == PROVIDER_META:
        try:
            session = build_meta_cascade_session(
                seed.voice_name,
                seed.voice_language,
                _cascade_tts_voice_for_gender(seed.persona_gender),
            )
        except Exception as exc:  # noqa: BLE001 - never take practice voice down
            logger.warning(
                "Meta voice cascade unavailable (%s: %s) — falling back to "
                "Gemini Live", type(exc).__name__, exc,
            )
            capture_exception(exc)
        else:
            logger.info(
                "practice-voice Meta cascade uid=%s session=%s stt=%s llm=%s tts=%s",
                seed.uid, seed.session_id or "?", CONFIG.meta_cascade_stt_model,
                CONFIG.meta_chat_model, CONFIG.meta_cascade_tts_model,
            )
            _arm_practice_cascade_fallback(ctx, seed, session)
            await _start_practice_session(
                ctx, seed, session, meta_cascade=True, use_inference=False
            )
            return

    session, use_inference = _build_practice_gemini_session(seed)
    await _start_practice_session(
        ctx, seed, session, meta_cascade=False, use_inference=use_inference
    )


def _build_practice_gemini_session(seed: RoomSeed) -> tuple[AgentSession, bool]:
    """Build the Gemini Live practice ``AgentSession`` — the default voice path
    and the Meta-cascade fallback. Returns the session and whether it routes
    through LiveKit Inference (so usage is metered against the right provider).

    The simulated match speaks in a voice matching their profile gender: a
    female persona gets a feminine-leaning preset, male a masculine one
    (``voices.voice_for_gender``). Non-binary / unknown gender returns ``""`` and
    falls back to the user's own ``voice_name`` preference, then the configured
    default (``build_realtime_model``) — never a wrong-gender guess."""
    route = llm_routing.route_for("voice", uid=seed.uid)
    use_inference = route == "inference"
    voice = voices.voice_for_gender(seed.persona_gender) or seed.voice_name
    session = AgentSession(
        llm=build_realtime_model(voice, seed.voice_language, route=route),
        allow_interruptions=True,
    )
    return session, use_inference


async def _start_practice_session(
    ctx: JobContext,
    seed: RoomSeed,
    session: AgentSession,
    *,
    meta_cascade: bool,
    use_inference: bool,
) -> None:
    """Wire the transcript/state/usage relays and live coach onto a practice
    session, start it on the room, and have the simulated match greet first."""
    relay_transcripts(ctx, session)
    relay_agent_state(ctx, session)
    if meta_cascade:
        relay_cascade_usage(
            session, seed.uid, session_id=seed.session_id,
            model=CONFIG.meta_chat_model,
        )
    else:
        relay_token_usage(
            session, seed.uid, session_id=seed.session_id, ctx=ctx,
            inference=use_inference,
        )
    relay_practice_coach(
        ctx,
        session,
        uid=seed.uid,
        session_id=seed.session_id,
        persona_name=seed.persona_name,
        persona_gender=seed.persona_gender,
        target_uid=seed.target_uid,
    )
    # No tools, no chat_ctx: the persona only knows the whitelisted facts the
    # seeded prompt carries.
    agent = Agent(instructions=seed.system_prompt)
    await session.start(
        agent=agent,
        room=ctx.room,
        room_input_options=_room_input_options(),
        room_output_options=RoomOutputOptions(transcription_enabled=False),
    )
    # The simulated match "picks up the phone" and opens in character instead of
    # waiting for the user (they are rehearsing their opener either way). On the
    # Meta cascade (text chat LLM) a greeting with no prior user turn would reach
    # the OpenAI-compatible gateway as a system-only message list and 400, so a
    # benign synthetic user turn is seeded; the Gemini Live / Inference realtime
    # path does not hit that request shape and is left unseeded.
    greeting_kwargs: dict = {"instructions": load_practice_greeting()}
    if meta_cascade:
        greeting_kwargs["user_input"] = load_voice_session_seed()
    try:
        await session.generate_reply(**greeting_kwargs)
    except Exception:  # noqa: BLE001 - a missed greeting shouldn't kill the call
        logger.exception("practice greeting failed")


def _arm_practice_cascade_fallback(
    ctx: JobContext, seed: RoomSeed, session: AgentSession
) -> None:
    """Fall a *running* Meta cascade back to Gemini Live if it dies mid-call.

    The cascade builds fine, but a leg (STT/LLM/TTS) can still fail at runtime
    — e.g. the Meta LLM 404s — and livekit-agents then closes the session with
    ``CloseReason.ERROR``, which would otherwise leave the caller in dead air.
    On that close we start a fresh Gemini Live practice session on the SAME
    room so the user keeps a working call. Fires at most once: a Gemini
    fallback that also errors just closes (no further switch)."""
    from livekit.agents.voice.events import CloseReason

    fired = False

    @session.on("close")
    def _on_close(ev) -> None:  # noqa: ANN001 - CloseEvent
        nonlocal fired
        if fired or getattr(ev, "reason", None) != CloseReason.ERROR:
            return
        fired = True
        err = getattr(ev, "error", None)
        logger.warning(
            "practice-voice fallback uid=%s session=%s — Meta cascade failed at "
            "runtime (%s), switching to Gemini Live",
            seed.uid, seed.session_id or "?",
            getattr(err, "error", err),
        )
        if err is not None:
            capture_exception(getattr(err, "error", err))

        async def _switch() -> None:
            try:
                gemini, use_inference = _build_practice_gemini_session(seed)
                await _start_practice_session(
                    ctx, seed, gemini, meta_cascade=False,
                    use_inference=use_inference,
                )
            except Exception as exc:  # noqa: BLE001 - fallback must not crash the job
                logger.exception("practice-voice Gemini Live fallback failed")
                capture_exception(exc)

        asyncio.create_task(_switch())


# A one-line last-topic hint for the opener is capped at this many characters so
# the opener gets just enough to reference ("where we left off about X") without
# the full prior turn being dumped back into the opening generation.
_OPENER_HINT_MAX_CHARS = 200


def _opener_prior_context(seed_turns: list[Turn]) -> tuple[bool, str]:
    """Whether this caller has a prior conversation the opener can offer to pick
    back up, and a short one-line hint at the last topic (founder behaviour,
    2026-10-28).

    ``has_prior`` is True when the seeded window carries any real (non-empty)
    prior turn; the hint is the most recent such turn's text, whitespace-collapsed
    and truncated to :data:`_OPENER_HINT_MAX_CHARS`. The hint is only a reference
    for the greeting ("want to pick up where we left off about …?") — the FULL
    context still rides in the agent's own ``chat_ctx`` for every later turn, so
    if the caller says "yeah, continue" it works; the opener just must not dump or
    continue that context itself."""
    real = [t for t in seed_turns if t.text.strip()]
    if not real:
        return False, ""
    hint = " ".join(real[-1].text.split()).strip()
    if len(hint) > _OPENER_HINT_MAX_CHARS:
        hint = hint[:_OPENER_HINT_MAX_CHARS].rstrip() + "…"
    return bool(hint), hint


def _profile_first_name(db, uid: str) -> str:
    """The caller's first name from ``users/{uid}/profile/main``, or "".

    Sync Firestore read (call via ``asyncio.to_thread``). Never raises: a
    missing profile, a blank name, or a read error all degrade to the
    nameless greeting rather than costing the opener."""
    try:
        data = schema.profile_doc(db, uid).get().to_dict() or {}
        parts = str(data.get(schema.PF_NAME) or "").split()
    except Exception:  # noqa: BLE001 - the greeting must survive a bad read
        return ""
    return parts[0] if parts else ""


async def _attempt_voice_say(
    session: AgentSession, text: str
) -> BaseException | None:
    """Speak one literal line via ``session.say``; None on success, the
    error on failure.

    The same swallowed-failure discipline as opener ``generate_reply``
    attempts (staging voice-silence audit, 2026-11-02): awaiting a LiveKit
    ``SpeechHandle`` never raises — a synthesis failure is only exposed via
    ``handle.exception()`` — so check both: a synchronous raise (session
    not running / closing, or a raising test fake) AND the returned
    handle's ``exception()``. A None handle (some test fakes) counts as
    spoken."""
    try:
        handle = session.say(text)
        if handle is not None:
            await handle
    except Exception as exc:  # noqa: BLE001 - any failure fails this attempt only
        return exc
    get_error = getattr(handle, "exception", None)
    if not callable(get_error):
        return None
    try:
        return get_error()
    except Exception as exc:  # noqa: BLE001 - an unreadable handle fails it too
        return exc


async def _attempt_voice_reply(
    session: AgentSession, **kwargs: object
) -> BaseException | None:
    """Fire one ``generate_reply``; None on success, the error on failure.

    A try/except around the await alone can NEVER see a generation failure:
    awaiting a LiveKit ``SpeechHandle`` never raises - the error is swallowed
    and only exposed via ``handle.exception()`` (livekit-agents 1.8.9
    ``speech_handle.py``; staging voice-silence audit, 2026-11-02). So check
    both: a synchronous raise (session not running / closing, or a raising
    test fake) AND the returned handle's ``exception()``."""
    try:
        handle = session.generate_reply(**kwargs)  # type: ignore[arg-type]
        await handle
    except Exception as exc:  # noqa: BLE001 - any failure fails this attempt only
        return exc
    get_error = getattr(handle, "exception", None)
    if not callable(get_error):
        return None
    try:
        error = get_error()
    except Exception as exc:  # noqa: BLE001 - an unreadable handle fails it too
        return exc
    return error


async def maybe_open_conversation(
    session: AgentSession,
    seed: RoomSeed,
    *,
    window: list[Turn],
    grace_seconds: float | None = None,
    opener_chat_ctx: NotGivenOr[object] = NOT_GIVEN,
    seed_user_turn: bool = False,
) -> bool:
    """Ayma speaks first on a normal call when the caller stays silent.

    Waits the grace window after the session is live; if the caller has not
    started speaking (user_state_changed -> speaking, or any
    user_input_transcribed) and nobody has spoken in the room, she opens
    with the name greeting below. Returns True if the greeting fired.
    Skipped for the welcome room (it has its own greeting) or when the
    opener is disabled by config. Runs at most once per session by
    construction.

    The greeting itself (founder ruling, 2026-11-03 23:06 PT): a FRESH
    session opens with JUST a short name greeting — "Hey {first name}." —
    and nothing about the previous conversation: no recap, no "pick up
    where we left off" choice, no answer to a dangling last message. This
    supersedes the 2026-10-28 greet+choice opener and the 2026-11-02
    dangling-answer opener FOR THE OPENING LINE ONLY. The full seeded
    context still rides in the agent's own ``chat_ctx`` for every later
    turn, so anything the caller wants to pick up is one turn away — they
    raise it; the opener never does. The line is spoken via
    ``session.say`` (the literal words, the same mechanism as the
    ack-gate's not-confirmed line) so no model can embellish it into a
    recap, and it is a status greeting, not an action claim, so the
    ack-gating contract is untouched. On a realtime session whose model
    cannot say() (Gemini Live), say() raises instead — the line then
    rides ``generate_reply`` under a say-exactly-this instruction (see
    the fallback in the body), because the app produces no first
    response — and holds the caller's mic — until the agent speaks. A mid-call RECONNECT continuation
    never reaches here — it returns from :func:`_open_main_call` on the
    claim branch — so its "I'm back" line and in-call continuity are
    unaffected.

    ``opener_chat_ctx`` / ``seed_user_turn`` are accepted for signature
    compatibility with the starters and are now inert: the greeting is a
    literal ``say``, not a ``generate_reply``, so there is no LLM request
    to scope to a history-free context or to seed a user turn into.
    """
    # Opener observability (2026-11-02): today a silent stall and a deliberately
    # skipped opener look identical in the logs. Log, at INFO, whether the opener
    # FIRED or was SKIPPED (+ why) and — once fired — whether the say
    # COMPLETED or errored, tagged with the brain id. This powers the honest
    # open-weights status and gives a first-response trace on every path.
    brain = seed.brain_id or seed.realtime_model_id or "gemini-live"
    grace = (
        CONFIG.voice_opener_grace_seconds if grace_seconds is None else grace_seconds
    )
    if grace <= 0 or seed.greeting_instructions:
        logger.info(
            "voice opener SKIPPED brain=%s reason=%s session=%s", brain,
            "disabled" if grace <= 0 else "has_greeting", seed.session_id or "?",
        )
        return False

    user_started = asyncio.Event()

    @session.on("user_state_changed")
    def _on_user_state(ev) -> None:  # noqa: ANN001 - UserStateChangedEvent
        if getattr(ev, "new_state", "") == "speaking":
            user_started.set()

    @session.on("user_input_transcribed")
    def _on_user_input(ev) -> None:  # noqa: ANN001 - UserInputTranscribedEvent
        user_started.set()

    seeded = len(window)
    try:
        await asyncio.wait_for(user_started.wait(), timeout=grace)
        logger.info(
            "voice opener SKIPPED brain=%s reason=caller_spoke_first session=%s",
            brain, seed.session_id or "?",
        )
        return False
    except asyncio.TimeoutError:
        pass
    if user_started.is_set() or _has_new_turns(window, seeded):
        logger.info(
            "voice opener SKIPPED brain=%s reason=activity_during_grace session=%s",
            brain, seed.session_id or "?",
        )
        return False

    first = ""
    if seed.uid:
        first = await asyncio.to_thread(_profile_first_name, get_db(), seed.uid)
    greeting = f"Hey {first}." if first else "Hey there."
    logger.info(
        "voice opener FIRED kind=name_greeting brain=%s session=%s — "
        "awaiting say", brain, seed.session_id or "?",
    )
    say_error = await _attempt_voice_say(session, greeting)
    if say_error is not None:
        # A realtime session with no TTS whose model cannot say() (Gemini
        # Live: the google plugin leaves capabilities.supports_say False)
        # raises RuntimeError from say() - the literal line then rides
        # generate_reply under a say-exactly-this instruction instead, the
        # same mechanism the welcome greeting and the reconnect line
        # already use on realtime. This fallback is load-bearing, not
        # cosmetic: the app holds the caller's mic until the agent's
        # first genuine response lands, so an opener that produces
        # nothing leaves a fresh realtime call stuck on "Connecting..."
        # until the app's first-response guard tears it down (founder
        # bug, 2026-11-03 - fresh Gemini Live starts never connected).
        logger.warning(
            "voice opener say ERRORED kind=name_greeting brain=%s "
            "session=%s err=%s - falling back to generate_reply",
            brain, seed.session_id or "?", say_error,
        )
        reply_error = await _attempt_voice_reply(
            session, instructions=load_voice_verbatim_line(greeting)
        )
        if reply_error is not None:
            # logger.error, not logger.exception: the error usually
            # arrives via handle.exception(), outside any except block,
            # so there is no active traceback to attach - the carried
            # error string is the signal.
            logger.error(
                "voice opener generate_reply ERRORED kind=name_greeting "
                "brain=%s session=%s err=%s",
                brain, seed.session_id or "?", reply_error,
            )
            return False
    logger.info(
        "voice opener COMPLETED kind=name_greeting brain=%s session=%s",
        brain, seed.session_id or "?",
    )
    return True


# Imported lazily by the voice/inference stack or the session-end flush;
# measured blocking the job's event loop for 3-6 s on first use in production
# (2026-10-25 "event loop blocked ... importing" warnings), right at call start
# and again during the end-of-call flush. Imported once per process instead.
_PREWARM_MODULES = (
    "google.auth.compute_engine.credentials",
    "openai.types.realtime",
    "livekit.agents.inference.realtime.gpt_live",
    "wiki_ingest",
    "backfill_ops",
)


def prewarm(proc: JobProcess) -> None:
    """Worker prewarm hook: runs in each job process before it takes a job."""
    import importlib

    for name in _PREWARM_MODULES:
        try:
            importlib.import_module(name)
        except Exception:  # noqa: BLE001 - a missing optional module only costs latency
            logger.warning("prewarm import of %s failed", name, exc_info=True)


def _this_runtime_cloud() -> str:
    """Which cloud THIS worker process is: ``livekit`` when ``AGENT_RUNTIME`` is
    ``livekit`` (the LiveKit-Cloud-hosted deployment), else ``cloudrun`` (GCP
    Cloud Run — the default and all of production)."""
    return "livekit" if CONFIG.agent_runtime == "livekit" else "cloudrun"


def _room_target_cloud(metadata: str | None) -> str:
    """The ``voice_agent_cloud`` marker ``POST /bootstrap`` left on the room
    metadata, or ``cloudrun`` when absent/unreadable — so a room with no marker
    (and any room whose metadata can't be parsed yet) is served by Cloud Run
    exactly as today."""
    raw = (metadata or "").strip()
    if not raw:
        return "cloudrun"
    try:
        target = str(json.loads(raw).get("voice_agent_cloud", "")).strip()
    except (ValueError, AttributeError):
        return "cloudrun"
    return target if target in ("cloudrun", "livekit") else "cloudrun"


async def _request_fnc(req: JobRequest) -> None:
    """Dual-cloud dispatch guard (ARCHITECTURE §1.1).

    LiveKit still offers EVERY new room to the Cloud Run worker's automatic
    dispatch — including rooms explicitly routed to the LiveKit-Cloud-hosted
    worker (``agent_name``). Without this guard both deployments would join a
    ``livekit``-routed room and contend. Each worker accepts only the rooms
    whose ``voice_agent_cloud`` marker matches its own runtime; the other
    declines. A room with no marker is ``cloudrun`` (unchanged production).

    Fail-open: any error reading the marker ends in ``accept`` on the Cloud Run
    worker so a guard bug can never take production voice down; the LiveKit
    worker (explicit dispatch only ever receives its own rooms) also accepts.

    Before the cloud guard, a STAGING/PROD environment guard (ARCHITECTURE
    §1.1a) runs first: staging and prod share one LiveKit project, so each
    worker declines rooms whose name belongs to the other environment
    (``room_env_mismatch``) BEFORE accepting — the prod worker never joins or
    writes for a ``ayma-staging-*`` room, which on 2026-11-01 corrupted prod
    Firestore. This decision is by room NAME and is default-safe, so it holds
    even if the cloud-marker read below would otherwise fail open to accept."""
    room_name = req.room.name if req.room else None
    if room_env_mismatch(room_name):
        logger.info(
            "declining room %s: wrong environment (this_agent_serves_staging=%s)",
            room_name or "?", this_agent_serves_staging(),
        )
        await req.reject()
        return
    mine = _this_runtime_cloud()
    try:
        target = _room_target_cloud(req.room.metadata if req.room else None)
    except Exception:  # noqa: BLE001 - never drop a job on a guard error
        logger.exception("dispatch guard failed to read room target; accepting")
        await req.accept()
        return
    if target != mine:
        logger.info(
            "declining room %s: target=%s this=%s",
            req.room.name if req.room else "?", target, mine,
        )
        await req.reject()
        return
    await req.accept()


def worker_options() -> WorkerOptions:
    # Explicit agent dispatch on the LiveKit-Cloud-hosted worker (it registers
    # under this name and is dispatched only to rooms that request it);
    # AUTOMATIC dispatch (no agent_name) on Cloud Run, exactly as production.
    agent_name = (
        CONFIG.agent_name_livekit if CONFIG.agent_runtime == "livekit" else ""
    )
    return WorkerOptions(
        entrypoint_fnc=entrypoint,
        prewarm_fnc=prewarm,
        request_fnc=_request_fnc,
        agent_name=agent_name,
        # The Cloud Run port ($PORT) belongs to AymaAgentServer's keep-alive
        # server (routes can't be added to the worker's own health server,
        # which is built and started inside AgentServer.run), so the worker's
        # health server binds an internal port.
        port=int(os.getenv("AGENT_WORKER_HEALTH_PORT", "8081")),
        # Scale-to-zero service — keep the pre-forked job pool tiny.
        num_idle_processes=1,
        drain_timeout=int(os.getenv("AGENT_DRAIN_TIMEOUT", "30")),
        # How long a job process gets, after the room closes, to finish its
        # shutdown callbacks (the SessionFlush memory write: raw_turns, wiki
        # ingest, summary) before the worker SIGUSR1-kills it. The library
        # default of 10 s was killing every call's flush mid-ingest
        # ("process did not exit in time, killing process", 2026-10-25).
        # The instance runs --no-cpu-throttling, so the CPU is there to use.
        shutdown_process_timeout=float(
            os.getenv("AGENT_SHUTDOWN_PROCESS_TIMEOUT", "60")
        ),
    )


class AymaAgentServer(AgentServer):
    """The LiveKit worker plus the per-call keep-alive server on ``$PORT``.

    On SIGTERM the CLI calls ``drain()``: livekit-agents marks the worker
    unavailable for new jobs and waits for the active ones. Cloud Run kills
    the container 10 s after SIGTERM (not configurable), so a drain can't
    save a long call; the keep-alive request is what stops Cloud Run from
    sending SIGTERM to an instance with a live call. A drain that still finds
    active calls is logged and reported to Sentry."""

    _keepalive_server: KeepAliveServer | None = None

    async def run(self, *, devmode: bool = False, unregistered: bool = False) -> None:
        self._keepalive_server = KeepAliveServer(
            "0.0.0.0", int(os.getenv("PORT", "8080"))
        )
        await self._keepalive_server.start()
        await super().run(devmode=devmode, unregistered=unregistered)

    async def drain(self, timeout: NotGivenOr[int | None] = NOT_GIVEN) -> None:
        active = len(self.active_jobs)
        holds = self._keepalive_server.active_holds if self._keepalive_server else 0
        if active:
            logger.warning(
                "shutdown signal with active calls: active_jobs=%d "
                "keepalive_holds=%d; draining (Cloud Run kills in 10 s)",
                active, holds,
            )
            capture_message(
                "ayma-agent got SIGTERM with active calls",
                tags={"active_jobs": str(active), "keepalive_holds": str(holds)},
            )
        else:
            logger.info("shutdown signal with no active calls; draining")
        await super().drain(timeout)

    async def aclose(self) -> None:
        try:
            await super().aclose()
        finally:
            if self._keepalive_server is not None:
                await self._keepalive_server.aclose()


if __name__ == "__main__":
    cli.run_app(AymaAgentServer.from_server_options(worker_options()))
