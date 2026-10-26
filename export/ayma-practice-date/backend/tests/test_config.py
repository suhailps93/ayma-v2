"""Config: the hackathon-new Meta voice-cascade + per-surface provider defaults.

Extracted from Ayma's private ``tests/test_config.py`` — only the cascade /
provider cases that cover hackathon-new config fields are included here (the
Gemini-live model cases in the private suite are pre-existing work and are left
out). These run against the extracted ``config.py`` with no private core.
"""

import config


def test_voice_surface_defaults_to_gemini(monkeypatch):
    # The Meta voice cascade is behind LLM_PROVIDER_VOICE — the default MUST
    # stay gemini so the flip never changes default voice behaviour.
    monkeypatch.delenv("LLM_PROVIDER_VOICE", raising=False)
    monkeypatch.delenv("LLM_PROVIDER", raising=False)
    cfg = config._load()
    assert cfg.llm_provider_voice == "gemini"


def test_meta_cascade_defaults(monkeypatch):
    for var in (
        "META_CASCADE_TTS_MODEL",
        "META_CASCADE_TTS_VOICE",
        "META_CASCADE_VAD_MODEL",
    ):
        monkeypatch.delenv(var, raising=False)
    cfg = config._load()
    # TTS vendor + voice + VAD live in config so the flag can reach them.
    assert cfg.meta_cascade_tts_model == "inworld/inworld-tts-1"
    assert cfg.meta_cascade_tts_voice == ""
    assert cfg.meta_cascade_vad_model == "silero"


def test_meta_cascade_tts_vendor_is_env_overridable(monkeypatch):
    monkeypatch.setenv("META_CASCADE_TTS_MODEL", "rime/mistv2")
    monkeypatch.setenv("META_CASCADE_TTS_VOICE", "cove")
    cfg = config._load()
    assert cfg.meta_cascade_tts_model == "rime/mistv2"
    assert cfg.meta_cascade_tts_voice == "cove"


def test_every_surface_defaults_to_gemini(monkeypatch):
    # Production behaviour is unchanged until a surface is explicitly flipped.
    for var in (
        "LLM_PROVIDER", "LLM_PROVIDER_CHAT", "LLM_PROVIDER_MATCHING",
        "LLM_PROVIDER_REPORTS", "LLM_PROVIDER_PRACTICE", "LLM_PROVIDER_VOICE",
    ):
        monkeypatch.delenv(var, raising=False)
    cfg = config._load()
    assert cfg.llm_provider_chat == "gemini"
    assert cfg.llm_provider_matching == "gemini"
    assert cfg.llm_provider_reports == "gemini"
    assert cfg.llm_provider_practice == "gemini"
    assert cfg.llm_provider_voice == "gemini"


def test_meta_model_ids_have_the_locked_defaults(monkeypatch):
    for var in ("META_CHAT_MODEL", "META_TRANSCRIBE_MODEL", "META_OPEN_WEIGHTS_MODEL"):
        monkeypatch.delenv(var, raising=False)
    cfg = config._load()
    assert cfg.meta_chat_model == "muse-spark-1.3"
    assert cfg.meta_transcribe_model == "muse-voice-transcribe-1.0"
    assert cfg.meta_open_weights_model == "meta-models/muse-spark-open-1026"
