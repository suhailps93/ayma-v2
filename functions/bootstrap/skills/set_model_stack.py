"""Ayma changes her OWN model stack — brain, voice mode, realtime model — and
reconnects the live call to apply it (ARCHITECTURE.md §13.9 / §13.10).

Before this, Ayma could change her *voice character / accent / language*
(``set_voice_preference``) but had no way to change the BRAIN she thinks with,
the VOICE MODE (realtime native-audio ↔ cascade) or the REALTIME MODEL — so she
wrongly told the founder she "doesn't have separate brains". These tools close
that gap. Each one:

* resolves the user's words to an id and validates it against the SAME source of
  truth the "Ayma's models" settings screen uses (``llm_provider.available_brains``
  for the brain, ``voice_catalog`` for the mode / realtime model), so Ayma can
  never save a value the screen wouldn't allow;
* writes the SAME ``users/{uid}/profile/main`` field the screen's save endpoint
  writes (``schema.PF_AYMA_*``), so a change Ayma makes shows up on the screen and
  vice-versa — one source of truth;
* reports an honest result (and never claims a switch that didn't happen).

A saved stack change applies on the NEXT voice call, exactly as the screen says.
``reconnect_voice`` applies it to the CURRENT call on explicit request only, by
asking the client to tear down and re-establish the LiveKit session (the same
bootstrap path that reads the saved stack at connect time) — all voice stays on
LiveKit. Callable in both voice and text sessions.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from typing import Callable

from firebase_admin import firestore

import schema
import voice_catalog
import voices
from llm_provider import PROVIDER_GEMINI, PROVIDER_META, available_brains

from ._base import Skill
from .app_control_queue import _await_ack, _prompt, _queue_command

logger = logging.getLogger("ayma.skills")


# --- shared persistence (mirrors main.set_voice_preference_endpoint writes) ---


def _write(db, uid: str, field: str, value: str) -> None:
    """Merge one model-stack field onto ``users/{uid}/profile/main`` — the SAME
    doc and field constant the settings screen's save endpoints write."""
    schema.profile_doc(db, uid).set(
        {field: value, "updated_at": firestore.SERVER_TIMESTAMP}, merge=True
    )


def _write_many(db, uid: str, fields: dict[str, str]) -> None:
    schema.profile_doc(db, uid).set(
        {**fields, "updated_at": firestore.SERVER_TIMESTAMP}, merge=True
    )


# --- brain --------------------------------------------------------------------

# "Muse" is the founder's everyday name for the Meta Muse Spark brain. Open
# weights is NOT a unified-brain option (it is only a cascade *voice* brain), so
# it is handled with an honest redirect rather than a silent no-op.
_BRAIN_ALIASES: dict[str, str] = {
    "muse": PROVIDER_META,
    "muse spark": PROVIDER_META,
    "muse-spark": PROVIDER_META,
    "meta": PROVIDER_META,
    "meta muse spark": PROVIDER_META,
    "gemini": PROVIDER_GEMINI,
    "google": PROVIDER_GEMINI,
    "google gemini": PROVIDER_GEMINI,
}
_OPEN_WEIGHTS_WORDS = frozenset(
    "open-weights open weights openweights llama open-weight".split()
)


def _brain_catalog() -> dict[str, str]:
    """``{id: label}`` for the unified-Brain options — the SAME list the screen's
    ``GET /brain/preference`` serves (``llm_provider.available_brains``)."""
    return {str(b["id"]): str(b["label"]) for b in available_brains()}


def _resolve_brain(text: str) -> tuple[str | None, str]:
    """``(brain_id, "")`` for a recognised, available brain, else
    ``(None, reason)`` with an honest, user-facing reason."""
    raw = (text or "").strip().lower()
    catalog = _brain_catalog()
    if not raw:
        names = ", ".join(f"{label}" for label in catalog.values())
        return None, f"ask which brain they want — {names}"
    chosen = _BRAIN_ALIASES.get(raw, raw)
    if chosen in catalog:
        return chosen, ""
    if raw in _OPEN_WEIGHTS_WORDS or "open weight" in raw or "llama" in raw:
        return None, (
            "open-weights isn't one of the main brains (those are "
            + " and ".join(catalog.values())
            + "); it IS available as the brain under Voice \u2014 call "
            "set_voice_brain with 'open weights' to switch the voice "
            "brain to it (cascade mode); the main brain stays unchanged"
        )
    names = ", ".join(f"{label}" for label in catalog.values())
    return None, f"'{text.strip()}' isn't an available brain — those are {names}"


