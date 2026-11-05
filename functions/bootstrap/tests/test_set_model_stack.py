"""Ayma's self-service model-stack tools (``skills.set_model_stack``): set_brain /
set_voice_mode / set_realtime_model persist to the SAME ``profile/main`` fields
the "Ayma's models" screen writes, and reconnect_voice drives the client command.
"""

from __future__ import annotations

import asyncio
import time

import pytest

import schema
import voice_catalog
from skills import app_control, session_tool_declarations, set_model_stack


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


# --- minimal tuple-keyed fake Firestore (mirrors tests/test_app_control.py) ---

_PROFILE = ("users", "u1", "profile", "main")
_PENDING = ("users", "u1", "app_commands", "pending")
_ACK = ("users", "u1", "app_commands", "ack")


class _Snap:
    def __init__(self, data):
        self._data = data
        self.exists = data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _Doc:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def collection(self, name):
        return _Col(self.store, (*self.key, name))

    def get(self):
        return _Snap(self.store.get(self.key))

    def set(self, patch, merge=False):
        cur = self.store.get(self.key) if merge else None
        self.store[self.key] = {**(cur or {}), **patch}
        # Auto-ack: a client that acks every pending command (ok = store.ok).
        if self.key[-1] == "pending" and getattr(self.store, "ok", None) is not None:
            ack = (*self.key[:-1], "ack")
            self.store[ack] = {"id": patch.get("id"), "ok": self.store.ok}


class _Col:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _Doc(self.store, (*self.key, doc_id))


class _Store(dict):
    def __init__(self, ok=None):
        super().__init__()
        self.ok = ok  # None = never acks; True/False = auto-ack with that ok


class _Db:
    def __init__(self, ok=None):
        self.store = _Store(ok=ok)

    def collection(self, name):
        return _Col(self.store, (name,))


@pytest.fixture(autouse=True)
def _offline_catalog(monkeypatch):
    """Force the voice catalog's documented offline fallback so realtime-model
    validation is deterministic and never hits the LiveKit gateway in tests."""
    monkeypatch.setattr(voice_catalog, "_fetch_livekit_models", lambda: None)
    voice_catalog.clear_cache()
    yield
    voice_catalog.clear_cache()


# --- set_brain ----------------------------------------------------------------


def test_set_brain_muse_persists_the_meta_vendor():
    db = _Db()
    msg = _run(set_model_stack._bind_set_brain(db, "u1")("Muse"))
    assert db.store[_PROFILE][schema.PF_AYMA_BRAIN_MODEL] == "meta"
    assert "Muse Spark" in msg and "saved" in msg


def test_set_brain_gemini_persists_gemini():
    db = _Db()
    _run(set_model_stack._bind_set_brain(db, "u1")("gemini"))
    assert db.store[_PROFILE][schema.PF_AYMA_BRAIN_MODEL] == "gemini"


def test_set_brain_open_weights_is_an_honest_redirect_not_a_write():
    db = _Db()
    msg = _run(set_model_stack._bind_set_brain(db, "u1")("open weights"))
    assert _PROFILE not in db.store  # nothing written
    assert "cascade" in msg.lower()


def test_set_brain_unknown_is_honest_and_writes_nothing():
    db = _Db()
    msg = _run(set_model_stack._bind_set_brain(db, "u1")("banana"))
    assert _PROFILE not in db.store
    assert "isn't an available brain" in msg


# --- set_voice_mode -----------------------------------------------------------


def test_set_voice_mode_cascade():
    db = _Db()
    _run(set_model_stack._bind_set_voice_mode(db, "u1")("cascade"))
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "cascade"


def test_set_voice_mode_text_alias_is_cascade():
    db = _Db()
    _run(set_model_stack._bind_set_voice_mode(db, "u1")("text mode"))
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "cascade"


def test_set_voice_mode_realtime_from_native_audio():
    db = _Db()
    _run(set_model_stack._bind_set_voice_mode(db, "u1")("native audio"))
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "realtime"


def test_set_voice_mode_unknown_is_honest():
    db = _Db()
    msg = _run(set_model_stack._bind_set_voice_mode(db, "u1")("telepathy"))
    assert _PROFILE not in db.store
    assert "isn't a voice mode" in msg


