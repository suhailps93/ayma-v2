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
            + "); it's a voice brain you pick in cascade mode"
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


# --- reconnect the live call --------------------------------------------------


def _bind_reconnect_voice(db, uid: str) -> Callable[..., object]:
    async def reconnect_voice() -> str:
        """Ask the client to reconnect the live voice session so the saved stack
        applies now. The client acks ``ok=true`` only when a call is actually
        live, then tears down + re-establishes it (bootstrap re-reads the stack);
        ``ok=false`` means there was nothing live to reconnect."""
        cmd_id = _queue_command(db, uid, {"action": "reconnect_voice"})
        ack = await _await_ack(db, uid, cmd_id)
        if ack and ack.get("ok"):
            return (
                "Reconnecting now — I'll drop for a second and come back on your "
                "updated setup."
            )
        return (
            "There's no live voice call to reconnect right now — your saved "
            "changes will apply on your next voice call."
        )

    return reconnect_voice


# --- declarations -------------------------------------------------------------

_BRAINS_FILL = ", ".join(f"{bid} ({label})" for bid, label in _brain_catalog().items())
_MODES_FILL = ", ".join(voice_catalog.MODES)
# Built from the static catalog builder (empty sources → no LiveKit network at
# import): the always-present Gemini Live entry is the realtime default.
_REALTIME_DEFAULT_FILL = str(voice_catalog._realtime_models({})[0]["label"])

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

RECONNECT_VOICE = Skill(
    declaration={
        "name": "reconnect_voice",
        "description": _prompt("reconnect_voice"),
        "parameters": {"type": "object", "properties": {}},
    },
    bind=_bind_reconnect_voice,
)

SKILLS: list[Skill] = [SET_BRAIN, SET_VOICE_MODE, SET_REALTIME_MODEL, RECONNECT_VOICE]
