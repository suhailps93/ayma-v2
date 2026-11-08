"""Voice-preview LIBRARY + per-model voice resolution (founder 2026-11-07).

Two guarantees pinned here:

* Every catalog voice can be previewed: ``voice_preview`` serves a recorded
  clip for any named voice in the voice catalog (not just the Gemini
  presets), answers an honest "not recorded" for a catalog voice without a
  clip, and still rejects names that are not voices at all.
* The picker shows only what the selected model supports:
  ``voice_catalog.voices_for_stack`` is the exact per-model list, and
  ``GET /voice/engines`` resolves a saved voice the active model does not
  support to a supported one — and SAYS so (``voice_fell_back`` /
  ``saved_voice_id``), never a silent wrong voice.
"""

import asyncio
import uuid

import pytest

import main
import schema
import voice_catalog
import voice_preview
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)

FISH_HANNAH = "9a9cf47702da476aa4629e2506d4a857"
FISH_SARAH = "933563129e564b19a115bedd57b7406a"
GRADIUM_HARPER = "4SZHfMpw-p46Ywgs"


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer [REDACTED]"}


@pytest.fixture(autouse=True)
def _offline_catalog(monkeypatch):
    """Deterministic config-fallback catalog (no LiveKit fetch in tests)."""
    voice_catalog.clear_cache()
    yield
    voice_catalog.clear_cache()


# --------------------------------------------------------------------------- #
# storage fakes (same shape as tests/test_voice_preview.py)
# --------------------------------------------------------------------------- #
class _FakeBlob:
    def __init__(self, store, name):
        self._store = store
        self.name = name
        self.metadata = None

        class _B:
            name = "ayma-test.firebasestorage.app"

        self.bucket = _B()

    def exists(self):
        return self.name in self._store

    def reload(self):
        rec = self._store.get(self.name)
        self.metadata = dict(rec["metadata"]) if rec else None

    def patch(self):
        self._store[self.name]["metadata"] = dict(self.metadata or {})

    def upload_from_string(self, data, content_type=None):
        self._store[self.name] = {
            "data": data,
            "content_type": content_type,
            "metadata": dict(self.metadata or {}),
        }


class _FakeBucket:
    def __init__(self, store):
        self._store = store

    def blob(self, name):
        return _FakeBlob(self._store, name)


def _install_fakes(monkeypatch):
    store: dict = {}
    monkeypatch.setattr(voice_preview, "_bucket", lambda: _FakeBucket(store))
    return store


def _seed_clip(store, voice_id):
    store[f"voice_previews/{voice_id}.wav"] = {
        "data": b"RIFF....fake-wav",
        "content_type": "audio/wav",
        "metadata": {"firebaseStorageDownloadTokens": str(uuid.uuid4())},
    }


# --------------------------------------------------------------------------- #
# voices_for_stack: the exact per-model list
# --------------------------------------------------------------------------- #
def test_voices_for_stack_cascade_tts_models():
    inworld = voice_catalog.voices_for_stack(
        mode="cascade", tts_id="inworld/inworld-tts-1"
    )
    assert [v.id for v in inworld] == [
        "",
        "Ashley",
        "Olivia",
        "Elizabeth",
        "Sarah",
        "Alex",
        "Mark",
        "Hades",
        "Edward",
    ]
    fish = voice_catalog.voices_for_stack(mode="cascade", tts_id="fishaudio/s2.1-pro")
    assert [v.id for v in fish] == [
        "",
        "bf322df2096a46f18c579d0baa36f41d",
        "536d3a5e000945adb7038665781a4aca",
        FISH_HANNAH,
        "79d0bd3e4e5444b18f7b6d89b5927bf1",
        "e3cd384158934cc9a01029cd7d278634",
        FISH_SARAH,
        "b347db033a6549378b48d00acb0d06cd",
    ]
    rime = voice_catalog.voices_for_stack(mode="cascade", tts_id="rime/coda")
    assert [v.id for v in rime] == ["", "astra", "celeste", "luna"]
    gradium = voice_catalog.voices_for_stack(mode="cascade", tts_id="gradium/default")
    assert [v.id for v in gradium] == ["", GRADIUM_HARPER, "6MFfc37kq0sBjBjy"]


