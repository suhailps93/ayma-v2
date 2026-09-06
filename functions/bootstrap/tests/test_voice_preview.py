"""Voice-preset preview: cached Gemini TTS samples for the settings picker."""

import asyncio

import gemini
import main
import voice_preview
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


# --------------------------------------------------------------------------- #
# fakes
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
    """Patch out Storage + the Gemini TTS call. Returns
    ``(store, tts_calls)``."""
    store: dict = {}
    tts_calls: list = []
    monkeypatch.setattr(voice_preview, "_bucket", lambda: _FakeBucket(store))
    monkeypatch.setattr(gemini, "_client", lambda: object())

    async def _fake_generate(_client, **kwargs):
        tts_calls.append(kwargs)

        class _Inline:
            data = b"\x01\x02\x03\x04" * 600  # stand-in PCM
            mime_type = "audio/L16;codec=pcm;rate=24000"

        class _Part:
            inline_data = _Inline()

        class _Content:
            parts = [_Part()]

        class _Cand:
            content = _Content()

        class _Resp:
            candidates = [_Cand()]

        return _Resp()

    monkeypatch.setattr(gemini, "_generate", _fake_generate)
    return store, tts_calls


# --------------------------------------------------------------------------- #
# voice_preview.preview_url
# --------------------------------------------------------------------------- #
def test_known_voice_generates_uploads_and_returns_a_url(monkeypatch):
    store, tts_calls = _install_fakes(monkeypatch)

    url = asyncio.run(voice_preview.preview_url("Charon"))

    assert len(tts_calls) == 1
    cfg = tts_calls[0]["config"]
    assert cfg.response_modalities == ["AUDIO"]
    assert (
        cfg.speech_config.voice_config.prebuilt_voice_config.voice_name
        == "Charon"
    )
    assert tts_calls[0]["model"] == main.CONFIG.gemini_tts_model
    # uploaded once, as a WAV
    assert "voice_previews/Charon.wav" in store
    blob = store["voice_previews/Charon.wav"]
    assert blob["content_type"] == "audio/wav"
    assert blob["data"].startswith(b"RIFF")  # WAV header wrapped around the PCM
    # a token-based Firebase download URL
    assert url.startswith("https://firebasestorage.googleapis.com/v0/b/")
    assert "voice_previews%2FCharon.wav" in url
    assert "token=" in url


def test_second_call_is_served_from_cache_without_a_second_tts_call(monkeypatch):
    store, tts_calls = _install_fakes(monkeypatch)

    first = asyncio.run(voice_preview.preview_url("Aoede"))
    second = asyncio.run(voice_preview.preview_url("Aoede"))

    assert len(tts_calls) == 1  # no regeneration
    assert first == second


def test_unknown_voice_is_rejected_before_any_tts_call(monkeypatch):
    _store, tts_calls = _install_fakes(monkeypatch)

    try:
        asyncio.run(voice_preview.preview_url("Nonsense"))
    except ValueError:
        pass
    else:  # pragma: no cover
        raise AssertionError("expected ValueError for an unknown preset")
    assert tts_calls == []


# --------------------------------------------------------------------------- #
# GET /voice/preview/{voice_name}
# --------------------------------------------------------------------------- #
def test_endpoint_happy_path(monkeypatch):
    async def _fake_url(name):
        return f"https://example.test/{name}.wav"

    monkeypatch.setattr(voice_preview, "preview_url", _fake_url)
    resp = client.get("/voice/preview/Aoede", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json() == {"url": "https://example.test/Aoede.wav"}


def test_endpoint_unknown_voice_is_404(monkeypatch):
    resp = client.get("/voice/preview/Bogus", headers=_auth(monkeypatch))
    assert resp.status_code == 404


def test_endpoint_generation_failure_is_502(monkeypatch):
    async def _boom(_name):
        raise RuntimeError("tts upstream down")

    monkeypatch.setattr(voice_preview, "preview_url", _boom)
    resp = client.get("/voice/preview/Aoede", headers=_auth(monkeypatch))
    assert resp.status_code == 502


def test_endpoint_requires_auth():
    assert client.get("/voice/preview/Aoede").status_code in (401, 403)
