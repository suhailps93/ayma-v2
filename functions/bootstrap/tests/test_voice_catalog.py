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
    # The key is wired here (enabled), so the live cartesia realtime entry is
    # served; keyless it is withheld (test_live_catalog_hides_cartesia_...).
    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
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
    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    vc.clear_cache()
    cat = vc.catalog()
    assert cat["source"] == "fallback"
    # Keyless, so the gate withholds the cartesia STT ids from the config list.
    assert [s["id"] for s in cat["stt"]] == [
        m for m in vc.CONFIG.voice_cascade_stt_models if "cartesia" not in m
    ]
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


def test_open_weights_brain_listed_only_when_configured(monkeypatch):
    import dataclasses

    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    # Unset (production): the open-weights brain is NOT offered.
    monkeypatch.setattr(vc, "CONFIG", dataclasses.replace(
        vc.CONFIG, open_weights_api_base_url="", open_weights_model=""))
    vc.clear_cache()
    assert not any(
        b["id"] == vc.BRAIN_OPEN_WEIGHTS for b in vc.catalog()["brains"])

    # Configured (opt-in): it appears, available, with a clear label + route.
    monkeypatch.setattr(vc, "CONFIG", dataclasses.replace(
        vc.CONFIG,
        open_weights_api_base_url="https://modal.example/v1",
        open_weights_model="meta-llama/Llama-3.1-8B-Instruct"))
    vc.clear_cache()
    brains = {b["id"]: b for b in vc.catalog()["brains"]}
    assert vc.BRAIN_OPEN_WEIGHTS in brains
    ow = brains[vc.BRAIN_OPEN_WEIGHTS]
    assert ow["available"] is True
    assert ow["route"] == vc.ROUTE_OPEN_WEIGHTS
    assert ow["provider"] == vc.PROVIDER_OPEN_WEIGHTS
    assert "open weights" in ow["label"].lower()


def test_brain_route_open_weights(monkeypatch):
    import dataclasses

    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    # Unconfigured → unknown brain (route None).
    monkeypatch.setattr(vc, "CONFIG", dataclasses.replace(
        vc.CONFIG, open_weights_api_base_url="", open_weights_model=""))
    vc.clear_cache()
    assert vc.brain_route(vc.BRAIN_OPEN_WEIGHTS) is None

    # Configured → resolves to the open-weights route + config model id.
    monkeypatch.setattr(vc, "CONFIG", dataclasses.replace(
        vc.CONFIG,
        open_weights_api_base_url="https://modal.example/v1",
        open_weights_model="meta-llama/Llama-3.1-8B-Instruct"))
    vc.clear_cache()
    assert vc.brain_route(vc.BRAIN_OPEN_WEIGHTS) == (
        vc.ROUTE_OPEN_WEIGHTS, "meta-llama/Llama-3.1-8B-Instruct")


def test_open_weights_brain_never_the_default(monkeypatch):
    import dataclasses

    # Even with the endpoint configured, the default stack is unchanged — the
    # open-weights brain is opt-in only and never auto-selected as the default.
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    monkeypatch.setattr(vc, "CONFIG", dataclasses.replace(
        vc.CONFIG,
        llm_provider_voice_main=vc.PROVIDER_META,
        open_weights_api_base_url="https://modal.example/v1",
        open_weights_model="meta-llama/Llama-3.1-8B-Instruct"))
    vc.clear_cache()
    d = vc.default_selection()
    assert d["brain_id"] == vc.BRAIN_META
    assert d["brain_id"] != vc.BRAIN_OPEN_WEIGHTS


def test_tts_voices_fallback_inworld():
    ids = vc.tts_voice_ids("inworld/inworld-tts-1")
    assert "" in ids and "Ashley" in ids