def _bind_set_brain(db, uid: str) -> Callable[..., object]:
    async def set_brain(brain: str = "") -> str:
        brain_id, reason = _resolve_brain(brain)
        if brain_id is None:
            return reason
        label = _brain_catalog()[brain_id]
        try:
            await asyncio.to_thread(
                _write, db, uid, schema.PF_AYMA_BRAIN_MODEL, brain_id
            )
        except Exception:  # noqa: BLE001 - never crash the tool loop
            logger.exception("set_brain write failed for %s", uid)
            return "The app did NOT save that brain — tell the user it didn't work."
        return (
            f"brain → {label} — saved as your default. I'll think with it on our "
            "text chats from now; on a voice call it applies when you're in "
            "cascade mode (say 'reconnect' to apply a change to this call). Web "
            "search and reading images always use Gemini."
        )

    return set_brain



# --- voice brain (the brain under Voice) -------------------------------------
#
# The cascade voice stack has its OWN brain, distinct from the unified main
# brain above: the LLM the voice pipeline thinks with on a cascade call (Meta
# Muse Spark, the self-hosted open-weights Llama, or a LiveKit Inference LLM).
# Before this tool existed the two were conflated: an "under voice, change the
# brain to the open-weights model" ask hit ``set_brain``, whose catalog has no
# open-weights entry, so Ayma told the founder she "didn't have an
# open-weights option" even with it enabled (founder bug, 2026-11-03). The
# catalog here is ``voice_catalog``'s \u2014 the SAME list the models screen
# shows \u2014 so open weights is offered exactly when ``OPEN_WEIGHTS_BASE_URL``
# is set, and a switch persists to the SAME profile field the screen writes.

_VOICE_BRAIN_ALIASES: dict[str, str] = {
    "muse": voice_catalog.BRAIN_META,
    "muse spark": voice_catalog.BRAIN_META,
    "muse-spark": voice_catalog.BRAIN_META,
    "meta": voice_catalog.BRAIN_META,
    "meta muse spark": voice_catalog.BRAIN_META,
    "open weights": voice_catalog.BRAIN_OPEN_WEIGHTS,
    "open-weights": voice_catalog.BRAIN_OPEN_WEIGHTS,
    "openweights": voice_catalog.BRAIN_OPEN_WEIGHTS,
    "open weight": voice_catalog.BRAIN_OPEN_WEIGHTS,
    "open-weight": voice_catalog.BRAIN_OPEN_WEIGHTS,
    "llama": voice_catalog.BRAIN_OPEN_WEIGHTS,
    "llama 3.1 8b": voice_catalog.BRAIN_OPEN_WEIGHTS,
}


def _voice_brain_catalog() -> dict[str, str]:
    """``{id: label}`` for every cascade voice brain in the catalog
    (``voice_catalog.catalog()["brains"]``) \u2014 grounded in the live config,
    so open weights is present only when its endpoint is configured."""
    return {
        str(b["id"]): str(b["label"])
        for b in voice_catalog.catalog()["brains"]  # type: ignore[index]
    }


def _available_voice_brains() -> dict[str, str]:
    """The AVAILABLE subset of :func:`_voice_brain_catalog` \u2014 a brain whose
    provider isn't available on this account is never offered or saved."""
    return {
        str(b["id"]): str(b["label"])
        for b in voice_catalog.catalog()["brains"]  # type: ignore[index]
        if b.get("available")
    }


def _resolve_voice_brain(text: str) -> tuple[str | None, str]:
    """``(brain_id, "")`` for a recognised, AVAILABLE voice brain, else
    ``(None, reason)`` with an honest, user-facing reason naming the real
    options. Accepts canonical ids (``run_stack_command`` passes them)."""
    raw = (text or "").strip().lower()
    available = _available_voice_brains()
    labels = ", ".join(available.values())
    if not raw:
        return None, f"ask which voice brain they want \u2014 {labels}"
    chosen = _VOICE_BRAIN_ALIASES.get(raw, raw)
    if chosen in available:
        return chosen, ""
    full = _voice_brain_catalog()
    if chosen in full:
        return None, (
            f"the {full[chosen]} voice brain isn't available on this "
            f"account right now \u2014 the voice brains are: {labels}"
        )
    norm = _norm(raw)
    for bid, label in available.items():
        if norm and (norm in _norm(bid) or norm in _norm(label)):
            return bid, ""
    return None, (
        f"'{text.strip()}' isn't an available voice brain \u2014 "
        f"the voice brains are: {labels}"
    )


def _persist_voice_brain(db, uid: str, text: str) -> str:
    """Validate (voice catalog) and save the cascade voice brain + cascade
    mode. Returns the user-facing result. Runs in a worker thread
    (``catalog()`` may touch the LiveKit Inference gateway); never raises."""
    brain_id, reason = _resolve_voice_brain(text)
    if brain_id is None:
        return reason
    label = _available_voice_brains()[brain_id]
    try:
        _write_many(
            db, uid,
            {
                schema.PF_AYMA_CASCADE_BRAIN: brain_id,
                # The voice brain only applies in cascade mode; set it too,
                # like the STT/TTS setters, so the choice takes effect.
                schema.PF_AYMA_VOICE_MODE: voice_catalog.MODE_CASCADE,
            },
        )
    except Exception:  # noqa: BLE001
        logger.exception("set_voice_brain write failed for %s", uid)
        return "The app did NOT save that voice brain \u2014 tell the user it didn't work."
    return (
        f"voice brain \u2192 {label} \u2014 that's the brain under Voice (cascade "
        "mode), saved as your default; your main brain is unchanged. It "
        "takes effect on your next voice call, or say 'reconnect' to apply "
        "it to this call."
    )