# --- set_realtime_model -------------------------------------------------------


def test_set_realtime_model_gemini_live_sets_model_and_realtime_mode():
    db = _Db()
    msg = _run(set_model_stack._bind_set_realtime_model(db, "u1")("Gemini Live"))
    assert db.store[_PROFILE][schema.PF_AYMA_REALTIME_MODEL] == "gemini-live"
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "realtime"
    assert "saved" in msg


def test_set_realtime_model_unknown_is_honest_and_writes_nothing():
    db = _Db()
    msg = _run(set_model_stack._bind_set_realtime_model(db, "u1")("hal 9000"))
    assert _PROFILE not in db.store
    assert "isn't an available realtime model" in msg


# --- reconnect_voice ----------------------------------------------------------


def test_reconnect_voice_confirms_when_the_client_acks_a_live_call():
    db = _Db(ok=True)  # a live call acks ok=True
    msg = _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert db.store[_PENDING]["action"] == "reconnect_voice"
    assert "Reconnecting now" in msg


def test_reconnect_voice_is_honest_when_no_call_is_live(monkeypatch):
    monkeypatch.setattr(app_control, "_ACK_TIMEOUT_SECONDS", 0.05)
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", 0.01)
    db = _Db(ok=False)  # client acks ok=False — nothing live to reconnect
    msg = _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert "next voice call" in msg


def test_reconnect_voice_is_one_shot_and_does_not_loop():
    # Founder 2026-11-03: the reconnected session is re-seeded with the
    # "reconnect" transcript and fired reconnect_voice AGAIN → infinite loop.
    # The one-shot cooldown guard must make the SECOND call (the fresh session's
    # re-fire) a no-op: no new reconnect command is queued.
    db = _Db(ok=True)
    msg1 = _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert db.store[_PENDING]["action"] == "reconnect_voice"
    assert "Reconnecting now" in msg1
    first_id = db.store[_PENDING]["id"]

    # The fresh session calls it again immediately — must NOT queue a reconnect.
    msg2 = _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert db.store[_PENDING]["id"] == first_id  # no new command queued
    assert "already reconnecting" in msg2.lower()
    assert "reconnecting now" not in msg2.lower()


def test_failed_reconnect_does_not_mark_so_a_later_reconnect_still_works(monkeypatch):
    # A genuinely-failed reconnect (no live call) must not arm the cooldown, so
    # it can't block — nor retry-storm — a real reconnect afterwards.
    monkeypatch.setattr(app_control, "_ACK_TIMEOUT_SECONDS", 0.05)
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", 0.01)
    db = _Db(ok=False)
    _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert (db.store.get(_PROFILE) or {}).get("ayma_reconnect_requested_at") is None


# --- the post-reconnect announcement claim ------------------------------------
#
# A queued reconnect arms a one-shot announcement: the OLD session stays
# silent (agent.py's claim gate), and the continuation session claims this
# to speak the one "I'm back" line at open. The claim must fire exactly
# once, only while the reconnect is fresh, and never for a plain fresh call.


def test_a_queued_reconnect_arms_the_announcement_and_it_claims_once():
    db = _Db(ok=True)
    msg = _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert msg == set_model_stack._RECONNECT_QUEUED_RESULT
    profile = db.store[_PROFILE]
    assert profile["ayma_reconnect_announce_pending"] is True
    assert profile["ayma_reconnect_requested_at"] > 0

    # The continuation session claims it — exactly once.
    assert set_model_stack.claim_reconnect_announcement(db, "u1") is True
    assert db.store[_PROFILE]["ayma_reconnect_announce_pending"] is False
    assert set_model_stack.claim_reconnect_announcement(db, "u1") is False


def test_no_announcement_is_claimed_on_a_fresh_call():
    # Nothing was ever marked: a plain session open must not claim.
    db = _Db(ok=True)
    assert set_model_stack.claim_reconnect_announcement(db, "u1") is False
    assert set_model_stack.claim_reconnect_announcement(db, "") is False