def test_voices_for_stack_realtime_gemini():
    voices = voice_catalog.voices_for_stack(
        mode="realtime", realtime_model_id="gemini-live"
    )
    assert [v.id for v in voices] == [
        "Aoede",
        "Kore",
        "Leda",
        "Zephyr",
        "Puck",
        "Charon",
        "Fenrir",
        "Orus",
    ]
    # An empty realtime id means Gemini Live.
    default = voice_catalog.voices_for_stack(mode="realtime")
    assert [v.id for v in default] == [v.id for v in voices]


# --------------------------------------------------------------------------- #
# resolve_stack_voice: supported stays; unsupported falls back, flagged
# --------------------------------------------------------------------------- #
def test_resolve_supported_voice_stays():
    assert voice_catalog.resolve_stack_voice(
        mode="cascade", tts_id="inworld/inworld-tts-1", voice_id="Ashley"
    ) == ("Ashley", False)
    assert voice_catalog.resolve_stack_voice(
        mode="realtime", realtime_model_id="gemini-live", voice_id="Aoede"
    ) == ("Aoede", False)


def test_resolve_unsupported_voice_falls_back_to_stack_default():
    # A Fish Audio voice saved against the Inworld TTS: not supported there.
    resolved, fell_back = voice_catalog.resolve_stack_voice(
        mode="cascade", tts_id="inworld/inworld-tts-1", voice_id=FISH_HANNAH
    )
    assert fell_back is True
    assert resolved == ""  # inworld's first entry is the vendor default
    # A cascade voice saved against Gemini Live realtime.
    resolved, fell_back = voice_catalog.resolve_stack_voice(
        mode="realtime", realtime_model_id="gemini-live", voice_id="Hades"
    )
    assert (resolved, fell_back) == ("Aoede", True)


def test_resolve_empty_voice_is_not_a_fallback():
    assert voice_catalog.resolve_stack_voice(
        mode="cascade", tts_id="inworld/inworld-tts-1", voice_id=""
    ) == ("", False)


# --------------------------------------------------------------------------- #
# catalog index: preview keys are unambiguous
# --------------------------------------------------------------------------- #
def test_catalog_voice_ids_are_unique_across_stacks():
    index = voice_catalog.catalog_voice_index()
    collisions = {vid: owners for vid, owners in index.items() if len(owners) != 1}
    assert collisions == {}


def test_find_catalog_voice():
    owner, voice = voice_catalog.find_catalog_voice("Ashley")
    assert owner == "inworld/inworld-tts-1"
    assert voice.label == "Ashley"
    owner, _ = voice_catalog.find_catalog_voice(FISH_HANNAH)
    assert owner == "fishaudio/s2.1-pro"
    owner, _ = voice_catalog.find_catalog_voice("astra")
    assert owner == "rime/coda"
    owner, _ = voice_catalog.find_catalog_voice(GRADIUM_HARPER)
    assert owner == "gradium/default"
    owner, _ = voice_catalog.find_catalog_voice("Aoede")
    assert owner == "gemini-live"
    assert voice_catalog.find_catalog_voice("Nonsense") is None
    assert voice_catalog.find_catalog_voice("") is None


# --------------------------------------------------------------------------- #
# preview serving for catalog voices
# --------------------------------------------------------------------------- #
def test_catalog_voice_with_recorded_clip_is_served(monkeypatch):
    store = _install_fakes(monkeypatch)
    _seed_clip(store, "Ashley")

    url = asyncio.run(voice_preview.preview_url("Ashley"))

    assert "voice_previews%2FAshley.wav" in url
    assert "token=" in url


def test_catalog_voice_without_clip_is_honest_not_recorded(monkeypatch):
    _install_fakes(monkeypatch)

    with pytest.raises(voice_preview.PreviewNotRecordedError):
        asyncio.run(voice_preview.preview_url("Ashley"))