def _bind_set_voice_brain(db, uid: str) -> Callable[..., object]:
    async def set_voice_brain(brain: str = "") -> str:
        return await asyncio.to_thread(_persist_voice_brain, db, uid, brain)

    return set_voice_brain


# --- voice mode ---------------------------------------------------------------

_MODE_ALIASES: dict[str, str] = {
    "realtime": voice_catalog.MODE_REALTIME,
    "real time": voice_catalog.MODE_REALTIME,
    "native": voice_catalog.MODE_REALTIME,
    "native audio": voice_catalog.MODE_REALTIME,
    "live": voice_catalog.MODE_REALTIME,
    "cascade": voice_catalog.MODE_CASCADE,
    "text": voice_catalog.MODE_CASCADE,
    "text mode": voice_catalog.MODE_CASCADE,
}


def _resolve_mode(text: str) -> str | None:
    raw = (text or "").strip().lower()
    chosen = _MODE_ALIASES.get(raw, raw)
    return chosen if chosen in voice_catalog.MODES else None


def _bind_set_voice_mode(db, uid: str) -> Callable[..., object]:
    async def set_voice_mode(mode: str = "") -> str:
        resolved = _resolve_mode(mode)
        if resolved is None:
            return (
                f"'{mode.strip()}' isn't a voice mode — the modes are "
                + " and ".join(voice_catalog.MODES)
                + " (realtime is native audio; cascade is brain + STT + TTS)"
            )
        try:
            await asyncio.to_thread(
                _write, db, uid, schema.PF_AYMA_VOICE_MODE, resolved
            )
        except Exception:  # noqa: BLE001
            logger.exception("set_voice_mode write failed for %s", uid)
            return "The app did NOT save that mode — tell the user it didn't work."
        kind = (
            "native-audio (I listen and speak directly)"
            if resolved == voice_catalog.MODE_REALTIME
            else "cascade — a brain plus speech-to-text and text-to-speech"
        )
        return (
            f"voice mode → {resolved} ({kind}) — saved as your default; it takes "
            "effect on your next voice call, or say 'reconnect' to apply it to "
            "this call."
        )

    return set_voice_mode


# --- realtime model -----------------------------------------------------------

_REALTIME_ALIASES: dict[str, str] = {
    "gemini": voice_catalog.REALTIME_GEMINI,
    "gemini live": voice_catalog.REALTIME_GEMINI,
    "gemini-live": voice_catalog.REALTIME_GEMINI,
    "native": voice_catalog.REALTIME_GEMINI,
    "native audio": voice_catalog.REALTIME_GEMINI,
    "openai": voice_catalog.REALTIME_OPENAI,
    "open ai": voice_catalog.REALTIME_OPENAI,
    "gpt": voice_catalog.REALTIME_OPENAI,
    "openai realtime": voice_catalog.REALTIME_OPENAI,
}


def _realtime_label(model_id: str) -> str:
    for m in voice_catalog.catalog()["realtime_models"]:  # type: ignore[index]
        if m["id"] == model_id:
            return str(m["label"])
    return model_id


def _persist_realtime(db, uid: str, text: str) -> str:
    """Validate (catalog) and save the realtime model + realtime mode. Returns
    the user-facing result. Runs in a worker thread (``catalog()`` may touch the
    LiveKit Inference gateway); never raises."""
    raw = (text or "").strip().lower()
    model_id = _REALTIME_ALIASES.get(raw, raw)
    try:
        if not model_id or not voice_catalog.is_valid_realtime_model(model_id):
            options = ", ".join(
                str(m["label"])
                for m in voice_catalog.catalog()["realtime_models"]  # type: ignore[index]
            )
            return (
                f"'{text.strip()}' isn't an available realtime model — "
                f"the options on this account are: {options}"
            )
        _write_many(
            db, uid,
            {
                schema.PF_AYMA_REALTIME_MODEL: model_id,
                # A realtime model only applies in realtime mode; set both so the
                # choice actually takes effect (the screen couples them too).
                schema.PF_AYMA_VOICE_MODE: voice_catalog.MODE_REALTIME,
            },
        )
    except Exception:  # noqa: BLE001
        logger.exception("set_realtime_model failed for %s", uid)
        return "The app did NOT save that model — tell the user it didn't work."
    return (
        f"realtime model → {_realtime_label(model_id)} — saved as your default "
        "(in realtime mode); it takes effect on your next voice call, or say "
        "'reconnect' to apply it to this call."
    )


def _bind_set_realtime_model(db, uid: str) -> Callable[..., object]:
    async def set_realtime_model(model: str = "") -> str:
        return await asyncio.to_thread(_persist_realtime, db, uid, model)

    return set_realtime_model


