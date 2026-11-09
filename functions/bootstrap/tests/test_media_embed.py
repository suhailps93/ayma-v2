"""Tests for media_embed download helpers."""

import media_embed


class _FakeBlob:
    def __init__(self, data=b"fakebytes", content_type="image/png"):
        self.data = data
        self.content_type = content_type

    def reload(self):
        pass

    def download_as_bytes(self):
        return self.data


class _FakeBucket:
    def blob(self, path):
        return _FakeBlob()


def test_download_bytes(monkeypatch):
    from firebase_admin import storage

    monkeypatch.setattr(storage, "bucket", lambda _b: _FakeBucket())
    data, mime = media_embed.download_bytes("uploads/u1/photo.png")
    assert data == b"fakebytes"
    assert mime == "image/png"


def test_download_helper(monkeypatch):
    from firebase_admin import storage

    monkeypatch.setattr(storage, "bucket", lambda _b: _FakeBucket())
    assert media_embed._download("uploads/u1/photo.png") == b"fakebytes"
