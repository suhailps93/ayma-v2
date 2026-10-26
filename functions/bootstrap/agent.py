"""Ayma LiveKit voice agent worker (ARCHITECTURE §1.1, §10.1, §1.7 step 3).

A separate Cloud Run deployable from the Main API (`main.py`). It holds an
outbound connection to LiveKit Cloud waiting for job dispatch; on dispatch it
joins the room and bridges the participant's audio to a Gemini Live session and
back.

Current scope:

* base persona instructions (shared `persona.md`, same character as `/chat`),
* default voice from `config.py`,
* Gemini Live's native (server-side) turn detection — no client VAD; the
  server's automatic activity detection is tuned conservatively against
  false triggers (see ``_turn_detection_config``), env-overridable,
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

from google.genai import types  # noqa: E402
from livekit.agents import (  # noqa: E402 - must follow the dotenv load
    Agent,
    AgentSession,
    AgentStateChangedEvent,
    ConversationItemAddedEvent,
    JobContext,
    JobProcess,
    MetricsCollectedEvent,
    RoomOutputOptions,
    UserInputTranscribedEvent,
    WorkerOptions,
    cli,
    llm,
)
from livekit.agents.metrics import RealtimeModelMetrics  # noqa: E402
from livekit.plugins.google.realtime import RealtimeModel  # noqa: E402

import context_opt  # noqa: E402
from idle_watchdog import IdleWatchdog  # noqa: E402
import llm_routing  # noqa: E402
import token_ledger  # noqa: E402
from config import CONFIG  # noqa: E402
from monitoring import capture_exception, init_sentry  # noqa: E402

init_sentry("ayma-agent")  # no-op without SENTRY_DSN
from db import get_db  # noqa: E402
from post_turn import persist_and_ingest  # noqa: E402
from prompt import (  # noqa: E402
    compose_system_prompt,
    load_voice_opener,
    voice_swap_confirm,
    voice_swap_note,
)
import skills  # noqa: E402
import voices  # noqa: E402
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
# distinguishes a deliberate, graceful stop (currently only "out_of_credits",
# §F3 mid-call credit cap) from an ordinary dropped connection so the client
# can show the actionable "reload credits" affordance (`cappedError` in
# `voice_session_controller.dart`) instead of a generic "connection dropped"
# error. Payload: {"reason": "out_of_credits"}.
TOPIC_CALL_ENDING = "call_ending"
# `call_ending` reason sent when there was no activity for the idle window
# (`CONFIG.voice_idle_timeout_seconds`).
REASON_IDLE_TIMEOUT = "idle_timeout"
# Ayma was told to "shut up" (or called back by name) — published on every
# muted<->unmuted transition so the client can show an "Ayma is quiet" chip
# instead of a call that looks broken. Payload: {"muted": bool}.
TOPIC_AGENT_MUTE = "agent_mute"

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
# Measured problem (production 2026-09-26, gemini-3.8-live, call
# s-t83myxsFsvQLhbb_s64jTL): 5 of 15 billed turns in a ~3-minute call returned
# out=6 tokens — essentially empty replies, three of them seconds apart —
# classic VAD false triggers (breaths / noise / short pauses committing a
# "user turn" with no content). Each such turn still re-bills the entire
# resident input context (~9.2k tokens at that point): ~46k tokens (~$0.14, a
# third of the call) spent on turns where the model said nothing.
#
# Gemini Live's server defaults are START_SENSITIVITY_HIGH +
# END_SENSITIVITY_HIGH (verified in the installed google-genai
# StartSensitivity/EndSensitivity enum docs) — the most trigger-happy profile.
# The knobs below tune the *server's* automatic activity detection via
# `realtime_input_config.automatic_activity_detection`, which the installed
# livekit plugin (1.7.1) passes verbatim into the Live session setup
# (realtime_api.py `conf.realtime_input_config = ...`). No client-side VAD or
# transcript heuristics — configuration only, so real user speech is never
# eaten by our own cleverness. `activity_handling` is deliberately left unset:
# the plugin's interrupt() path checks it, and the default
# START_OF_ACTIVITY_INTERRUPTS is the barge-in behavior we want.
#
# Every knob is env-tunable on ayma-agent (no code deploy to adjust). The
# literal value "default" (or empty) leaves that field unset so the server
# default applies; setting all four to "default" — or
# GEMINI_LIVE_TURN_DETECTION_TUNING=off — restores the exact pre-tuning setup
# (no realtime_input_config sent at all).
#
#   GEMINI_LIVE_TURN_DETECTION_TUNING  on|off        default on
#   GEMINI_LIVE_START_SENSITIVITY      low|high|default   default "low":
#       breaths and background noise are less likely to open a user turn at
#       all (server default is HIGH).
#   GEMINI_LIVE_END_SENSITIVITY        low|high|default   default "default"
#       (server HIGH): end-of-speech eagerness is left alone —
#       silence_duration_ms below is the direct, bounded knob for early
#       commits, while END_SENSITIVITY_LOW adds unbounded extra lag on top.
#   GEMINI_LIVE_PREFIX_PADDING_MS      int ms|default     default 300:
#       detected speech must persist ~0.3s before start-of-speech commits, so
#       a breath, click, or cough doesn't open (and bill) a turn. Audio is
#       buffered server-side, so nothing said is lost — commit is just
#       confirmed later.
#   GEMINI_LIVE_SILENCE_DURATION_MS    int ms|default     default 700:
#       ~0.7s of non-speech before end-of-speech commits — mid-sentence
#       thinking pauses no longer cut the caller off / commit an empty tail
#       turn, while replies still start well under a second after the caller
#       actually finishes. Raise toward 1000 if callers feel cut off; lower
#       toward 500 if Ayma feels slow to answer.

_START_SENSITIVITY = {
    "low": types.StartSensitivity.START_SENSITIVITY_LOW,
    "high": types.StartSensitivity.START_SENSITIVITY_HIGH,
}
_END_SENSITIVITY = {
    "low": types.EndSensitivity.END_SENSITIVITY_LOW,
    "high": types.EndSensitivity.END_SENSITIVITY_HIGH,
}


def _env_choice(name: str, default: str, allowed: dict) -> object | None:
    """Read a low/high/default env knob; None means leave the field unset."""
    raw = os.getenv(name, default).strip().lower()
    if raw in ("", "default"):
        return None
    if raw in allowed:
        return allowed[raw]
    logger.warning(
        "%s=%r is not one of %s|default — using %r",
        name, raw, "|".join(allowed), default,
    )
    return allowed.get(default)


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


def _turn_detection_config() -> types.RealtimeInputConfig | None:
    """Build the tuned automatic-activity-detection config (or None).

    None (tuning off, or every field resolved to "default") means the session
    setup carries no ``realtime_input_config`` at all — byte-identical to the
    pre-tuning behavior.
    """
    if os.getenv("GEMINI_LIVE_TURN_DETECTION_TUNING", "on").strip().lower() in (
        "off", "false", "0",
    ):
        return None
    aad = types.AutomaticActivityDetection(
        start_of_speech_sensitivity=_env_choice(
            "GEMINI_LIVE_START_SENSITIVITY", "low", _START_SENSITIVITY
        ),
        end_of_speech_sensitivity=_env_choice(
            "GEMINI_LIVE_END_SENSITIVITY", "default", _END_SENSITIVITY
        ),
        prefix_padding_ms=_env_ms("GEMINI_LIVE_PREFIX_PADDING_MS", 300),
        silence_duration_ms=_env_ms("GEMINI_LIVE_SILENCE_DURATION_MS", 700),
    )
    if aad == types.AutomaticActivityDetection():
        return None
    return types.RealtimeInputConfig(automatic_activity_detection=aad)


def build_inference_realtime_model(voice: str):
    """Gemini Live through LiveKit Inference (``VOICE_PROVIDER=inference``).

    ``inference.RealtimeModel`` speaks the OpenAI realtime protocol to the
    gateway, which fronts ``google/gemini-3.8-live``. Only the knobs that
    protocol carries are passed: the voice preset, and server-VAD padding /
    silence taken from the same env tuning as the direct path. Live probes
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
        model=CONFIG.inference_live_model,
        voice=voice,
        turn_detection=ServerVad(**vad),
    )