# --- cascade STT / TTS engines ------------------------------------------------
#
# The cascade stack's speech-to-text and text-to-speech ENGINES are selectable
# exactly like the brain, from the SAME catalog the "Ayma's models" screen and
# the ``POST /voice/preference`` endpoint use (``voice_catalog.catalog()``).
# Before this Ayma had no tool for them, so she told the founder she had "no
# options" for STT/TTS even though the screen shows pickers (founder bug,
# 2026-11-03). Only AVAILABLE engines are offered (an uncredited provider is
# returned with an honest reason, never silently picked). Choosing either engine
# also puts Ayma in cascade mode (they only apply there — the screen couples them
# the same way ``set_realtime_model`` couples realtime mode).


def _norm(s: str) -> str:
    return re.sub(r"[\s_/-]+", "", (s or "").strip().lower())


def _component_labels(options: list[dict]) -> str:
    """The provider names of the AVAILABLE engines, for an honest "pick one of"."""
    seen: list[str] = []
    for o in options:
        if o.get("available"):
            name = str(o.get("provider") or o.get("id"))
            if name and name not in seen:
                seen.append(name)
    return ", ".join(seen)


def _resolve_cascade_component(text: str, options: list[dict]) -> tuple[str | None, str]:
    """``(engine_id, "")`` for a recognised, AVAILABLE engine in ``options``
    (catalog entries with ``id``/``provider``/``available``/``requires_secret``),
    else ``(None, reason)`` with an honest, user-facing reason. Matches by exact
    id, by provider name, or by a space/hyphen-insensitive substring so "fish
    audio", "fishaudio" and "fishaudio/s2.1-pro" all resolve."""
    raw = _norm(text)
    labels = _component_labels(options)
    if not raw:
        return None, f"ask which engine they want — {labels}"
    available = [o for o in options if o.get("available")]
    for o in available:
        oid, prov = _norm(str(o["id"])), _norm(str(o.get("provider") or ""))
        if raw in (oid, prov) or (prov and prov in raw) or raw in oid:
            return str(o["id"]), ""
    # Named but not available on this account → honest reason, not a silent pick.
    for o in options:
        if o.get("available"):
            continue
        oid, prov = _norm(str(o["id"])), _norm(str(o.get("provider") or ""))
        if raw in (oid, prov) or (prov and prov in raw) or raw in oid:
            note = str(o.get("requires_secret") or "more setup")
            return None, (
                f"'{text.strip()}' needs {note} on this account — "
                f"pick one of: {labels}"
            )
    return None, f"'{text.strip()}' isn't an available engine — pick one of: {labels}"


def _persist_cascade_component(
    db, uid: str, *, kind: str, field: str, text: str
) -> str:
    """Validate (catalog) and save a cascade STT/TTS engine + cascade mode.
    Returns the user-facing result. Runs in a worker thread (``catalog()`` may
    touch the LiveKit Inference gateway); never raises. ``kind`` is ``"stt"`` or
    ``"tts"`` (the catalog key and the human label)."""
    try:
        options = voice_catalog.catalog()[kind]  # type: ignore[index]
        engine_id, reason = _resolve_cascade_component(text, options)
        if engine_id is None:
            return reason
        _write_many(
            db, uid,
            {
                field: engine_id,
                # STT/TTS only apply in cascade mode, so set it too — otherwise
                # the change would silently have no effect (mirrors how
                # set_realtime_model couples realtime mode).
                schema.PF_AYMA_VOICE_MODE: voice_catalog.MODE_CASCADE,
            },
        )
    except Exception:  # noqa: BLE001
        logger.exception("set_%s failed for %s", kind, uid)
        return f"The app did NOT save that {kind.upper()} engine — tell the user it didn't work."
    human = "speech-to-text" if kind == "stt" else "text-to-speech"
    return (
        f"{human} → {engine_id} — saved as your default (in cascade mode); it "
        "takes effect on your next voice call, or say 'reconnect' to apply it to "
        "this call."
    )


def _bind_set_stt(db, uid: str) -> Callable[..., object]:
    async def set_stt(engine: str = "") -> str:
        return await asyncio.to_thread(
            _persist_cascade_component,
            db, uid, kind="stt", field=schema.PF_AYMA_CASCADE_STT, text=engine,
        )

    return set_stt


def _bind_set_tts(db, uid: str) -> Callable[..., object]:
    async def set_tts(engine: str = "") -> str:
        return await asyncio.to_thread(
            _persist_cascade_component,
            db, uid, kind="tts", field=schema.PF_AYMA_CASCADE_TTS, text=engine,
        )

    return set_tts


# --- reconnect the live call --------------------------------------------------


