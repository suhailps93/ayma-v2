"""`voice_catalog` — the LIVE LiveKit inference catalog fetch + categorization,
and the fallback to config (§13.9)."""

import voice_catalog as vc


def setup_function(_):
    vc.clear_cache()


def teardown_function(_):
    vc.clear_cache()


def test_categorize_live_buckets_by_type():
    items = [
        {"id": "deepgram/nova-3", "type": "STT"},
        {"id": "assemblyai/universal-streaming", "type": "stt"},
        {"id": "inworld/inworld-tts-1.5-mini", "type": "TTS"},
        {"id": "fishaudio/s2.1-pro", "type": "tts"},
        {"id": "google/gemini-3.8-flash", "type": "LLM"},
        {"id": "x/turn-detector", "type": "TD"},     # ignored
        {"id": "y/interrupt", "type": "INT"},        # ignored
    ]
    cat = vc._categorize_live(items)
    assert cat["stt"] == ["deepgram/nova-3", "assemblyai/universal-streaming"]
    assert cat["tts"] == ["inworld/inworld-tts-1.5-mini", "fishaudio/s2.1-pro"]
    assert cat["llm"] == ["google/gemini-3.8-flash"]


def test_categorize_live_none_when_no_types():
    # Unknown shape (no TYPE on any item) → fall back rather than misclassify.
    assert vc._categorize_live([{"id": "a"}, {"id": "b"}]) is None


def test_catalog_uses_live_when_fetch_succeeds(monkeypatch):
    monkeypatch.setattr(
        vc, "_fetch_livekit_models", lambda: [
            {"id": "deepgram/nova-3", "type": "STT"},
            {"id": "fishaudio/s2.1-pro", "type": "TTS"},
            {"id": "google/gemini-3.7-flash", "type": "LLM"},
            {"id": "cartesia/sonic-realtime", "type": "realtime"},
        ]
    )
    vc.clear_cache()
    cat = vc.catalog()
    assert cat["source"] == "livekit"
    assert [s["id"] for s in cat["stt"]] == ["deepgram/nova-3"]
    assert [t["id"] for t in cat["tts"]] == ["fishaudio/s2.1-pro"]
    brain_ids = [b["id"] for b in cat["brains"]]
    # Meta Muse (direct API) is merged on top of the live LLM list.
    assert "meta-muse-spark" in brain_ids
    assert "google/gemini-3.7-flash" in brain_ids
    # A non-google/non-openai realtime model from the catalog is selectable.
    assert any(m["id"] == "cartesia/sonic-realtime" for m in cat["realtime_models"])
    # Gemini Live is always present; new TTS get their fallback voice list.
    assert any(m["id"] == "gemini-live" for m in cat["realtime_models"])


def test_catalog_falls_back_when_fetch_fails(monkeypatch):
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    vc.clear_cache()
    cat = vc.catalog()
    assert cat["source"] == "fallback"
    assert [s["id"] for s in cat["stt"]] == list(vc.CONFIG.voice_cascade_stt_models)
    assert any(b["id"] == "meta-muse-spark" for b in cat["brains"])


def test_meta_never_a_realtime_model(monkeypatch):
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    vc.clear_cache()
    assert not vc.is_valid_realtime_model("meta-muse-spark")
    assert vc.is_valid_brain("meta-muse-spark")


def test_brain_route_meta_vs_inference(monkeypatch):
    monkeypatch.setattr(
        vc, "_fetch_livekit_models", lambda: [
            {"id": "google/gemini-3.8-flash", "type": "LLM"},
        ]
    )
    vc.clear_cache()
    assert vc.brain_route("meta-muse-spark") == (vc.ROUTE_META, vc.CONFIG.meta_chat_model)
    assert vc.brain_route("google/gemini-3.8-flash") == (
        vc.ROUTE_INFERENCE, "google/gemini-3.8-flash",
    )
    assert vc.brain_route("nope") is None


def test_tts_voices_fallback_inworld():
    ids = vc.tts_voice_ids("inworld/inworld-tts-1")
    assert "" in ids and "Ashley" in ids