def build_realtime_model(
    voice_name: str | None = None,
    language: str | None = None,
    route: str | None = None,
) -> RealtimeModel:
    """Construct the Gemini Live model.

    Auth mirrors the Main API (`gemini.py`): Vertex AI with the Cloud Run
    runtime identity when ``USE_VERTEX`` is set, otherwise the Gemini Developer
    API with ``GOOGLE_API_KEY`` from the environment. The model id comes only
    from ``config.py`` (AGENTS.md); ``voice_name`` is the user's
    ``ayma_voice_name`` preference (§13.3) when set and valid, else the
    ``config.py`` default. ``language`` is their ``ayma_voice_language``
    (BCP-47) default — the system prompt still lets Ayma follow the caller into
    another language mid-call. ``route`` (``"vertex"`` | ``"inference"``) is the
    already-decided provider for this call (see :func:`_run_session`); omitted,
    it is resolved here without a uid.
    """
    import voices

    voice = voice_name if voice_name and voices.is_valid_voice(voice_name) \
        else CONFIG.gemini_live_voice

    if (route or llm_routing.route_for("voice")) == "inference":
        return build_inference_realtime_model(voice)

    dev_api = CONFIG.gemini_live_use_dev_api
    model = (
        CONFIG.gemini_live_dev_model if dev_api else CONFIG.gemini_live_model
    )
    kwargs: dict[str, object] = {
        "model": model,
        "voice": voice,
        "temperature": 0.9,
        # Native Gemini Live transcription of both sides of the call (§1.6,
        # §1.7 step 11) — explicit rather than relying on the plugin default.
        #
        # Transcription audit (cost program 2026-09-26, Phase 1): BOTH sides
        # are genuinely consumed downstream, so neither can be gated off —
        # input transcription feeds `user_input_transcribed` (the client's
        # live user captions via `relay_transcripts`, the "shut up" mute
        # triggers via `relay_mute_control`, AND the user half of the
        # `raw_turns` window that wiki ingest reads on shutdown); output
        # transcription is where the plugin gets the assistant text for
        # `conversation_item_added` (verified in the installed livekit
        # plugin's realtime_api.py — model-turn text is never used for
        # captions), which drives the client's agent captions and the Ayma
        # half of `raw_turns`. Dropping either would silently lose captions
        # and memory, not just cost.
        "input_audio_transcription": types.AudioTranscriptionConfig(),
        "output_audio_transcription": types.AudioTranscriptionConfig(),
    }
    # Server-VAD tuning against false turn triggers — see the block comment on
    # `_turn_detection_config`. Field acceptance verified live against
    # gemini-3.8-live on the Dev API (setupComplete with the tuned
    # realtimeInputConfig) before enabling by default.
    turn_detection = _turn_detection_config()
    if turn_detection is not None:
        kwargs["realtime_input_config"] = turn_detection
    if context_opt.voice_compression_enabled():
        # Phase 1 (cost program 2026-09-26): Live API sliding-window context
        # compression. Without it the Live session re-bills the ENTIRE
        # accumulated context (audio ≈25 tok/s + seeded history + wiki) on
        # every single turn — the dominant term in voice cost. Field names
        # verified against the installed google-genai SDK
        # (ContextWindowCompressionConfig.trigger_tokens /
        # SlidingWindow.target_tokens) and the installed livekit plugin's
        # RealtimeModel(context_window_compression=...) parameter.
        #
        # BUT only for models that genuinely honor it. The legacy Dev-API
        # `gemini-3.1-flash-live-preview` accepts the field (returns
        # setupComplete) but does NOT evict: on audio it's a soft hint that
        # keeps re-billing a growing window, and on the text-seed path it
        # fatally closes the session with 1007. It is therefore gated OFF for
        # that model — see context_opt.voice_compression_supported_for. On
        # `gemini-3.8-live` (the current Dev-API default, 2026-09-26 upgrade)
        # the sliding window was measured live to genuinely evict — bounded
        # sawtooth ~8k..16k, no 1007 (details in context_opt.py) — and on the
        # Vertex `gemini-live-2.5-flash-native-audio` launch model it works as
        # intended, so it stays on for both.
        if context_opt.voice_compression_supported_for(model):
            kwargs["context_window_compression"] = types.ContextWindowCompressionConfig(
                trigger_tokens=context_opt.voice_compression_trigger_tokens(),
                sliding_window=types.SlidingWindow(
                    target_tokens=context_opt.voice_compression_target_tokens()
                ),
            )
        else:
            # No safe client-side substitute exists on this model: the plugin
            # marks its chat context immutable (mutable_chat_context=False for
            # "3.1"), so update_chat_ctx can't push a trimmed window
            # mid-session, truncate() is a no-op, and message removal is
            # unsupported. The only lever left is the seed diet (level >= 2)
            # plus a full session restart, which we deliberately do not force
            # mid-call. Log it so the decision is visible in the worker logs.
            logger.info(
                "voice context_window_compression skipped: model %s does not "
                "honor the sliding window (seed diet is the only active lever)",
                model,
            )
    lang_code = voices.bcp47_hint(language) if language else None
    if lang_code:
        # An exact tag ("en-GB") or a best-guess from the free-text preference
        # ("Malayalam mixed with English" -> "ml-IN"). This biases Gemini Live's
        # transcription so romanised Indian-language speech isn't misdetected
        # (often as Chinese). The system prompt still carries the full accent
        # instruction and lets Ayma follow the caller mid-call.
        kwargs["language"] = lang_code
    # Native-audio-only Live features (read the caller's tone and reply with
    # matching prosody; volunteer a thought unprompted). OFF by default — the
    # Live model we run rejects the session setup when these are set, which
    # takes voice down entirely. Opt back in per-env once on a native-audio
    # model: GEMINI_LIVE_AFFECTIVE_DIALOG / GEMINI_LIVE_PROACTIVITY = true.
    if CONFIG.gemini_live_affective_dialog:
        kwargs["enable_affective_dialog"] = True
    if CONFIG.gemini_live_proactivity:
        kwargs["proactivity"] = True
    if dev_api:
        # Gemini Developer API — the only place Live 3.x is served. Key comes
        # from GOOGLE_API_KEY (Secret Manager, mounted on ayma-agent only).
        #
        # Async function calling: livekit-plugins-google >= 1.8 defaults
        # 3.8-live tool declarations to NON_BLOCKING (the model keeps talking
        # while a tool runs). Every Ayma tool result is meant to be spoken
        # about immediately, so pin BLOCKING — the synchronous flow verified
        # live on 2026-09-26 (toolCall -> toolResponse -> model continues).
        # Dev API only: Vertex rejects a per-declaration ``behavior``.
        kwargs["tool_behavior"] = types.Behavior.BLOCKING
        key = os.getenv("GOOGLE_API_KEY")
        if not key:
            raise RuntimeError(
                "gemini_live_use_dev_api is on but GOOGLE_API_KEY is unset"
            )
        kwargs["vertexai"] = False
        kwargs["api_key"] = key
    elif CONFIG.use_vertex:
        kwargs["vertexai"] = True
        if CONFIG.project_id:
            kwargs["project"] = CONFIG.project_id
        # The native-audio Live model is served from us-central1, not the
        # "global" endpoint the text models use (config.py LOCKED block).
        kwargs["location"] = CONFIG.gemini_live_location
    return RealtimeModel(**kwargs)


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