# One-shot guard against the infinite reconnect loop (founder 2026-11-03): a
# reconnect tears down the call and starts a fresh session seeded (via
# ``/bootstrap``'s ``recent_turns``) with the transcript that STILL contains the
# user's "reconnect" ask — so the new session's agent re-invoked reconnect_voice,
# reconnecting forever and burning LiveKit minutes. The marker records when a
# reconnect was last requested; within the cooldown reconnect_voice refuses to
# queue another reconnect, so the session it just created can never re-trigger
# it. A deliberate later reconnect (after the window) still works.
_RECONNECT_COOLDOWN_SECONDS = 45.0
# Epoch-seconds marker on users/{uid}/profile/main, kept local to this module —
# it is internal reconnect bookkeeping, not a user-facing model-settings field.
_PF_RECONNECT_AT = "ayma_reconnect_requested_at"
# One-shot "announce the reconnect" flag, set in the same write as the marker:
# the OLD session stays silent once a reconnect is queued (agent.py's claim
# gate suppresses its narration — its speech is cut off by the teardown
# anyway, founder 2026-11-03), and the NEW session claims this flag at open
# (:func:`claim_reconnect_announcement`) to speak the one "I'm back" line
# exactly once. A separate flag (not the timestamp) so claiming the
# announcement can never disarm the loop-guard cooldown above.
_PF_RECONNECT_PENDING = "ayma_reconnect_announce_pending"
# How long a pending announcement stays claimable: the continuation session
# opens seconds after the teardown; far past this the flag is stale (the
# reconnect never landed) and a claim just clears it, silently.
_RECONNECT_ANNOUNCE_WINDOW_SECONDS = 120.0

#: ``reconnect_voice``'s queued-and-acked result — the exact string agent.py's
#: claim gate matches to silence the old session's narration for the turn.
_RECONNECT_QUEUED_RESULT = (
    "Reconnecting now — I'll drop for a second and come back on your "
    "updated setup."
)


def _recently_reconnected(db, uid: str) -> bool:
    """True when a reconnect was requested within the cooldown — read tolerantly
    so a Firestore hiccup never *blocks* a genuine first reconnect (the client
    circuit-breaker is the backstop against a storm if this read ever fails)."""
    try:
        snap = schema.profile_doc(db, uid).get()
        at = float((snap.to_dict() or {}).get(_PF_RECONNECT_AT) or 0.0)
    except Exception:  # noqa: BLE001
        return False
    return (time.time() - at) < _RECONNECT_COOLDOWN_SECONDS


def _mark_reconnected(db, uid: str) -> None:
    try:
        schema.profile_doc(db, uid).set(
            {_PF_RECONNECT_AT: time.time(), _PF_RECONNECT_PENDING: True},
            merge=True,
        )
    except Exception:  # noqa: BLE001 - best-effort; the client breaker backs it up
        logger.exception("could not mark reconnect for %s", uid)


def claim_reconnect_announcement(db, uid: str) -> bool:
    """Claim the one-shot post-reconnect announcement for ``uid``.

    True exactly once: for the first session that opens while a reconnect
    announcement is pending and still fresh — the reconnect's continuation
    session, which speaks the one "I'm back" line (agent.py
    ``_open_main_call``). The claim clears the flag, so a fresh call started
    later — or a fallback session re-opening on the same room — never
    repeats the line. A stale flag (the continuation never opened) is
    cleared and reports False. Never raises: a Firestore hiccup just means
    no announcement, never a broken call.
    """
    if not uid:
        return False
    try:
        ref = schema.profile_doc(db, uid)
        data = ref.get().to_dict() or {}
        if not data.get(_PF_RECONNECT_PENDING):
            return False
        at = float(data.get(_PF_RECONNECT_AT) or 0.0)
        fresh = (time.time() - at) < _RECONNECT_ANNOUNCE_WINDOW_SECONDS
        ref.set({_PF_RECONNECT_PENDING: False}, merge=True)
        return fresh
    except Exception:  # noqa: BLE001 - best-effort; no announcement beats a crash
        logger.exception("could not claim reconnect announcement for %s", uid)
        return False


def _bind_reconnect_voice(db, uid: str) -> Callable[..., object]:
    async def reconnect_voice() -> str:
        """Ask the client to reconnect the live voice session so the saved stack
        applies now. STRICTLY ONE-SHOT per explicit request: if a reconnect
        happened within the cooldown, refuse — the fresh session it created is
        seeded with the "reconnect" transcript and must never reconnect again
        (the infinite-loop fix). The client acks ``ok=true`` only when a call is
        actually live; ``ok=false`` means there was nothing live to reconnect."""
        if await asyncio.to_thread(_recently_reconnected, db, uid):
            return (
                "You're already reconnecting onto your updated setup — give it a "
                "moment. No need to reconnect again."
            )
        cmd_id = _queue_command(db, uid, {"action": "reconnect_voice"})
        ack = await _await_ack(db, uid, cmd_id)
        if ack and ack.get("ok"):
            # Mark BEFORE the client actually tears down + re-bootstraps (that
            # runs after this ack), so the new session sees the cooldown.
            await asyncio.to_thread(_mark_reconnected, db, uid)
            return _RECONNECT_QUEUED_RESULT
        return (
            "There's no live voice call to reconnect right now — your saved "
            "changes will apply on your next voice call."
        )

    return reconnect_voice


