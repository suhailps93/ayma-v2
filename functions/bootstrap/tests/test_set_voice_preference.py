import voices
from skills import make_session_tool_fns, session_tool_declarations
from skills.set_voice_preference import _closest_preset


class _Chain:
    """collection().document().collection().document().set() -> captures."""

    def __init__(self):
        self.written = {}

    def collection(self, _):
        return self

    def document(self, _):
        return self

    def set(self, payload, merge=False):
        self.written.update(payload)


def _fn(db):
    return make_session_tool_fns(db, "u1")["set_voice_preference"]


def test_closest_preset_keyword_mapping():
    assert _closest_preset("can you sound deeper, more masculine") == "Charon"
    assert _closest_preset("something softer and calmer please") == "Zephyr"
    assert _closest_preset("a younger, brighter voice") == "Leda"
    assert _closest_preset("more playful and energetic") == "Puck"
    assert _closest_preset("just a warm friendly voice") == "Aoede"
    assert _closest_preset("???") is None
    assert voices.is_valid_voice(_closest_preset("deeper"))


def test_gendered_descriptors_resolve_to_a_concrete_preset():
    assert _closest_preset("use a female voice") == "Kore"
    assert _closest_preset("can you be a woman") == "Kore"
    assert _closest_preset("sound more feminine") == "Kore"
    assert _closest_preset("a man's voice please") == "Charon"
    assert _closest_preset("more masculine") == "Charon"


def test_explicit_voice_name_bypasses_keyword_matching():
    db = _Chain()
    msg = _fn(db)(request="whatever", voice_name="Leda")
    assert db.written["ayma_voice_name"] == "Leda"
    assert "next" in msg


def test_accent_only_change_is_immediate_wording():
    db = _Chain()
    msg = _fn(db)(accent_language="an Irish accent")
    assert db.written["ayma_voice_language"] == "an Irish accent"
    assert "now" in msg or "immediately" in msg
    assert "next voice call" not in msg


def test_character_change_says_next_call():
    db = _Chain()
    msg = _fn(db)(request="a deeper voice")
    assert "next" in msg


def test_skill_is_registered_and_sets_the_voice_character():
    assert any(
        d["name"] == "set_voice_preference" for d in session_tool_declarations()
    )
    db = _Chain()
    msg = _fn(db)(request="please sound deeper and more masculine")
    assert db.written["ayma_voice_name"] == "Charon"
    assert "ayma_voice_language" not in db.written
    assert "next voice call" in msg


def test_skill_stores_the_accent_language_verbatim():
    db = _Chain()
    _fn(db)(accent_language="Malayalam mixed with English")
    assert db.written["ayma_voice_language"] == "Malayalam mixed with English"
    assert "ayma_voice_name" not in db.written


def test_skill_can_set_both_at_once():
    db = _Chain()
    _fn(db)(request="a deeper voice", accent_language="a soft Southern US accent")
    assert db.written["ayma_voice_name"] == "Charon"
    assert db.written["ayma_voice_language"] == "a soft Southern US accent"


def test_skill_declines_when_given_neither():
    class _NoWrite(_Chain):
        def set(self, *a, **k):
            raise AssertionError("should not write")

    assert "couldn't tell" in _fn(_NoWrite())(request="the weather is nice")
    assert "couldn't tell" in _fn(_NoWrite())()


def test_looks_like_bcp47():
    assert voices.looks_like_bcp47("en-GB")
    assert voices.looks_like_bcp47("cmn-CN")
    assert not voices.looks_like_bcp47("a Southern US accent")
    assert not voices.looks_like_bcp47("")


# --- voices.bcp47_hint -------------------------------------------------

import voices  # noqa: E402


def test_bcp47_hint_maps_free_text_to_a_code():
    assert voices.bcp47_hint("Malayalam mixed with English") == "ml-IN"
    assert voices.bcp47_hint("manglish") == "ml-IN"
    assert voices.bcp47_hint("Hindi") == "hi-IN"
    assert voices.bcp47_hint("a soft Southern US accent") == "en-US"
    assert voices.bcp47_hint("British RP") == "en-GB"
    assert voices.bcp47_hint("en-AU") == "en-AU"  # already a tag
    assert voices.bcp47_hint("") is None
    assert voices.bcp47_hint("something unrecognisable") is None


# --- dedicated free-text ACCENT + accent-switch messaging (§13.9) ------------
import voice_catalog  # noqa: E402
from skills import set_voice_preference as svp  # noqa: E402


