"""Stack-aware voice vocabulary (§13.9): the voice agent must know the voices
of the stack it is ACTUALLY running — the Gemini presets on Gemini Live, the
active TTS provider's voices on a cascade — report its real current voice, and
switch only within that set. Regression guard for the founder bug where a
fishaudio cascade answered "what voices do you have" with the Gemini presets.
"""

import prompt
import voice_catalog
import voices
from skills import set_voice_preference as svp


# --- voice_catalog.runtime_voices -------------------------------------------
def test_gemini_realtime_stack_lists_the_presets_and_hot_swaps():
    rv = voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_REALTIME,
        realtime_model_id=voice_catalog.REALTIME_GEMINI,
        current_voice_id="Puck",
    )
    labels = {v.label for v in rv.voices}
    assert set(voices.VOICE_PRESETS) <= labels
    assert rv.provider == "gemini"
    assert rv.hot_swap is True
    assert rv.current is not None and rv.current.label == "Puck"


def test_fishaudio_cascade_stack_lists_fishaudio_voices_and_current_is_hannah():
    # Hannah's documented Fish Audio id (voice_catalog._TTS_FALLBACK_VOICES).
    hannah = "9a9cf47702da476aa4629e2506d4a857"
    rv = voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_CASCADE,
        tts_id="fishaudio/s2.1-pro",
        current_voice_id=hannah,
    )
    labels = {v.label for v in rv.voices}
    assert "Hannah" in labels and "Laura" in labels
    # None of the Gemini presets leak into a fishaudio cascade.
    assert not (set(voices.VOICE_PRESETS) & labels)
    assert rv.provider == "fishaudio"
    assert rv.hot_swap is False
    assert rv.current is not None and rv.current.label == "Hannah"


def test_inworld_cascade_stack_lists_inworld_voices():
    rv = voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_CASCADE,
        tts_id="inworld/inworld-tts-1",
        current_voice_id="Ashley",
    )
    labels = {v.label for v in rv.voices}
    assert {"Ashley", "Olivia", "Alex"} <= labels
    assert not (set(voices.VOICE_PRESETS) & labels)
    assert rv.current is not None and rv.current.label == "Ashley"


def test_empty_current_voice_falls_to_the_vendor_default_sentinel():
    rv = voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_CASCADE, tts_id="fishaudio/s2.1-pro",
        current_voice_id="",
    )
    assert rv.current is not None and rv.current.id == ""


# --- voice_catalog.resolve_voice (within the active provider set) -----------
def _fish():
    return list(
        voice_catalog.runtime_voices(
            mode=voice_catalog.MODE_CASCADE, tts_id="fishaudio/s2.1-pro"
        ).voices
    )


def test_resolve_voice_matches_within_the_active_set():
    vs = _fish()
    assert voice_catalog.resolve_voice("use Hannah", vs).label == "Hannah"
    assert voice_catalog.resolve_voice("a female voice", vs).gender == "feminine"
    assert voice_catalog.resolve_voice("a male voice", vs).gender == "masculine"
    # Never returns the bare vendor-default sentinel.
    assert voice_catalog.resolve_voice("??? nothing", vs) is None


def test_resolve_voice_never_returns_a_gemini_preset_for_a_cascade():
    vs = _fish()
    got = voice_catalog.resolve_voice("Puck", vs)
    assert got is None  # Puck is a Gemini preset, not a fishaudio voice


# --- set_voice_preference stack binder --------------------------------------
class _Chain:
    def __init__(self):
        self.written = {}

    def collection(self, _):
        return self

    def document(self, _):
        return self

    def set(self, payload, merge=False):
        self.written.update(payload)


def _rv_fish(current="9a9cf47702da476aa4629e2506d4a857"):
    return voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_CASCADE, tts_id="fishaudio/s2.1-pro",
        current_voice_id=current,
    )


def test_stack_binder_saves_cascade_voice_to_tts_field_for_next_call():
    db = _Chain()
    msg = svp.bind_stack(db, "u1", _rv_fish())(request="a male voice")
    # Persisted as ayma_tts_voice (not the Gemini-preset ayma_voice_name).
    assert "ayma_tts_voice" in db.written and db.written["ayma_tts_voice"]
    assert "ayma_voice_name" not in db.written
    assert "next call" in msg


def test_stack_binder_resolves_an_explicit_cascade_voice_name():
    db = _Chain()
    svp.bind_stack(db, "u1", _rv_fish())(voice_name="Laura")
    laura = "e3cd384158934cc9a01029cd7d278634"
    assert db.written["ayma_tts_voice"] == laura


def test_stack_binder_accent_only_is_immediate():
    db = _Chain()
    msg = svp.bind_stack(db, "u1", _rv_fish())(accent_language="an Irish accent")
    assert db.written["ayma_voice_language"] == "an Irish accent"
    assert "now" in msg and "ayma_tts_voice" not in db.written


def test_stack_description_names_the_provider_voices_not_gemini_presets():
    desc = svp.stack_description(_rv_fish())
    assert "Hannah" in desc and "Laura" in desc
    assert "Aoede" not in desc and "Puck" not in desc
    assert "next call" in desc.lower()


# --- prompt directive -------------------------------------------------------
def test_voice_vocab_directive_reports_current_and_set_and_swap_rule():
    rv = _rv_fish()
    directive = prompt.voice_vocab_directive(
        voice_catalog.current_label(rv),
        voice_catalog.vocab_lines(rv),
        rv.hot_swap,
    )
    assert "Hannah" in directive  # current + in the list
    assert "Laura" in directive
    # A cascade can't hot-swap: the directive says next call, not live.
    assert "NEXT call" in directive


def test_voice_vocab_directive_gemini_says_live():
    rv = voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_REALTIME,
        realtime_model_id=voice_catalog.REALTIME_GEMINI,
        current_voice_id="Aoede",
    )
    directive = prompt.voice_vocab_directive(
        voice_catalog.current_label(rv),
        voice_catalog.vocab_lines(rv),
        rv.hot_swap,
    )
    assert "Aoede" in directive
    assert "live during this call" in directive
