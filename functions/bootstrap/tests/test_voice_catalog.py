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
    assert "fishaudio/s2.1-pro" in [t["id"] for t in cat["tts"]]
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


def test_fallback_lists_credited_providers_with_types(monkeypatch):
    # /v1/models is empty for this project, so the catalog is the config
    # fallback — assert every credited provider surfaces in the RIGHT dropdown.
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    vc.clear_cache()
    cat = vc.catalog()
    assert cat["source"] == "fallback"

    tts = {t["id"]: t for t in cat["tts"]}
    stt = {s["id"]: s for s in cat["stt"]}
    brains = {b["id"]: b for b in cat["brains"]}

    # Fish Audio (the headline ask) is a TTS, enabled, with its documented
    # sample voices (default + the 7 s2.1-pro voices).
    assert "fishaudio/s2.1-pro" in tts
    assert tts["fishaudio/s2.1-pro"]["provider"] == "fishaudio"
    assert tts["fishaudio/s2.1-pro"]["available"] is True
    fish_voices = {v["id"] for v in tts["fishaudio/s2.1-pro"]["voices"]}
    assert "" in fish_voices  # vendor default, always safe
    assert "bf322df2096a46f18c579d0baa36f41d" in fish_voices  # Adrian

    # Other credited TTS providers, enabled.
    assert tts["rime/coda"]["available"] is True
    assert tts["gradium/default"]["available"] is True
    assert tts["inworld/inworld-tts-1"]["available"] is True

    # Credited STT providers land in the STT dropdown, enabled.
    assert stt["deepgram/nova-3"]["provider"] == "deepgram"
    assert stt["deepgram/nova-3"]["available"] is True
    assert stt["assemblyai/universal-streaming"]["available"] is True

    # Google LLMs land in the brain dropdown, enabled.
    assert brains["google/gemini-3.8-flash"]["route"] == vc.ROUTE_INFERENCE
    assert brains["google/gemini-3.8-flash"]["available"] is True


def test_fallback_marks_uncredited_provider_disabled(monkeypatch):
    # Cartesia is a real LiveKit TTS but NOT in the founder's credited set, so
    # on the fallback path it must be shown disabled (honest "needs enabling")
    # rather than as a pick that would silently fail mid-call.
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    vc.clear_cache()
    cat = vc.catalog()
    cartesia = next(t for t in cat["tts"] if t["id"] == "cartesia/sonic-3")
    assert cartesia["available"] is False
    assert cartesia["requires_secret"]  # a non-empty note


def test_live_catalog_marks_everything_available(monkeypatch):
    # When the live catalog IS populated, it lists exactly what credits enable,
    # so a non-"credited-list" provider from it is still available.
    monkeypatch.setattr(
        vc, "_fetch_livekit_models", lambda: [
            {"id": "cartesia/sonic-3", "type": "TTS"},
            {"id": "fishaudio/s2.1-pro", "type": "TTS"},
        ]
    )
    vc.clear_cache()
    cat = vc.catalog()
    assert cat["source"] == "livekit"
    assert all(t["available"] for t in cat["tts"])


def test_meta_default_is_configured_cascade_not_first_entry(monkeypatch):
    import dataclasses

    cfg = dataclasses.replace(
        vc.CONFIG,
        llm_provider_voice_main=vc.PROVIDER_META,
        meta_cascade_stt_model="assemblyai/universal-streaming",
        meta_cascade_tts_model="rime/coda",
    )
    monkeypatch.setattr(vc, "CONFIG", cfg)
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    vc.clear_cache()
    d = vc.default_selection()
    assert d["stt_id"] == "assemblyai/universal-streaming"
    assert d["tts_id"] == "rime/coda"
    assert d["stt_id"] != cfg.voice_cascade_stt_models[0]
    cat = vc.catalog()
    assert d["stt_id"] in [s["id"] for s in cat["stt"]]
    assert d["tts_id"] in [t["id"] for t in cat["tts"]]


