"""`/voice/engines` + `/voice/preference` (§13.9): the voice-stack catalog and
the per-user preference the agent reads at the next call."""

import config
import main
import schema
import voice_catalog
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


class _ProfileDoc:
    """A stand-in ``profile/main`` doc: returns ``stored`` on get, captures set."""

    def __init__(self, stored=None):
        self.stored = dict(stored or {})
        self.written = {}

    def get(self):
        doc = self

        class _S:
            exists = True

            def to_dict(self_):
                return dict(doc.stored)

        return _S()

    def set(self, payload, merge=False):
        self.written.update(payload)
        self.stored.update(payload)


def _patch_db(monkeypatch, doc):
    monkeypatch.setattr(main.schema, "profile_doc", lambda _db, _uid: doc)
    monkeypatch.setattr(main, "get_db", lambda: object())


def setup_function(_):
    voice_catalog.clear_cache()


import pytest


@pytest.fixture(autouse=True)
def _offline_catalog(monkeypatch):
    """The catalog is the config fallback (the gateway /v1/models route is
    a stub — there is no live fetch), so tests are deterministic and
    network-free; just clear the catalog cache around each test."""
    voice_catalog.clear_cache()
    yield
    voice_catalog.clear_cache()


# --- GET /voice/engines -----------------------------------------------------
def test_engines_lists_modes_realtime_cascade_components(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    resp = client.get("/voice/engines", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    body = resp.json()
    assert body["modes"] == ["realtime", "cascade"]
    # Realtime models carry their own voices + languages.
    rt_ids = [m["id"] for m in body["realtime_models"]]
    assert "gemini-live" in rt_ids
    gemini = next(m for m in body["realtime_models"] if m["id"] == "gemini-live")
    assert any(v["id"] == "Aoede" for v in gemini["voices"])
    assert any(l["code"] == "" for l in gemini["languages"])
    # Cascade: brains, STT, and TTS (TTS carries its voices).
    assert any(b["id"] == "meta-muse-spark" for b in body["brains"])
    assert any(b["id"] == "google/gemini-3.7-flash" for b in body["brains"])
    assert any(s["id"] == "deepgram/nova-3" for s in body["stt"])
    tts = next(t for t in body["tts"] if t["id"] == "inworld/inworld-tts-1")
    assert any(v["id"] == "Ashley" for v in tts["voices"])
    # The default selection comes through.
    assert body["default"]["mode"] in ("realtime", "cascade")
    assert "current" in body


def test_engines_openai_realtime_hidden_until_flag(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    resp = client.get("/voice/engines", headers=_auth(monkeypatch))
    rt_ids = [m["id"] for m in resp.json()["realtime_models"]]
    assert "openai-realtime" not in rt_ids  # flag off by default

    monkeypatch.setenv("VOICE_OPENAI_REALTIME", "true")
    monkeypatch.setattr(main, "CONFIG", config._load())
    monkeypatch.setattr(voice_catalog, "CONFIG", config._load())
    voice_catalog.clear_cache()
    resp2 = client.get("/voice/engines", headers=_auth(monkeypatch))
    models = {m["id"]: m for m in resp2.json()["realtime_models"]}
    assert "openai-realtime" in models
    assert models["openai-realtime"]["requires_secret"] == "OPENAI_API_KEY"


def test_engines_hides_cartesia_while_disabled(monkeypatch):
    # Founder ruling 2026-11-05: the served catalog (what the models page
    # renders) contains no cartesia entry while the key is missing — even
    # when the deploy credits the provider (the staging state).
    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    monkeypatch.setenv(
        "VOICE_CREDITED_PROVIDERS",
        "inworld,deepgram,fishaudio,assemblyai,rime,gradium,google,cartesia",
    )
    monkeypatch.setattr(main, "CONFIG", config._load())
    monkeypatch.setattr(voice_catalog, "CONFIG", config._load())
    voice_catalog.clear_cache()
    _patch_db(monkeypatch, _ProfileDoc())
    body = client.get("/voice/engines", headers=_auth(monkeypatch)).json()
    served = (
        [s["id"] for s in body["stt"]]
        + [t["id"] for t in body["tts"]]
        + [m["id"] for m in body["realtime_models"]]
        + [b["id"] for b in body["brains"]]
    )
    assert not [i for i in served if "cartesia" in i]


def test_engines_lists_cartesia_when_enabled(monkeypatch):
    # Genuinely enabled (credited + key wired): the Sonic TTS + both Ink STT
    # ids are served, available.
    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia-key")
    monkeypatch.setenv(
        "VOICE_CREDITED_PROVIDERS",
        "inworld,deepgram,fishaudio,assemblyai,rime,gradium,google,cartesia",
    )
    monkeypatch.setattr(main, "CONFIG", config._load())
    monkeypatch.setattr(voice_catalog, "CONFIG", config._load())
    voice_catalog.clear_cache()
    _patch_db(monkeypatch, _ProfileDoc())
    body = client.get("/voice/engines", headers=_auth(monkeypatch)).json()
    tts = {t["id"]: t for t in body["tts"]}
    assert tts["cartesia/sonic-3"]["available"] is True
    stt = {s["id"]: s for s in body["stt"]}
    assert stt["cartesia/ink-2"]["available"] is True
    assert stt["cartesia/ink-whisper"]["available"] is True


def test_engines_reflects_saved_cascade_selection(monkeypatch):
    doc = _ProfileDoc(
        {
            schema.PF_AYMA_VOICE_MODE: "cascade",
            schema.PF_AYMA_CASCADE_BRAIN: "meta-muse-spark",
            schema.PF_AYMA_CASCADE_STT: "assemblyai/universal-streaming",
            schema.PF_AYMA_CASCADE_TTS: "inworld/inworld-tts-1",
            schema.PF_AYMA_TTS_VOICE: "Hades",
            "ayma_voice_language": "Malayalam",
        }
    )
    _patch_db(monkeypatch, doc)
    body = client.get("/voice/engines", headers=_auth(monkeypatch)).json()
    cur = body["current"]
    assert cur["mode"] == "cascade"
    assert cur["brain_id"] == "meta-muse-spark"
    assert cur["stt_id"] == "assemblyai/universal-streaming"
    assert cur["voice_id"] == "Hades"
    assert cur["language_code"] == "ml-IN"


def test_engines_requires_auth():
    assert client.get("/voice/engines").status_code in (401, 403)


# --- POST /voice/preference -------------------------------------------------
def test_preference_saves_cascade_stack(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/voice/preference",
        headers=_auth(monkeypatch),
        json={
            "mode": "cascade",
            "brain_id": "google/gemini-3.7-flash",
            "stt_id": "deepgram/nova-3",
            "tts_id": "inworld/inworld-tts-1",
            "voice_id": "Ashley",
            "language_code": "ml-IN",
        },
    )
    assert resp.status_code == 200
    assert doc.written[schema.PF_AYMA_VOICE_MODE] == "cascade"
    assert doc.written[schema.PF_AYMA_CASCADE_BRAIN] == "google/gemini-3.7-flash"
    assert doc.written[schema.PF_AYMA_CASCADE_TTS] == "inworld/inworld-tts-1"
    assert doc.written[schema.PF_AYMA_TTS_VOICE] == "Ashley"
    # The language label (not the code) is stored so the prompt reads naturally.
    assert doc.written["ayma_voice_language"] == "Malayalam"


def test_preference_realtime_gemini_voice_goes_to_voice_name(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/voice/preference",
        headers=_auth(monkeypatch),
        json={
            "mode": "realtime",
            "realtime_model_id": "gemini-live",
            "voice_id": "Charon",
            "language_code": "",
        },
    )
    assert resp.status_code == 200
    assert doc.written[schema.PF_AYMA_VOICE_MODE] == "realtime"
    assert doc.written[schema.PF_AYMA_REALTIME_MODEL] == "gemini-live"
    # A Gemini preset is the hot-swappable ayma_voice_name, not ayma_tts_voice.
    assert doc.written[schema.PF_AYMA_VOICE] == "Charon"


def test_preference_rejects_unknown_mode(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    resp = client.post(
        "/voice/preference",
        headers=_auth(monkeypatch),
        json={"mode": "telepathy"},
    )
    assert resp.status_code == 422


def test_preference_rejects_voice_not_in_tts(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    resp = client.post(
        "/voice/preference",
        headers=_auth(monkeypatch),
        json={
            "mode": "cascade",
            "brain_id": "meta-muse-spark",
            "stt_id": "deepgram/nova-3",
            "tts_id": "inworld/inworld-tts-1",
            "voice_id": "NotARealVoice",
        },
    )
    assert resp.status_code == 422


def test_preference_rejects_meta_as_realtime(monkeypatch):
    """Meta is a cascade brain only — it is never a valid realtime model."""
    _patch_db(monkeypatch, _ProfileDoc())
    resp = client.post(
        "/voice/preference",
        headers=_auth(monkeypatch),
        json={"mode": "realtime", "realtime_model_id": "meta-muse-spark"},
    )
    assert resp.status_code == 422


# --- main._voice_engine_seed (what the agent receives) ----------------------
def test_voice_engine_seed_empty_when_unset(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    seed = main._voice_engine_seed("me")
    assert seed["voice_mode"] == ""  # agent keeps the deploy default


def test_voice_engine_seed_carries_cascade_ids(monkeypatch):
    doc = _ProfileDoc(
        {
            schema.PF_AYMA_VOICE_MODE: "cascade",
            schema.PF_AYMA_CASCADE_BRAIN: "google/gemini-3.7-flash",
            schema.PF_AYMA_CASCADE_STT: "deepgram/nova-3",
            schema.PF_AYMA_CASCADE_TTS: "cartesia/sonic-3",
            schema.PF_AYMA_TTS_VOICE: "Olivia",
        }
    )
    _patch_db(monkeypatch, doc)
    seed = main._voice_engine_seed("me")
    assert seed["voice_mode"] == "cascade"
    assert seed["brain_id"] == "google/gemini-3.7-flash"
    assert seed["tts_id"] == "cartesia/sonic-3"
    assert seed["tts_voice"] == "Olivia"