def test_fish_voice_with_recorded_clip_is_served(monkeypatch):
    store = _install_fakes(monkeypatch)
    _seed_clip(store, FISH_HANNAH)

    url = asyncio.run(voice_preview.preview_url(FISH_HANNAH))

    assert f"voice_previews%2F{FISH_HANNAH}.wav" in url


def test_is_previewable_voice():
    assert voice_preview.is_previewable_voice("Aoede") is True
    assert voice_preview.is_previewable_voice("Ashley") is True
    assert voice_preview.is_previewable_voice(FISH_HANNAH) is True
    assert voice_preview.is_previewable_voice("Nonsense") is False
    assert voice_preview.is_previewable_voice("") is False


def test_endpoint_serves_recorded_catalog_clip(monkeypatch):
    store = _install_fakes(monkeypatch)
    _seed_clip(store, "Ashley")

    resp = client.get("/voice/preview/Ashley", headers=_auth(monkeypatch))

    assert resp.status_code == 200
    assert "voice_previews%2FAshley.wav" in resp.json()["url"]


def test_endpoint_catalog_voice_without_clip_is_404(monkeypatch):
    _install_fakes(monkeypatch)

    resp = client.get("/voice/preview/Ashley", headers=_auth(monkeypatch))

    assert resp.status_code == 404
    assert resp.json()["detail"] == "No preview recorded for this voice yet."


# --------------------------------------------------------------------------- #
# GET /voice/engines: the reported current voice is always supported
# --------------------------------------------------------------------------- #
class _ProfileDoc:
    def __init__(self, stored=None):
        self.stored = dict(stored or {})

    def get(self):
        doc = self

        class _S:
            exists = True

            def to_dict(self_):
                return dict(doc.stored)

        return _S()

    def set(self, payload, merge=False):
        self.stored.update(payload)


def _patch_db(monkeypatch, doc):
    monkeypatch.setattr(main.schema, "profile_doc", lambda _db, _uid: doc)
    monkeypatch.setattr(main, "get_db", lambda: object())


def test_engines_falls_back_when_saved_voice_not_supported(monkeypatch):
    doc = _ProfileDoc(
        {
            schema.PF_AYMA_VOICE_MODE: "cascade",
            schema.PF_AYMA_CASCADE_TTS: "inworld/inworld-tts-1",
            schema.PF_AYMA_TTS_VOICE: FISH_HANNAH,  # a Fish Audio voice
        }
    )
    _patch_db(monkeypatch, doc)

    body = client.get("/voice/engines", headers=_auth(monkeypatch)).json()
    cur = body["current"]

    assert cur["voice_id"] == ""  # inworld's supported default
    assert cur["voice_fell_back"] is True
    assert cur["saved_voice_id"] == FISH_HANNAH


def test_engines_keeps_supported_saved_voice(monkeypatch):
    doc = _ProfileDoc(
        {
            schema.PF_AYMA_VOICE_MODE: "cascade",
            schema.PF_AYMA_CASCADE_TTS: "inworld/inworld-tts-1",
            schema.PF_AYMA_TTS_VOICE: "Hades",
        }
    )
    _patch_db(monkeypatch, doc)

    body = client.get("/voice/engines", headers=_auth(monkeypatch)).json()
    cur = body["current"]

    assert cur["voice_id"] == "Hades"
    assert cur["voice_fell_back"] is False
    assert cur["saved_voice_id"] == ""


def test_engines_realtime_foreign_voice_falls_back(monkeypatch):
    doc = _ProfileDoc(
        {
            schema.PF_AYMA_VOICE_MODE: "realtime",
            schema.PF_AYMA_REALTIME_MODEL: "gemini-live",
            schema.PF_AYMA_VOICE: "Hades",  # an Inworld voice, not a preset
        }
    )
    _patch_db(monkeypatch, doc)

    body = client.get("/voice/engines", headers=_auth(monkeypatch)).json()
    cur = body["current"]

    assert cur["voice_id"] == "Aoede"
    assert cur["voice_fell_back"] is True
    assert cur["saved_voice_id"] == "Hades"