# --- deterministic pre-model intent (text chat, brain-agnostic) ---------------
#
# When the user's active unified Brain is Meta (Muse Spark), the brain-switch
# CHAT turn is itself handled by Muse Spark (main._generate_chat_reply →
# get_user_brain_provider("chat", needs="tools") → MetaProvider), whose weaker
# tool-calling at reasoning_effort="minimal" often answers in prose WITHOUT
# emitting set_brain — and the no-tool path never raises, so the Gemini fallback
# never engages. Result: "change back to Gemini" silently did nothing — the
# switch was one-way (founder 2026-11-02). Mirroring the #28 determinism fix,
# main._prepare_chat runs this matcher BEFORE the model, so a clear model-stack
# command is executed and confirmed regardless of which brain is active (the
# model still handles everything else). Kept strict — a change verb AND a
# resolvable target — so ordinary chat is never hijacked. Voice is unaffected:
# a realtime (Gemini Live) call already emits set_brain reliably.

_CHANGE_VERB = re.compile(
    r"\b(switch|change|set|use|put|make|flip|turn|go to|go back|change back)\b", re.I
)
_TO_BRAIN = re.compile(
    r"\bto\s+(?:the\s+)?(gemini|google|muse spark|muse|meta)\b", re.I
)
_ANY_BRAIN = re.compile(r"\b(gemini|google|muse spark|muse|meta)\b", re.I)
_TO_MODE = re.compile(r"\bto\s+(?:the\s+)?(cascade|realtime|real time|native audio)\b", re.I)
# Explicit STT / TTS phrases. Checked BEFORE the mode branch because the word
# "model" contains the substring "mode" — "change the speech-to-text MODEL to X"
# must route to set_stt, never set_voice_mode (founder/Scout bug, 2026-11-03: the
# model picked set_voice_mode because its description also mentions
# "speech-to-text", so a deterministic intercept settles it regardless of brain).
_STT_PHRASE = re.compile(
    r"\b(speech[- ]to[- ]text|speech recognition|stt|transcription|transcriber)\b",
    re.I,
)
_TTS_PHRASE = re.compile(
    r"\b(text[- ]to[- ]speech|tts|voice synthesis|speech synthesis)\b", re.I
)


def _engine_keyword_map(models: tuple[str, ...]) -> dict[str, str]:
    """``{normalised provider segment: full model id}`` for the deterministic
    STT/TTS detector — config-only (no catalog/network), so the pre-model path
    stays fast. Keyed on the PROVIDER segment only (``deepgram``, ``fishaudio``,
    …) — distinctive, so a generic model-fragment word (e.g. ``default`` from
    ``gradium/default``) can never false-match an engine. The binder re-validates
    availability + resolves finer phrasings and gives the honest refusal when
    run_stack_command calls it, so this map only needs to NAME the candidate."""
    out: dict[str, str] = {}
    for mid in models:
        prov = _norm(mid.partition("/")[0])
        if prov:
            out.setdefault(prov, mid)
    return out


_STT_KEYWORDS = _engine_keyword_map(voice_catalog.CONFIG.voice_cascade_stt_models)
_TTS_KEYWORDS = _engine_keyword_map(voice_catalog.CONFIG.voice_cascade_tts_models)


def _scan_engine(m: str, keywords: dict[str, str]) -> str | None:
    """The catalog model id for the first engine keyword (provider or model
    fragment) named anywhere in ``m``, else ``None``."""
    norm = _norm(m)
    for kw, mid in keywords.items():
        if kw in norm:
            return mid
    return None


def _scan_brain(m: str) -> str | None:
    hit = _TO_BRAIN.search(m) or _ANY_BRAIN.search(m)
    if not hit:
        return None
    tok = hit.group(1).lower()
    return PROVIDER_GEMINI if tok in ("gemini", "google") else PROVIDER_META