def test_cartesia_fallback_voices_are_the_documented_uuids():
    ids = vc.tts_voice_ids("cartesia/sonic-3")
    assert "" in ids  # vendor default, always safe
    assert "f786b574-daa5-4673-aa0c-cbe3e8534c02" in ids  # Katie, plugin dflt
    assert "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4" in ids  # Skylar
    assert "47c38ca4-5f35-497b-b1a3-415245fb35e1" in ids  # Daniel
    assert "9626c31c-bec5-4cca-baa8-f8ba9e84c8bc" in ids  # Jacqueline
    assert "62ae83ad-4f6a-430b-af41-a9bede9286ca" in ids  # Gemma
    assert "ef191366-f52f-447a-a398-ed8c0f2943a1" in ids  # Archie


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
    # A fallback-list provider outside the credited set is still shown
    # disabled (honest "needs enabling") rather than as a silently-failing
    # pick — pinned with a synthetic provider, since cartesia itself is now
    # hidden while disabled (test_fallback_hides_cartesia_while_disabled).
    import dataclasses

    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    monkeypatch.setattr(vc, "CONFIG", dataclasses.replace(
        vc.CONFIG, voice_cascade_tts_models=(
            *vc.CONFIG.voice_cascade_tts_models, "acme/synth-1",
        ),
    ))
    vc.clear_cache()
    cat = vc.catalog()
    synth = next(t for t in cat["tts"] if t["id"] == "acme/synth-1")
    assert synth["available"] is False
    assert synth["requires_secret"]  # a non-empty note


def test_fallback_enables_cartesia_when_credited(monkeypatch):
    # Enabled means credited AND key-wired: staging credits cartesia via the
    # VOICE_CREDITED_PROVIDERS env override (scripts/deploy-staging.sh), and
    # once CARTESIA_API_KEY lands the Sonic TTS + both Ink STT ids show
    # enabled on the fallback path.
    import dataclasses

    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    monkeypatch.setattr(vc, "CONFIG", dataclasses.replace(
        vc.CONFIG, voice_credited_providers=(
            *vc.CONFIG.voice_credited_providers, "cartesia",
        ),
    ))
    vc.clear_cache()
    cat = vc.catalog()
    assert cat["source"] == "fallback"
    cartesia = next(t for t in cat["tts"] if t["id"] == "cartesia/sonic-3")
    assert cartesia["available"] is True
    assert cartesia["requires_secret"] == ""
    stt = {s["id"]: s for s in cat["stt"]}
    assert stt["cartesia/ink-2"]["available"] is True
    assert stt["cartesia/ink-whisper"]["available"] is True


def test_default_credited_providers_are_the_union(monkeypatch):
    # Union corrected 2026-11-06: the committed default must match the
    # live staging list (deepgram, elevenlabs, openai, google, cartesia,
    # inworld, fishaudio, rime, gradium) plus the previously committed
    # assemblyai — no entries dropped, so a deploy with no env override
    # cannot regress the cascade TTS providers to unavailable.
    assert set(vc.CONFIG.voice_credited_providers) == {
        "inworld", "deepgram", "fishaudio", "assemblyai", "rime",
        "gradium", "google", "elevenlabs", "openai", "cartesia",
    }


def test_fallback_omits_cartesia_stt_while_keyless(monkeypatch):
    # Cartesia IS in the committed credited set (union, 2026-11-06), and
    # the committed default still lists ink-2 (primary) + ink-whisper
    # (wide-language fallback) after the credited two — but the served
    # catalog omits them while the key is missing (founder ruling
    # 2026-11-05), so nothing inactive is offered. The key, not the
    # credited list, is Cartesia's gate.
    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    vc.clear_cache()
    assert "cartesia" in vc.CONFIG.voice_credited_providers
    assert vc.CONFIG.voice_cascade_stt_models[-2:] == (
        "cartesia/ink-2", "cartesia/ink-whisper",
    )
    cat = vc.catalog()
    stt = {s["id"]: s for s in cat["stt"]}
    assert stt["deepgram/nova-3"]["available"] is True
    assert stt["assemblyai/universal-streaming"]["available"] is True
    assert "cartesia/ink-2" not in stt
    assert "cartesia/ink-whisper" not in stt