def test_a_failed_reconnect_arms_no_announcement(monkeypatch):
    monkeypatch.setattr(app_control, "_ACK_TIMEOUT_SECONDS", 0.05)
    monkeypatch.setattr(app_control, "_ACK_POLL_SECONDS", 0.01)
    db = _Db(ok=False)  # no live call — nothing was reconnected
    _run(set_model_stack._bind_reconnect_voice(db, "u1")())
    assert set_model_stack.claim_reconnect_announcement(db, "u1") is False


def test_a_stale_announcement_is_cleared_not_claimed():
    # The reconnect was queued long ago but its continuation never opened
    # (or this is a much later call): the flag must not fire the line now.
    db = _Db(ok=True)
    db.store[_PROFILE] = {
        "ayma_reconnect_requested_at": (
            time.time() - set_model_stack._RECONNECT_ANNOUNCE_WINDOW_SECONDS - 60
        ),
        "ayma_reconnect_announce_pending": True,
    }
    assert set_model_stack.claim_reconnect_announcement(db, "u1") is False
    assert db.store[_PROFILE]["ayma_reconnect_announce_pending"] is False


# --- registration -------------------------------------------------------------


@pytest.mark.parametrize("msg,expected", [
    # brain — both directions (the one-way bug was Meta->Gemini)
    ("change back to gemini", ("set_brain", "gemini")),
    ("switch to muse", ("set_brain", "meta")),
    ("switch my brain to gemini", ("set_brain", "gemini")),
    ("use the muse spark brain", ("set_brain", "meta")),
    ("change the brain to meta", ("set_brain", "meta")),
    # voice mode
    ("switch to cascade", ("set_voice_mode", "cascade")),
    ("use cascade mode", ("set_voice_mode", "cascade")),
    ("go to realtime mode", ("set_voice_mode", "realtime")),
    ("switch to text mode", ("set_voice_mode", "cascade")),
    # realtime model
    ("switch to gemini live", ("set_realtime_model", "gemini-live")),
    # STT / TTS engine (Scout misroute bug 2026-11-03): must route to set_stt /
    # set_tts, NEVER set_voice_mode — including when the word is "model" (which
    # contains the substring "mode").
    ("change the speech-to-text to deepgram", ("set_stt", "deepgram/nova-3")),
    ("change the speech-to-text model to deepgram", ("set_stt", "deepgram/nova-3")),
    ("switch my stt to assemblyai",
     ("set_stt", "assemblyai/universal-streaming")),
    ("use deepgram for speech to text", ("set_stt", "deepgram/nova-3")),
    ("change the text-to-speech to inworld", ("set_tts", "inworld/inworld-tts-1")),
    ("switch my tts to fish audio", ("set_tts", "fishaudio/s2.1-pro")),
    ("change the text to speech model to rime", ("set_tts", "rime/coda")),
])
def test_detect_stack_command_matches_clear_commands(msg, expected):
    assert set_model_stack.detect_stack_command(msg) == expected


def test_stt_command_never_misroutes_to_voice_mode():
    # The exact Scout bug: an STT change fired a MODE save. The deterministic
    # intercept must claim it as set_stt, so it can never reach set_voice_mode.
    for msg in (
        "change the speech-to-text to deepgram",
        "change the speech-to-text model to deepgram",
        "switch my STT to AssemblyAI",
    ):
        name, _ = set_model_stack.detect_stack_command(msg)
        assert name == "set_stt", f"{msg!r} misrouted to {name}"


@pytest.mark.parametrize("msg", [
    "I love how you use Gemini at work",   # brand mention, not a command
    "tell me about your brain",            # question, no change verb target
    "change the subject",                  # change verb, no stack target
    "set a reminder for tomorrow",         # unrelated 'set'
    "how does cascade work?",              # no change verb
    "",                                    # empty
])
def test_detect_stack_command_ignores_non_commands(msg):
    assert set_model_stack.detect_stack_command(msg) is None


def test_run_stack_command_writes_the_right_field_both_directions():
    db = _Db()
    msg = _run(set_model_stack.run_stack_command(db, "u1", "set_brain", "meta"))
    assert db.store[_PROFILE][schema.PF_AYMA_BRAIN_MODEL] == "meta"
    assert "Muse Spark" in msg
    # and back again — symmetry (the reported bug)
    msg2 = _run(set_model_stack.run_stack_command(db, "u1", "set_brain", "gemini"))
    assert db.store[_PROFILE][schema.PF_AYMA_BRAIN_MODEL] == "gemini"
    assert "Gemini" in msg2


