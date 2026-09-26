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