class _ProfChain(_Chain):
    """``_Chain`` that also answers ``.get()`` with a fixed saved profile, for the
    text-chat accent gate (which reads the saved stack)."""

    def __init__(self, profile=None):
        super().__init__()
        self._profile = profile or {}

    def get(self):
        chain = self

        class _Snap:
            def to_dict(self):
                return dict(chain._profile)

        return _Snap()


def _rv_gemini():
    return voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_REALTIME,
        realtime_model_id=voice_catalog.REALTIME_GEMINI,
    )


def _rv_fish():
    return voice_catalog.runtime_voices(
        mode=voice_catalog.MODE_CASCADE, tts_id="fishaudio/s2.1-pro",
    )


def test_accent_persists_on_an_accent_capable_live_model():
    # Live contract (accent hot-swap 2026-11-01): the accent is persisted AND
    # routed through the hot-swap hook, and the reply is the hook's live
    # detail — no more "next call" clause on a live call.
    db = _Chain()
    calls = []

    def _hook(preset, accent, *, voice_accent=None):
        calls.append((preset, accent, voice_accent))
        return False, f"accent → {voice_accent} (already current)"

    msg = svp.bind_live(db, "u1", _hook)(accent="a southern American accent")
    assert calls == [(None, "", "a southern American accent")]
    assert db.written[voices.PF_AYMA_VOICE_ACCENT] == "a southern American accent"
    assert "southern American accent" in msg
    assert "can't change its accent" not in msg
    assert "next" not in msg


def test_accent_switch_on_fixed_voice_stack_tells_user_to_switch_models():
    db = _Chain()
    msg = svp.bind_stack(db, "u1", _rv_fish())(accent="a California accent")
    # Nothing saved — the model can't do it, so we don't pretend it worked.
    assert voices.PF_AYMA_VOICE_ACCENT not in db.written
    assert "can't change its accent" in msg
    assert "Ayma" in msg  # points at the "Ayma's models" screen


def test_accent_persists_on_an_accent_capable_cascade_when_configured(monkeypatch):
    # If a cascade TTS provider is ever marked accent-capable, the accent saves.
    import dataclasses
    monkeypatch.setattr(voice_catalog, "CONFIG", dataclasses.replace(
        voice_catalog.CONFIG,
        voice_accent_capable_providers=("gemini", "openai", "fishaudio"),
    ))
    db = _Chain()
    msg = svp.bind_stack(db, "u1", _rv_fish())(accent="a British accent")
    assert db.written[voices.PF_AYMA_VOICE_ACCENT] == "a British accent"
    assert "British accent" in msg


def test_text_chat_accent_gated_by_saved_stack():
    import schema
    # Saved fixed-voice cascade -> not supported, nothing saved.
    db = _ProfChain({
        schema.PF_AYMA_VOICE_MODE: voice_catalog.MODE_CASCADE,
        schema.PF_AYMA_CASCADE_TTS: "fishaudio/s2.1-pro",
    })
    msg = db and svp._bind(db, "u1")(accent="an internet accent")
    assert voices.PF_AYMA_VOICE_ACCENT not in db.written
    assert "can't change its accent" in msg
    # Saved Gemini Live realtime -> supported, saved.
    db2 = _ProfChain({
        schema.PF_AYMA_VOICE_MODE: voice_catalog.MODE_REALTIME,
        schema.PF_AYMA_REALTIME_MODEL: voice_catalog.REALTIME_GEMINI,
    })
    svp._bind(db2, "u1")(accent="an internet accent")
    assert db2.written[voices.PF_AYMA_VOICE_ACCENT] == "an internet accent"


def test_accent_and_voice_change_combine_in_one_reply():
    # Live contract (accent hot-swap 2026-11-01): voice + accent ride one hook
    # call and the reply is the hook's combined live detail.
    db = _Chain()
    calls = []

    def _hook(preset, accent, *, voice_accent=None):
        calls.append((preset, accent, voice_accent))
        return False, "voice set; accent → a British accent (switching now)"

    msg = svp.bind_live(db, "u1", _hook)(
        request="a deeper voice", accent="a British accent"
    )
    assert calls == [("Charon", "", "a British accent")]
    assert "British accent" in msg and "voice set" in msg
    assert db.written[voices.PF_AYMA_VOICE_ACCENT] == "a British accent"


def test_language_param_unchanged_by_accent_work():
    # The separate LANGUAGE field is untouched: it still saves verbatim and does
    # not land in the accent field.
    db = _Chain()
    svp._bind(db, "u1")(accent_language="Malayalam mixed with English")
    assert db.written[voices.PF_AYMA_VOICE_LANGUAGE] == "Malayalam mixed with English"
    assert voices.PF_AYMA_VOICE_ACCENT not in db.written