def test_run_stack_command_voice_mode_and_realtime_model():
    db = _Db()
    _run(set_model_stack.run_stack_command(db, "u1", "set_voice_mode", "cascade"))
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "cascade"
    _run(set_model_stack.run_stack_command(db, "u1", "set_realtime_model", "gemini-live"))
    assert db.store[_PROFILE][schema.PF_AYMA_REALTIME_MODEL] == "gemini-live"


def test_detected_stt_command_persists_the_stt_field_end_to_end():
    # Scout bug end-to-end: "change the speech-to-text to deepgram" → detected as
    # set_stt → run_stack_command WRITES PF_AYMA_CASCADE_STT (the field the
    # "Ayma's models" STT picker watches + re-fetches), NOT the voice mode as if
    # set_voice_mode ran. The page live-updates off this field (voice_engine_
    # control.dart watches ayma_cascade_stt), so persisting it is what the page reflects.
    db = _Db()
    cmd = set_model_stack.detect_stack_command("change the speech-to-text to deepgram")
    assert cmd[0] == "set_stt"
    msg = _run(set_model_stack.run_stack_command(db, "u1", *cmd))
    assert db.store[_PROFILE][schema.PF_AYMA_CASCADE_STT] == "deepgram/nova-3"
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "cascade"
    assert "speech-to-text" in msg
    # The STT write must NOT have been shadowed by a realtime-model/brain write.
    assert schema.PF_AYMA_REALTIME_MODEL not in db.store[_PROFILE]


def test_detected_tts_command_persists_the_tts_field_end_to_end():
    db = _Db()
    cmd = set_model_stack.detect_stack_command("switch my text-to-speech to inworld")
    assert cmd[0] == "set_tts"
    _run(set_model_stack.run_stack_command(db, "u1", *cmd))
    assert db.store[_PROFILE][schema.PF_AYMA_CASCADE_TTS] == "inworld/inworld-tts-1"
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "cascade"


# --- set_stt / set_tts (cascade engines) --------------------------------------


def test_set_stt_deepgram_persists_and_sets_cascade_mode():
    db = _Db()
    msg = _run(set_model_stack._bind_set_stt(db, "u1")("deepgram"))
    assert db.store[_PROFILE][schema.PF_AYMA_CASCADE_STT] == "deepgram/nova-3"
    # STT only applies in cascade mode, so the mode is set too (it would have no
    # effect otherwise).
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "cascade"
    assert "speech-to-text" in msg and "saved" in msg


def test_set_stt_resolves_by_model_fragment():
    db = _Db()
    _run(set_model_stack._bind_set_stt(db, "u1")("nova-3"))
    assert db.store[_PROFILE][schema.PF_AYMA_CASCADE_STT] == "deepgram/nova-3"


def test_set_stt_assemblyai_persists():
    db = _Db()
    _run(set_model_stack._bind_set_stt(db, "u1")("AssemblyAI"))
    assert db.store[_PROFILE][schema.PF_AYMA_CASCADE_STT] == "assemblyai/universal-streaming"


def test_set_tts_inworld_persists_and_sets_cascade_mode():
    db = _Db()
    msg = _run(set_model_stack._bind_set_tts(db, "u1")("inworld"))
    assert db.store[_PROFILE][schema.PF_AYMA_CASCADE_TTS] == "inworld/inworld-tts-1"
    assert db.store[_PROFILE][schema.PF_AYMA_VOICE_MODE] == "cascade"
    assert "text-to-speech" in msg


def test_set_tts_fish_audio_with_a_space_resolves():
    db = _Db()
    _run(set_model_stack._bind_set_tts(db, "u1")("Fish Audio"))
    assert db.store[_PROFILE][schema.PF_AYMA_CASCADE_TTS] == "fishaudio/s2.1-pro"