def detect_stack_command(message: str) -> tuple[str, str] | None:
    """A clear, unambiguous "change my brain / voice mode / realtime model to X"
    command → ``(tool_name, resolved_value)``, else ``None``. Strict: requires a
    change verb AND a resolvable target, so ordinary chat is never intercepted.
    The value is the canonical id; the bound setter re-resolves it idempotently."""
    m = (message or "").strip().lower()
    if not m or len(m) > 200 or not _CHANGE_VERB.search(m):
        return None
    # Realtime model first (most specific: a NAMED realtime model).
    if re.search(r"\bgemini live\b", m):
        return ("set_realtime_model", voice_catalog.REALTIME_GEMINI)
    if re.search(r"\bopenai realtime\b|\bgpt[- ]?realtime\b", m) or (
        "openai" in m and "realtime" in m
    ):
        return ("set_realtime_model", voice_catalog.REALTIME_OPENAI)
    # STT / TTS engine — gated by an explicit speech-to-text / text-to-speech
    # phrase AND a named engine, BEFORE the mode branch (so "model" never routes
    # to mode) and before brain (so "use fishaudio for TTS" isn't read as a brain).
    # The engine id is resolved from the config lists; the binder re-validates
    # availability and gives the honest refusal for an uncredited one.
    if _STT_PHRASE.search(m):
        engine = _scan_engine(m, _STT_KEYWORDS)
        if engine:
            return ("set_stt", engine)
    if _TTS_PHRASE.search(m):
        engine = _scan_engine(m, _TTS_KEYWORDS)
        if engine:
            return ("set_tts", engine)
    # Brain under Voice — an explicit voice qualifier ("under voice",
    # "voice brain", "for voice", "in voice") routes to the CASCADE voice
    # brain, never the main brain (the two-brain conflation, founder
    # 2026-11-03). Only voice-catalog targets are intercepted; the binder
    # re-validates availability and gives the honest refusal otherwise.
    if re.search(r"\bunder voice\b|\bvoice brain\b|\bfor voice\b|\bin voice\b", m):
        if "open weight" in m or "open-weight" in m or "llama" in m:
            return ("set_voice_brain", voice_catalog.BRAIN_OPEN_WEIGHTS)
        if re.search(r"\b(muse|meta)\b", m):
            return ("set_voice_brain", voice_catalog.BRAIN_META)
    # Brain (either direction) — gated by the word "brain" or an explicit
    # "to <brain>" so a stray brand mention ("I use Gemini at work") can't trip it.
    if "brain" in m or _TO_BRAIN.search(m):
        brain = _scan_brain(m)
        if brain:
            return ("set_brain", brain)
    # Voice mode — gated by the WORD "mode" (``\bmode\b``, never the "model"
    # substring) or an explicit "to <mode>".
    if re.search(r"\bmode\b", m) or _TO_MODE.search(m) or "text mode" in m:
        if re.search(r"\bcascade\b", m) or "text mode" in m:
            return ("set_voice_mode", voice_catalog.MODE_CASCADE)
        if re.search(r"\b(realtime|real time|native audio)\b", m):
            return ("set_voice_mode", voice_catalog.MODE_REALTIME)
    return None


async def run_stack_command(db, uid: str, name: str, value: str) -> str:
    """Execute a detected model-stack command through the SAME bound setter the
    model would call, so the write and the confirmation text are identical."""
    if name == "set_brain":
        return await _bind_set_brain(db, uid)(brain=value)
    if name == "set_voice_brain":
        return await _bind_set_voice_brain(db, uid)(brain=value)
    if name == "set_voice_mode":
        return await _bind_set_voice_mode(db, uid)(mode=value)
    if name == "set_realtime_model":
        return await _bind_set_realtime_model(db, uid)(model=value)
    if name == "set_stt":
        return await _bind_set_stt(db, uid)(engine=value)
    if name == "set_tts":
        return await _bind_set_tts(db, uid)(engine=value)
    raise ValueError(f"unknown model-stack command {name!r}")



def model_stack_context(db, uid: str) -> str:
    """The two-brain context block for Ayma's system prompt: her MAIN brain
    and the brain UNDER VOICE as separate, labeled facts \u2014 current values
    from the user's saved profile (else the catalog defaults), option lists
    from the SAME catalogs the models screen serves, so she never conflates
    the two brains and never denies an option that is actually enabled (open
    weights appears exactly when ``OPEN_WEIGHTS_BASE_URL`` is set). Tolerant:
    a failed profile read just falls back to the defaults. Never raises."""
    prof: dict = {}
    try:
        snap = schema.profile_doc(db, uid).get()
        prof = snap.to_dict() or {}
    except Exception:  # noqa: BLE001 - context must never break a turn
        logger.exception("model_stack_context profile read failed for %s", uid)
    main_labels = _brain_catalog()
    main_id = str(prof.get(schema.PF_AYMA_BRAIN_MODEL) or "").strip()
    if main_id not in main_labels:
        main_id = PROVIDER_GEMINI
    default = voice_catalog.default_selection()
    mode = (
        str(prof.get(schema.PF_AYMA_VOICE_MODE) or "").strip()
        or str(default["mode"])
    )
    voice_labels = _available_voice_brains()
    voice_id = str(prof.get(schema.PF_AYMA_CASCADE_BRAIN) or "").strip()
    if voice_id not in voice_labels:
        voice_id = (
            str(default["brain_id"])
            if str(default["brain_id"]) in voice_labels
            else next(iter(voice_labels), "")
        )
    return "\n".join([
        "Your model stack \u2014 you have TWO different brains; never mix them up:",
        f"- Main brain (your text replies and reasoning): {main_labels[main_id]}. "
        f"Main-brain options: {', '.join(main_labels.values())}.",
        f"- Voice mode: {mode}. The brain under Voice (what you think with on a "
        f"cascade voice call): {voice_labels.get(voice_id, voice_id)}. "
        f"Voice-brain options: {', '.join(voice_labels.values())}.",
        "\"The brain\" with no qualifier means your main brain; only an "
        "\"under Voice\" ask is about the voice brain. Every option listed "
        "here IS available \u2014 never say you don't have it.",
    ])