def test_fallback_hides_cartesia_while_disabled(monkeypatch):
    # Founder ruling 2026-11-05: while Cartesia is inactive (no
    # CARTESIA_API_KEY wired) it must not appear in ANY served selection
    # list — not shown-disabled, absent. The credited providers stay offered.
    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    vc.clear_cache()
    cat = vc.catalog()
    assert cat["source"] == "fallback"
    served = (
        [s["id"] for s in cat["stt"]]
        + [t["id"] for t in cat["tts"]]
        + [m["id"] for m in cat["realtime_models"]]
        + [b["id"] for b in cat["brains"]]
    )
    assert not [i for i in served if "cartesia" in i]
    assert not vc.is_valid_stt("cartesia/ink-2")
    assert not vc.is_valid_tts("cartesia/sonic-3")
    stt = {s["id"]: s for s in cat["stt"]}
    assert stt["deepgram/nova-3"]["available"] is True
    assert stt["assemblyai/universal-streaming"]["available"] is True
    tts = {t["id"]: t for t in cat["tts"]}
    assert tts["inworld/inworld-tts-1"]["available"] is True


def test_fallback_hides_cartesia_when_credited_but_keyless(monkeypatch):
    # The staging state: the deploy credits the provider (so a future key
    # lights it up with no other change) but the grant key is not wired yet —
    # the key is the enablement signal, so Cartesia stays hidden.
    import dataclasses

    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    monkeypatch.setattr(vc, "_fetch_livekit_models", lambda: None)
    monkeypatch.setattr(vc, "CONFIG", dataclasses.replace(
        vc.CONFIG, voice_credited_providers=(
            *vc.CONFIG.voice_credited_providers, "cartesia",
        ),
    ))
    vc.clear_cache()
    cat = vc.catalog()
    served = [s["id"] for s in cat["stt"]] + [t["id"] for t in cat["tts"]]
    assert not [i for i in served if "cartesia" in i]


def test_live_catalog_hides_cartesia_realtime_while_disabled(monkeypatch):
    # The gate covers the live path too: a cartesia realtime model LiveKit
    # returns is withheld while the key is missing.
    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    monkeypatch.setattr(
        vc, "_fetch_livekit_models", lambda: [
            {"id": "deepgram/nova-3", "type": "STT"},
            {"id": "cartesia/sonic-realtime", "type": "realtime"},
        ]
    )
    vc.clear_cache()
    cat = vc.catalog()
    assert cat["source"] == "livekit"
    assert [m["id"] for m in cat["realtime_models"]] == ["gemini-live"]


def test_live_catalog_marks_everything_available(monkeypatch):
    # When the live catalog IS populated, it lists exactly what credits enable,
    # so a non-"credited-list" provider from it is still available. (The live
    # cartesia entry appears only with its key wired — enabled here.)
    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
    monkeypatch.setattr(
        vc, "_fetch_livekit_models", lambda: [
            {"id": "cartesia/sonic-3", "type": "TTS"},
            {"id": "fishaudio/s2.1-pro", "type": "TTS"},
        ]
    )
    vc.clear_cache()
    cat = vc.catalog()
    assert cat["source"] == "livekit"
    assert "cartesia/sonic-3" in [t["id"] for t in cat["tts"]]
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


# --- safe_tts_voice: never hand the gateway a cross-provider voice id --------
def test_safe_tts_voice_drops_cross_provider_id():
    # The configured Fish Audio default voice on an Inworld TTS → vendor default.
    fish_hannah = "9a9cf47702da476aa4629e2506d4a857"
    assert vc.safe_tts_voice("inworld/inworld-tts-1", fish_hannah) == ""


def test_safe_tts_voice_keeps_valid_id():
    fish_hannah = "9a9cf47702da476aa4629e2506d4a857"
    assert vc.safe_tts_voice("fishaudio/s2.1-pro", fish_hannah) == fish_hannah
    assert vc.safe_tts_voice("inworld/inworld-tts-1", "Ashley") == "Ashley"


def test_safe_tts_voice_empty_stays_vendor_default():
    assert vc.safe_tts_voice("inworld/inworld-tts-1", "") == ""
    assert vc.safe_tts_voice("inworld/inworld-tts-1", None) == ""
    assert vc.safe_tts_voice("inworld/inworld-tts-1", "  ") == ""


def test_safe_tts_voice_cartesia_uuids():
    skylar = "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4"
    fish_hannah = "9a9cf47702da476aa4629e2506d4a857"
    assert vc.safe_tts_voice("cartesia/sonic-3", skylar) == skylar
    assert vc.safe_tts_voice("cartesia/sonic-3", fish_hannah) == ""
    assert vc.safe_tts_voice("fishaudio/s2.1-pro", skylar) == ""