def test_no_pref_default_resolves_to_meta_cascade_hannah(monkeypatch):
    # A user with no saved preference gets the founder's target stack:
    # cascade / Muse Spark / deepgram-nova-3 / fishaudio-s2.1-pro / Hannah.
    import dataclasses

    monkeypatch.setattr(vc, "CONFIG", dataclasses.replace(
        vc.CONFIG,
        llm_provider_voice_main=vc.PROVIDER_META,
        meta_cascade_stt_model="deepgram/nova-3",
        meta_cascade_tts_model="fishaudio/s2.1-pro",
        meta_cascade_tts_voice="9a9cf47702da476aa4629e2506d4a857",  # Hannah
    ))
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    vc.clear_cache()
    d = vc.default_selection()
    assert d["mode"] == vc.MODE_CASCADE
    assert d["realtime_model_id"] == ""
    assert d["brain_id"] == vc.BRAIN_META
    assert d["stt_id"] == "deepgram/nova-3"
    assert d["tts_id"] == "fishaudio/s2.1-pro"
    assert d["voice_id"] == "9a9cf47702da476aa4629e2506d4a857"
    # Hannah is a valid voice id of the default TTS.
    assert d["voice_id"] in vc.tts_voice_ids("fishaudio/s2.1-pro")


def test_configured_models_added_when_missing_from_live(monkeypatch):
    import dataclasses

    monkeypatch.setattr(vc, "CONFIG", dataclasses.replace(
        vc.CONFIG, llm_provider_voice_main=vc.PROVIDER_META,
        meta_cascade_stt_model="deepgram/nova-3",
        meta_cascade_tts_model="inworld/inworld-tts-1"))
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: [
        {"id": "x/stt", "type": "STT"}, {"id": "y/tts", "type": "TTS"}])
    vc.clear_cache()
    cat = vc.catalog()
    assert "deepgram/nova-3" in [s["id"] for s in cat["stt"]]
    assert "inworld/inworld-tts-1" in [t["id"] for t in cat["tts"]]


# --- accent capability (§13.9) ----------------------------------------------
def test_provider_supports_accent_only_for_instruction_driven_realtime():
    # Instruction-driven native-audio realtime providers honour a free-text
    # accent; the fixed-voice cascade TTS providers (and the bare default) do not.
    assert vc.provider_supports_accent("gemini") is True
    assert vc.provider_supports_accent("openai") is True
    assert vc.provider_supports_accent("OpenAI") is True  # case-insensitive
    for p in ("fishaudio", "inworld", "rime", "gradium", "cartesia", ""):
        assert vc.provider_supports_accent(p) is False


def test_catalog_entries_carry_supports_accent():
    cat = vc.catalog()
    gemini = next(m for m in cat["realtime_models"] if m["id"] == vc.REALTIME_GEMINI)
    assert gemini["supports_accent"] is True
    # Every cascade TTS (fixed voices) advertises supports_accent False.
    assert cat["tts"], "expected at least one TTS in the fallback catalog"
    assert all(t["supports_accent"] is False for t in cat["tts"])


def test_runtime_voices_supports_accent_matches_provider():
    rt = vc.runtime_voices(mode=vc.MODE_REALTIME, realtime_model_id=vc.REALTIME_GEMINI)
    assert rt.provider == "gemini" and rt.supports_accent is True
    casc = vc.runtime_voices(mode=vc.MODE_CASCADE, tts_id="fishaudio/s2.1-pro")
    assert casc.provider == "fishaudio" and casc.supports_accent is False


def test_accent_supported_resolves_saved_stack(monkeypatch):
    import schema
    # A saved cascade (fixed-voice) stack does not support accent...
    cascade_prof = {
        schema.PF_AYMA_VOICE_MODE: vc.MODE_CASCADE,
        schema.PF_AYMA_CASCADE_TTS: "fishaudio/s2.1-pro",
    }
    assert vc.accent_supported(cascade_prof) is False
    # ...a saved Gemini Live realtime stack does.
    realtime_prof = {
        schema.PF_AYMA_VOICE_MODE: vc.MODE_REALTIME,
        schema.PF_AYMA_REALTIME_MODEL: vc.REALTIME_GEMINI,
    }
    assert vc.accent_supported(realtime_prof) is True
