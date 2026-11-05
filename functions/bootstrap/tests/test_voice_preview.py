"""Voice-preset preview: cached TTS samples for the settings picker.

Synthesis is DISABLED (founder rule 2026-11-04 — the direct-Google TTS model
is gone): ``preview_url`` serves already-cached clips and fails honestly for
an uncached preset.
"""

import asyncio
import uuid

import pytest

import llm_routing
import main
import voice_preview
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer [REDACTED]"}


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
    """Patch out Storage. Returns the store dict."""
    store: dict = {}
    monkeypatch.setattr(voice_preview, "_bucket", lambda: _FakeBucket(store))
    return store


# --------------------------------------------------------------------------- #
# voice_preview.preview_url
# --------------------------------------------------------------------------- #
def test_uncached_voice_fails_honestly_without_synthesis(monkeypatch):
    store = _install_fakes(monkeypatch)

    with pytest.raises(llm_routing.DirectGoogleDisabledError):
        asyncio.run(voice_preview.preview_url("Charon"))

    assert store == {}  # nothing generated, nothing uploaded


def test_cached_clip_is_served_without_synthesis(monkeypatch):
    store = _install_fakes(monkeypatch)
    store["voice_previews/Aoede.wav"] = {
        "data": b"RIFF....fake-wav",
        "content_type": "audio/wav",
        "metadata": {"firebaseStorageDownloadTokens": str(uuid.uuid4())},
    }

    first = asyncio.run(voice_preview.preview_url("Aoede"))
    second = asyncio.run(voice_preview.preview_url("Aoede"))

    assert first == second
    assert first.startswith("https://firebasestorage.googleapis.com/v0/b/")
    assert "voice_previews%2FAoede.wav" in first
    assert "token=" in first


def test_unknown_voice_is_rejected_before_any_storage_read(monkeypatch):
    store = _install_fakes(monkeypatch)

    with pytest.raises(ValueError):
        asyncio.run(voice_preview.preview_url("Nonsense"))
    assert store == {}


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
        raise llm_routing.DirectGoogleDisabledError("tts disabled")

    monkeypatch.setattr(voice_preview, "preview_url", _boom)
    resp = client.get("/voice/preview/Aoede", headers=_auth(monkeypatch))
    assert resp.status_code == 502


def test_endpoint_requires_auth():
    assert client.get("/voice/preview/Aoede").status_code in (401, 403)