def _voice_brains_fill() -> str:
    """The available voice brains for the tool description \u2014 built from the
    static catalog builder (no LiveKit network at import), so open weights is
    listed exactly when its endpoint is configured."""
    brains = voice_catalog._brains({"source": "fallback", "llm": []})
    return ", ".join(
        f"{b['id']} ({b['label']})" for b in brains if b.get("available")
    )


_VOICE_BRAINS_FILL = _voice_brains_fill()

SET_VOICE_BRAIN = Skill(
    declaration={
        "name": "set_voice_brain",
        "description": _prompt("set_voice_brain", VOICE_BRAINS=_VOICE_BRAINS_FILL),
        "parameters": {
            "type": "object",
            "properties": {"brain": {"type": "string"}},
            "required": ["brain"],
        },
    },
    bind=_bind_set_voice_brain,
)

# --- declarations -------------------------------------------------------------

_BRAINS_FILL = ", ".join(f"{bid} ({label})" for bid, label in _brain_catalog().items())
_MODES_FILL = ", ".join(voice_catalog.MODES)
# Built from the static catalog builder (empty sources → no LiveKit network at
# import): the always-present Gemini Live entry is the realtime default.
_REALTIME_DEFAULT_FILL = str(voice_catalog._realtime_models({})[0]["label"])


def _credited_providers(models: tuple[str, ...]) -> str:
    """The provider names of ``models`` that carry LiveKit credits (so are
    offered), for a prompt hint. Config-only — no LiveKit network at import; the
    tool's resolver re-validates against the live catalog at call time.
    Cartesia is offered only when genuinely enabled (``CARTESIA_API_KEY``
    wired): staging credits the provider but has no key yet, and an inactive
    Cartesia must not appear in any list — not even this one (founder ruling
    2026-11-05)."""
    out: list[str] = []
    for m in models:
        prov = m.split("/", 1)[0] if "/" in m else m
        if prov == "cartesia" and not voice_catalog.cartesia_enabled():
            continue
        if prov in voice_catalog.CONFIG.voice_credited_providers and prov not in out:
            out.append(prov)
    return ", ".join(out)


_STT_ENGINES_FILL = _credited_providers(voice_catalog.CONFIG.voice_cascade_stt_models)
_TTS_ENGINES_FILL = _credited_providers(voice_catalog.CONFIG.voice_cascade_tts_models)

SET_BRAIN = Skill(
    declaration={
        "name": "set_brain",
        "description": _prompt("set_brain", BRAINS=_BRAINS_FILL),
        "parameters": {
            "type": "object",
            "properties": {"brain": {"type": "string"}},
            "required": ["brain"],
        },
    },
    bind=_bind_set_brain,
)

SET_VOICE_MODE = Skill(
    declaration={
        "name": "set_voice_mode",
        "description": _prompt("set_voice_mode", MODES=_MODES_FILL),
        "parameters": {
            "type": "object",
            "properties": {"mode": {"type": "string"}},
            "required": ["mode"],
        },
    },
    bind=_bind_set_voice_mode,
)

SET_REALTIME_MODEL = Skill(
    declaration={
        "name": "set_realtime_model",
        "description": _prompt(
            "set_realtime_model", DEFAULT_MODEL=_REALTIME_DEFAULT_FILL
        ),
        "parameters": {
            "type": "object",
            "properties": {"model": {"type": "string"}},
            "required": ["model"],
        },
    },
    bind=_bind_set_realtime_model,
)

SET_STT = Skill(
    declaration={
        "name": "set_stt",
        "description": _prompt("set_stt", STT_ENGINES=_STT_ENGINES_FILL),
        "parameters": {
            "type": "object",
            "properties": {"engine": {"type": "string"}},
            "required": ["engine"],
        },
    },
    bind=_bind_set_stt,
)

SET_TTS = Skill(
    declaration={
        "name": "set_tts",
        "description": _prompt("set_tts", TTS_ENGINES=_TTS_ENGINES_FILL),
        "parameters": {
            "type": "object",
            "properties": {"engine": {"type": "string"}},
            "required": ["engine"],
        },
    },
    bind=_bind_set_tts,
)

RECONNECT_VOICE = Skill(
    declaration={
        "name": "reconnect_voice",
        "description": _prompt("reconnect_voice"),
        "parameters": {"type": "object", "properties": {}},
    },
    bind=_bind_reconnect_voice,
)

SKILLS: list[Skill] = [
    SET_BRAIN, SET_VOICE_BRAIN, SET_VOICE_MODE, SET_REALTIME_MODEL, SET_STT,
    SET_TTS, RECONNECT_VOICE,
]