def _publish_tool_event(ctx: JobContext, phase: str, name: str) -> None:
    """Fire-and-forget a ``tool_used`` event onto the room data channel — the
    voice equivalent of the text chat's status -> reply kicker (gemini.py).
    ``phase`` is ``"start"`` (live, present-progressive label) or ``"end"``
    (persistent, past-tense label) so the client can swap one for the other,
    matching ``generate_reply_events``'s status -> reply pattern."""
    label = _working_label(name) if phase == "start" else _tool_label(name)
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


def watch_for_idle(
    ctx: JobContext,
    session: AgentSession,
    uid: str,
    flush: Callable[[], Awaitable[None]],
    timeout_seconds: float | None = None,
) -> IdleWatchdog | None:
    """Start the inactivity watchdog for this session (see
    :class:`idle_watchdog.IdleWatchdog`). Activity = user speech (any
    transcript or speaking state), the agent speaking or thinking, a tool call
    (via the returned watchdog's ``touch``), or a data message from the user.
    "Shut up" muting is not activity, so a muted forgotten call still times
    out. Returns None when the timeout is disabled."""
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


def relay_transcripts(
    ctx: JobContext,
    session: AgentSession,
    collector: list[Turn] | None = None,
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
        if collector is not None and ev.is_final and ev.transcript.strip():
            collector.append(Turn(ROLE_USER, ev.transcript.strip()))

    @session.on("conversation_item_added")
    def _on_item(ev: ConversationItemAddedEvent) -> None:
        if getattr(ev.item, "role", None) != "assistant":  # handoffs/tool calls have no role
            return
        text = _strip_leaked_tool_artifact(
            (ev.item.text_content or "").strip()
        ).strip()
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
# resolves to `True` for our exact setup (Google `RealtimeModel`,
# `capabilities.turn_detection=True`,
# `capabilities.can_disable_turn_detection=False`, no client VAD and no
# `automatic_activity_detection.disabled` anywhere — the sensitivity/padding
# tuning in `_turn_detection_config` keeps server turn detection ON) — see
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
    ``agent_mute`` topic so the client can show that Ayma is deliberately quiet.
    """

    @session.on("user_input_transcribed")
    def _on_user_final(ev: UserInputTranscribedEvent) -> None:
        if not ev.is_final:
            return
        transcript = ev.transcript.strip()
        if not transcript:
            return
        if state.muted:
            if _addresses_ayma(transcript):
                state.muted = False
                if ctx is not None:
                    _publish_mute_state(ctx, False)
        elif _is_mute_trigger(transcript):
            state.muted = True
            if ctx is not None:
                _publish_mute_state(ctx, True)

    @session.on("speech_created")
    def _on_speech_created(ev) -> None:  # noqa: ANN001 - SpeechCreatedEvent
        if state.muted:
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
    # When set, the agent speaks first with these instructions (the pre-sign-in
    # "welcome" room). Empty for a normal session where the caller opens.
    greeting_instructions: str = ""


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
        model = token_ledger.live_model_id(inference=inference)
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
        greeting_instructions=str(seed.get("greeting_instructions", "")),
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


def _session_tools(
    ctx: JobContext,
    uid: str,
    on_activity: Callable[[], None] | None = None,
    on_voice_change: Callable[[str | None, str], tuple[bool, str]] | None = None,
) -> list:
    """The shared skills registry (§13.6), bound to this session and wrapped as
    livekit-agents tools. Every call publishes a ``tool_used`` start/end event
    (§1.7 step 3) so the client can show what Ayma is doing mid-call, the way
    the text chat's status -> reply kicker already does."""
    if not uid:
        return []

    def _on_call(phase: str, name: str) -> None:
        if on_activity is not None:
            on_activity()
        _publish_tool_event(ctx, phase, name)

    return skills.make_livekit_tools(
        get_db(), uid, on_call=_on_call, on_voice_change=on_voice_change
    )


# Mid-call voice switch (founder request 2026-10-25): Gemini Live fixes the
# voice (and the speech-language hint) when the Live session is set up, so a
# change during the call reconnects it. Before the reconnect Ayma says a short
# heads-up in the old voice; we wait for that to finish playing, bounded by
# these timeouts so a heads-up that never comes (muted, or the model skipped
# it) costs at most _HEADS_UP_START_TIMEOUT of extra gap.
_HEADS_UP_START_TIMEOUT = 2.0
_HEADS_UP_END_TIMEOUT = 8.0


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


class SwappedVoiceAgent(Agent):
    """The same Ayma agent rebuilt on a new Live model after a mid-call voice
    switch. Its first line is the short confirmation in the new voice — there
    is no opener or greeting on this path."""

    def __init__(self, *, confirm_instructions: str, **kwargs) -> None:
        super().__init__(**kwargs)
        self._confirm_instructions = confirm_instructions

    async def on_enter(self) -> None:
        try:
            await self.session.generate_reply(instructions=self._confirm_instructions)
        except Exception:  # noqa: BLE001 - a missed confirmation shouldn't kill the call
            logger.exception("voice-swap confirmation failed")


class VoiceSwapper:
    """Applies a mid-call ``set_voice_preference`` change to the running call.

    The swap is an ``AgentSession.update_agent`` handoff to a
    :class:`SwappedVoiceAgent` whose ``llm`` is a freshly built realtime model
    (same builder, same provider route, new voice / language hint): the
    framework closes the old Live session and opens a new one on the same room,
    seeded with the conversation so far. The ``AgentSession`` itself stays, so
    everything wired onto it — transcript relay into the raw_turns window, mute
    control, agent-state relay, token metering, the idle watchdog — carries on
    untouched. Function-call items are dropped from the carried history (their
    ids belong to the closed Live session); the spoken turns, the instructions
    (system prompt with wiki memory) and the tools carry over as they were."""

    def __init__(
        self,
        session: AgentSession,
        *,
        system_prompt: str,
        route: str,
        voice_name: str = "",
        voice_language: str = "",
        model_factory: Callable[..., object] | None = None,
    ) -> None:
        self._session = session
        self._system_prompt = system_prompt
        self._route = route
        self._factory = model_factory or build_realtime_model
        self.tools: list = []
        self._voice = (
            voice_name if voices.is_valid_voice(voice_name) else CONFIG.gemini_live_voice
        )
        self._language = voice_language
        self._live = (self._voice, self._hint(voice_language))
        self._task: asyncio.Task | None = None

    def _hint(self, language: str) -> str | None:
        # The LiveKit Inference gateway ignores the language hint (see
        # build_inference_realtime_model), so only the Google route has one.
        if self._route == "inference" or not language:
            return None
        return voices.bcp47_hint(language)

    def _describe(self) -> str:
        desc = voices.VOICE_PRESETS.get(self._voice, "")
        text = f"the {self._voice} voice" + (f" ({desc})" if desc else "")
        if self._language:
            text += f", speaking: {self._language}"
        return text

    def request(self, preset: str | None, accent: str) -> tuple[bool, str]:
        """The ``set_voice_preference`` live hook: record the new target and,
        when it needs a new Live session, schedule the reconnect. Returns
        ``(reconnecting, detail)`` — ``detail`` says truthfully what changes."""
        parts: list[str] = []
        if preset:
            same = preset == self._voice
            parts.append(
                f"voice → {preset} ({voices.VOICE_PRESETS[preset]})"
                + (" — that is already the current voice" if same else "")
            )
            self._voice = preset
        if accent:
            self._language = accent
            hint = self._hint(accent)
            parts.append(
                f"accent/language → {accent}: Gemini Live has no accent "
                + (
                    f"setting, so the speech-language hint is set to {hint} and "
                    if hint
                    else "setting, so "
                )
                + "you speak that way yourself from now on"
            )
        reconnecting = (self._voice, self._hint(self._language)) != self._live
        if reconnecting:
            self._task = asyncio.get_running_loop().create_task(
                self._swap(self._task)
            )
        return reconnecting, "; ".join(parts)

    async def _swap(self, previous: asyncio.Task | None) -> None:
        if previous is not None:
            # Serialise back-to-back requests; each one already logged its
            # own failure.
            await asyncio.gather(previous, return_exceptions=True)
        target = (self._voice, self._hint(self._language))
        if target == self._live:
            return
        try:
            await _await_heads_up(self._session)
            change = self._describe()
            model = self._factory(self._voice, self._language, route=self._route)
            history = self._session.current_agent.chat_ctx.copy(
                exclude_function_call=True,
                exclude_instructions=True,
                exclude_empty_message=True,
                exclude_handoff=True,
                exclude_config_update=True,
            )
            self._session.update_agent(
                SwappedVoiceAgent(
                    confirm_instructions=voice_swap_confirm(change),
                    instructions=f"{self._system_prompt}\n\n{voice_swap_note(change)}",
                    tools=self.tools,
                    chat_ctx=history,
                    llm=model,
                )
            )
            self._live = target
            logger.info(
                "voice-swap voice=%s hint=%s route=%s items=%d",
                target[0], target[1], self._route, len(history.items),
            )
        except Exception as exc:  # noqa: BLE001 - keep the call on the old voice
            capture_exception(exc)
            logger.exception("voice swap failed; staying on the current voice")


def _has_new_turns(window: list[Turn], seeded_turn_count: int) -> bool:
    """True once ``window`` (the session's running turn collector, seeded from
    `/bootstrap`'s ``recent_turns`` and appended to live by
    :func:`relay_transcripts`) holds at least one turn beyond what it was
    seeded with — i.e. something was actually said in this room, as opposed
    to a job that was dispatched (§ room creation triggers LiveKit's
    automatic dispatch) but never heard from a connected caller."""
    return len(window) > seeded_turn_count


async def entrypoint(ctx: JobContext) -> None:
    """Join the dispatched room and run one Gemini Live voice session."""
    try:
        await _run_session(ctx)
    except Exception as exc:
        capture_exception(exc)
        raise


async def _run_session(ctx: JobContext) -> None:
    await ctx.connect()
    seed = await _await_room_seed(ctx)

    # The full session window = the turns carried in from /bootstrap plus every
    # finalized voice turn from here on. Persisted to raw_turns AND folded into
    # the wiki on shutdown — the room can close for any reason (a clean hang
    # up, but also out-of-credits mid-call, a dropped network, or the app
    # being killed/backgrounded), and this is the one hook guaranteed to run
    # regardless, so it must not rely on a later client `/post-turn` call that
    # may never come (see `post_turn.persist_and_ingest`'s docstring for the
    # real conversation this was root-caused against).
    window: list[Turn] = list(seed.seed_turns)
    # Provider decided ONCE per call (runtime Firestore flag, optional uid
    # allowlist) and threaded to the model, the session record and the ledger.
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

    # allow_interruptions defaults on; stated here so the "no custom VAD, native
    # turn-detection only" decision (§1.7 step 9) is visible at the call site.
    session = AgentSession(
        llm=build_realtime_model(seed.voice_name, seed.voice_language, route=route),
        allow_interruptions=True,
    )
    relay_transcripts(ctx, session, collector=window)
    # Session closed = the conversation is over (no more turns can arrive):
    # start the memory write now rather than at job shutdown (see
    # SessionFlush.start).
    session.on("close", lambda _ev: flush.start())
    relay_agent_state(ctx, session)
    relay_mute_control(session, MuteState(), ctx)
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
    watchdog = watch_for_idle(ctx, session, seed.uid, flush.run)
    swapper = VoiceSwapper(
        session,
        system_prompt=seed.system_prompt,
        route=route,
        voice_name=seed.voice_name,
        voice_language=seed.voice_language,
    )
    tools = _session_tools(
        ctx,
        seed.uid,
        on_activity=watchdog.touch if watchdog else None,
        on_voice_change=swapper.request,
    )
    swapper.tools = tools
    agent_kwargs: dict = {"instructions": seed.system_prompt, "tools": tools}
    if seed.chat_ctx is not None:
        agent_kwargs["chat_ctx"] = seed.chat_ctx
    agent = Agent(**agent_kwargs)
    await session.start(
        agent=agent,
        room=ctx.room,
        room_output_options=RoomOutputOptions(transcription_enabled=False),
    )

    # Pre-sign-in "welcome" room: Ayma opens the call instead of waiting for
    # the caller to speak first.
    if seed.greeting_instructions:
        try:
            await session.generate_reply(
                instructions=seed.greeting_instructions
            )
        except Exception:  # noqa: BLE001 - a missed greeting shouldn't kill the call
            logger.exception("welcome greeting failed")
    else:
        await maybe_open_conversation(session, seed, window=window)


async def maybe_open_conversation(
    session: AgentSession,
    seed: RoomSeed,
    *,
    window: list[Turn],
    grace_seconds: float | None = None,
) -> bool:
    """Ayma speaks first on a normal call when the caller stays silent.

    Waits the grace window after the session is live; if the caller has not
    started speaking (user_state_changed -> speaking, or any
    user_input_transcribed) and nobody has spoken in the room, generates one
    short contextual opener from ``prompts/voice_opener.md`` through the same
    ``generate_reply`` path (so the turn is metered by the usual
    ``metrics_collected`` ledger relay). Returns True if the opener fired.
    Skipped for the welcome room (it has its own greeting), when the last
    seeded turn is the caller's (a resumed call mid-turn), or when the opener
    is disabled by config. Runs at most once per session by construction."""
    grace = (
        CONFIG.voice_opener_grace_seconds if grace_seconds is None else grace_seconds
    )
    if grace <= 0 or seed.greeting_instructions:
        return False
    if seed.seed_turns and seed.seed_turns[-1].role == ROLE_USER:
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
        return False
    except asyncio.TimeoutError:
        pass
    if user_started.is_set() or _has_new_turns(window, seeded):
        return False
    try:
        await session.generate_reply(instructions=load_voice_opener())
    except Exception:  # noqa: BLE001 - a missed opener shouldn't kill the call
        logger.exception("voice opener failed")
        return False
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


def worker_options() -> WorkerOptions:
    return WorkerOptions(
        entrypoint_fnc=entrypoint,
        prewarm_fnc=prewarm,
        # Cloud Run assigns the container port ($PORT); the worker's health
        # server must bind it so the startup probe passes. Falls back to the
        # livekit-agents default when run outside Cloud Run.
        port=int(os.getenv("PORT", "8081")),
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


if __name__ == "__main__":
    cli.run_app(worker_options())