def test_set_tts_uncredited_provider_is_honest_and_writes_nothing(monkeypatch):
    # Cartesia is inactive here (no key wired, not credited), so selecting it
    # must be refused with an honest reason — never silently picked.
    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    voice_catalog.clear_cache()
    db = _Db()
    msg = _run(set_model_stack._bind_set_tts(db, "u1")("cartesia"))
    assert _PROFILE not in db.store
    assert "cartesia" in msg.lower()
    assert "inworld" in msg.lower()  # names the ones that DO work


def test_set_tts_key_wired_but_uncredited_is_honest_and_writes_nothing(monkeypatch):
    # Key wired but the provider not credited: still refused honestly
    # (defense in depth) — never silently picked.
    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
    voice_catalog.clear_cache()
    try:
        db = _Db()
        msg = _run(set_model_stack._bind_set_tts(db, "u1")("cartesia"))
    finally:
        voice_catalog.clear_cache()
    assert _PROFILE not in db.store
    assert "cartesia" in msg.lower()
    assert "needs" in msg.lower()  # the honest "needs LiveKit credits" reason
    assert "inworld" in msg.lower()  # names the ones that DO work


def test_credited_providers_fill_gates_cartesia_on_the_key(monkeypatch):
    # The set_stt/set_tts tool descriptions' option lists inherit the gate: a
    # credited-but-keyless cartesia is not offered; key-wired it is.
    import dataclasses

    monkeypatch.setattr(voice_catalog, "CONFIG", dataclasses.replace(
        voice_catalog.CONFIG, voice_credited_providers=(
            *voice_catalog.CONFIG.voice_credited_providers, "cartesia",
        ),
    ))
    models = ("deepgram/nova-3", "cartesia/ink-2")
    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    assert set_model_stack._credited_providers(models) == "deepgram"
    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
    assert set_model_stack._credited_providers(models) == "deepgram, cartesia"


def test_set_stt_unknown_is_honest_and_writes_nothing():
    db = _Db()
    msg = _run(set_model_stack._bind_set_stt(db, "u1")("telepathy"))
    assert _PROFILE not in db.store
    assert "isn't an available engine" in msg


def test_set_tts_empty_asks_which_engine():
    db = _Db()
    msg = _run(set_model_stack._bind_set_tts(db, "u1")(""))
    assert _PROFILE not in db.store
    assert "which engine" in msg.lower()


def test_all_model_stack_tools_are_registered_for_text_and_voice():
    names = {d["name"] for d in session_tool_declarations()}
    expected = {
        "set_brain", "set_voice_mode", "set_realtime_model",
        "set_stt", "set_tts", "reconnect_voice",
    }
    assert expected <= names
    # _REGISTRY feeds BOTH session_tool_declarations (text) and make_livekit_tools
    # (voice), so membership here is membership in the voice tool set too.
    import skills

    reg = {s.name for s in skills._REGISTRY}
    assert expected <= reg


# --- set_voice_brain (the brain under Voice) ---------------------------------
#
# The two-brain fix (founder, 2026-11-03): an "under voice" ask must reach the
# CASCADE voice brain (open weights included when enabled), never the main
# brain's catalog, and the two settings must never bleed into each other.


def test_detect_under_voice_open_weights_routes_to_voice_brain():
    # The founder's verbatim Beat-7 / live phrasings.
    assert set_model_stack.detect_stack_command(
        "Under voice, can you change the brain to open weight model?"
    ) == ("set_voice_brain", voice_catalog.BRAIN_OPEN_WEIGHTS)
    assert set_model_stack.detect_stack_command(
        "under Voice, switch the brain to the open-weights model"
    ) == ("set_voice_brain", voice_catalog.BRAIN_OPEN_WEIGHTS)


def test_detect_voice_brain_muse_routes_to_voice_brain():
    assert set_model_stack.detect_stack_command(
        "switch the voice brain to Muse"
    ) == ("set_voice_brain", voice_catalog.BRAIN_META)


def test_detect_bare_brain_stays_main_brain():
    assert set_model_stack.detect_stack_command(
        "switch my brain to Muse"
    ) == ("set_brain", "meta")


