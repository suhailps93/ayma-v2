"""Voice live-model selection (config._load): the 2026-09-26 upgrade of the
Dev-API voice model to `gemini-3.8-live` (Google marks the old
`gemini-3.1-flash-live-preview` "Legacy — update to Gemini 3.8 Live"), with
rollback as a pure config flip — GEMINI_LIVE_DEV_MODEL — and no code deploy.
"""

import config


def test_dev_live_model_defaults_to_3_8_live(monkeypatch):
    monkeypatch.delenv("GEMINI_LIVE_DEV_MODEL", raising=False)
    cfg = config._load()
    assert cfg.gemini_live_dev_model == "gemini-3.8-live"


def test_dev_live_model_env_override_is_the_rollback_lever(monkeypatch):
    monkeypatch.setenv(
        "GEMINI_LIVE_DEV_MODEL", "gemini-3.1-flash-live-preview"
    )
    cfg = config._load()
    assert cfg.gemini_live_dev_model == "gemini-3.1-flash-live-preview"


def test_vertex_live_model_default_unchanged(monkeypatch):
    # The Vertex fallback path (GEMINI_LIVE_USE_DEV_API=false) is untouched
    # by the 3.8 upgrade.
    monkeypatch.delenv("GEMINI_LIVE_MODEL", raising=False)
    cfg = config._load()
    assert cfg.gemini_live_model == "gemini-live-2.5-flash-native-audio"


def test_voice_surface_defaults_to_gemini(monkeypatch):
    # The Meta voice cascade is behind LLM_PROVIDER_VOICE — the default MUST
    # stay gemini so the flip never changes default voice behaviour.
    monkeypatch.delenv("LLM_PROVIDER_VOICE", raising=False)
    monkeypatch.delenv("LLM_PROVIDER", raising=False)
    cfg = config._load()
    assert cfg.llm_provider_voice == "gemini"


def test_dm_coach_surface_defaults_to_meta(monkeypatch):
    # Founder directive: the DM assistant runs on Muse, so this one surface
    # defaults to meta (unlike every other surface).
    monkeypatch.delenv("LLM_PROVIDER_DM_COACH", raising=False)
    monkeypatch.delenv("LLM_PROVIDER", raising=False)
    cfg = config._load()
    assert cfg.llm_provider_dm_coach == "meta"


def test_dm_coach_surface_honours_explicit_override(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER_DM_COACH", "gemini")
    cfg = config._load()
    assert cfg.llm_provider_dm_coach == "gemini"


def test_meta_cascade_defaults(monkeypatch):
    for var in (
        "META_CASCADE_TTS_MODEL",
        "META_CASCADE_TTS_VOICE",
        "META_CASCADE_TTS_VOICE_FEMALE",
        "META_CASCADE_TTS_VOICE_MALE",
        "META_CASCADE_VAD_MODEL",
    ):
        monkeypatch.delenv(var, raising=False)
    cfg = config._load()
    # TTS vendor + voice + VAD live in config so the flag can reach them.
    # Default TTS is Fish Audio s2.1-pro, voice Hannah (the founder's selected
    # default). Fish Audio voices are addressed by id, so the voice is Hannah's
    # documented id, not the label.
    assert cfg.meta_cascade_tts_model == "fishaudio/s2.1-pro"
    assert cfg.meta_cascade_tts_voice == "9a9cf47702da476aa4629e2506d4a857"
    # Gender-matched cascade voices default to real Fish Audio voice ids so
    # female personas sound female (Hannah) and male personas sound male (Adrian).
    assert cfg.meta_cascade_tts_voice_female == "9a9cf47702da476aa4629e2506d4a857"
    assert cfg.meta_cascade_tts_voice_male == "bf322df2096a46f18c579d0baa36f41d"
    assert cfg.meta_cascade_vad_model == "silero"


def test_main_voice_defaults_to_gemini_live(monkeypatch):
    # QLOO-PHASE directive: Qloo is judged before Meta, so a user with no saved
    # voice preference gets the best-experience stack — the locked Gemini Live
    # native-audio voice (Realtime). Flips back to the Meta cascade post-Qloo.
    monkeypatch.delenv("LLM_PROVIDER_VOICE_MAIN", raising=False)
    monkeypatch.delenv("LLM_PROVIDER", raising=False)
    cfg = config._load()
    assert cfg.llm_provider_voice_main == "gemini"


def test_main_voice_honours_explicit_meta_override(monkeypatch):
    monkeypatch.setenv("LLM_PROVIDER_VOICE_MAIN", "meta")
    cfg = config._load()
    assert cfg.llm_provider_voice_main == "meta"


def test_meta_cascade_tts_vendor_is_env_overridable(monkeypatch):
    monkeypatch.setenv("META_CASCADE_TTS_MODEL", "rime/mistv2")
    monkeypatch.setenv("META_CASCADE_TTS_VOICE", "cove")
    cfg = config._load()
    assert cfg.meta_cascade_tts_model == "rime/mistv2"
    assert cfg.meta_cascade_tts_voice == "cove"