def test_set_voice_brain_meta_persists_cascade_brain_and_mode():
    db = _Db()
    msg = _run(set_model_stack._bind_set_voice_brain(db, "u1")("Muse"))
    prof = db.store[_PROFILE]
    assert prof[schema.PF_AYMA_CASCADE_BRAIN] == voice_catalog.BRAIN_META
    assert prof[schema.PF_AYMA_VOICE_MODE] == "cascade"
    assert schema.PF_AYMA_BRAIN_MODEL not in prof  # main brain untouched
    assert "voice brain" in msg and "main brain is unchanged" in msg


def test_set_voice_brain_open_weights_persists_when_enabled():
    if not voice_catalog.CONFIG.open_weights_api_base_url:
        pytest.skip("open weights not configured in this environment")
    db = _Db()
    msg = _run(set_model_stack._bind_set_voice_brain(db, "u1")("open weights"))
    prof = db.store[_PROFILE]
    assert prof[schema.PF_AYMA_CASCADE_BRAIN] == voice_catalog.BRAIN_OPEN_WEIGHTS
    assert "Llama" in msg and "brain under Voice" in msg


def test_open_weights_voice_brain_not_offered_when_disabled(monkeypatch):
    import dataclasses

    monkeypatch.setattr(
        voice_catalog, "CONFIG",
        dataclasses.replace(
            voice_catalog.CONFIG, open_weights_api_base_url=""),
    )
    voice_catalog.clear_cache()
    try:
        brain_id, reason = set_model_stack._resolve_voice_brain("open weights")
        assert brain_id is None
        offered = reason.rsplit("voice brains are:", 1)[-1]
        assert "Llama" not in offered and "open" not in offered.lower()
        ctx = set_model_stack.model_stack_context(_Db(), "u1")
        assert "Llama 3.1 8B" not in ctx
    finally:
        voice_catalog.clear_cache()


def test_run_stack_command_voice_brain_end_to_end():
    db = _Db()
    msg = _run(set_model_stack.run_stack_command(
        db, "u1", "set_voice_brain", voice_catalog.BRAIN_META))
    assert db.store[_PROFILE][schema.PF_AYMA_CASCADE_BRAIN] == voice_catalog.BRAIN_META
    assert "voice brain" in msg


def test_model_stack_context_carries_both_brains_with_current_values():
    db = _Db()
    db.store[_PROFILE] = {
        schema.PF_AYMA_BRAIN_MODEL: "gemini",
        schema.PF_AYMA_VOICE_MODE: "cascade",
        schema.PF_AYMA_CASCADE_BRAIN: voice_catalog.BRAIN_META,
    }
    ctx = set_model_stack.model_stack_context(db, "u1")
    assert "Main brain" in ctx and "Gemini" in ctx
    assert "brain under Voice" in ctx and "Meta Muse Spark" in ctx
    if voice_catalog.CONFIG.open_weights_api_base_url:
        assert "Llama 3.1 8B" in ctx  # enabled -> offered as a voice brain


def test_open_weights_voice_brain_offered_and_persists_when_enabled(monkeypatch):
    import dataclasses

    monkeypatch.setattr(
        voice_catalog, "CONFIG",
        dataclasses.replace(
            voice_catalog.CONFIG,
            open_weights_api_base_url="http://localhost:0/v1"),
    )
    voice_catalog.clear_cache()
    try:
        brain_id, reason = set_model_stack._resolve_voice_brain("open weights")
        assert brain_id == voice_catalog.BRAIN_OPEN_WEIGHTS, reason
        db = _Db()
        msg = _run(set_model_stack.run_stack_command(
            db, "u1", *set_model_stack.detect_stack_command(
                "under Voice, switch the brain to the open-weights model")))
        prof = db.store[_PROFILE]
        assert prof[schema.PF_AYMA_CASCADE_BRAIN] == voice_catalog.BRAIN_OPEN_WEIGHTS
        assert prof[schema.PF_AYMA_VOICE_MODE] == "cascade"
        assert schema.PF_AYMA_BRAIN_MODEL not in prof
        assert "Llama" in msg
        ctx = set_model_stack.model_stack_context(_Db(), "u1")
        assert "Llama 3.1 8B" in ctx  # enabled -> offered in her context
    finally:
        voice_catalog.clear_cache()
