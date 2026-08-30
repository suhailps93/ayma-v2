import media_embed
from google.cloud.firestore_v1.vector import Vector


class _Doc:
    def __init__(self):
        self.written = None

    def set(self, payload):
        self.written = payload


class _Db:
    def __init__(self):
        self.doc = _Doc()
        self.path = []

    def collection(self, name):
        self.path.append(name)
        return self

    def document(self, name=None):
        self.path.append(name or "<auto>")
        return self

    @property
    def id(self):
        return "media-123"

    def set(self, payload):
        return self.doc.set(payload)


def test_process_media_writes_a_user_media_doc_with_a_vector(monkeypatch):
    monkeypatch.setattr(media_embed, "_download", lambda _p: b"\x89PNG-bytes")
    monkeypatch.setattr(
        media_embed, "embed_image_bytes", lambda _b: [0.1, 0.2, 0.3]
    )
    db = _Db()
    media_id = media_embed.process_media(
        db, "u1", "uploads/u1/profile_1.jpg", "profile"
    )

    assert media_id == "media-123"
    assert db.path == ["users", "u1", "user_media", "<auto>"]
    w = db.doc.written
    assert w["storage_path"] == "uploads/u1/profile_1.jpg"
    assert w["context"] == "profile"
    assert isinstance(w["embedding"], Vector)
    assert list(w["embedding"]) == [0.1, 0.2, 0.3]
    assert w["dim"] == 3


def test_embed_image_bytes_calls_embed_content_on_the_global_endpoint(
    monkeypatch,
):
    import io
    import json

    class _Creds:
        token = "tok"

        def refresh(self, _req):
            pass

    monkeypatch.setattr(
        media_embed.google.auth, "default", lambda scopes=None: (_Creds(), "p")
    )
    captured = {}

    def _fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        captured["body"] = json.loads(req.data)
        captured["auth"] = req.headers["Authorization"]
        return io.BytesIO(
            json.dumps({"embedding": {"values": [1.0, 2.0, 3.0]}}).encode()
        )

    monkeypatch.setattr(media_embed.urllib.request, "urlopen", _fake_urlopen)

    out = media_embed.embed_image_bytes(b"imgbytes", "image/png")
    assert out == [1.0, 2.0, 3.0]
    assert ":embedContent" in captured["url"]
    # global endpoint has no region prefix
    assert "//aiplatform.googleapis.com/" in captured["url"]
    assert media_embed.CONFIG.image_embedding_model in captured["url"]
    assert captured["auth"] == "Bearer tok"
    part = captured["body"]["content"]["parts"][0]["inlineData"]
    assert part["mimeType"] == "image/png"


def test_find_similar_media_uses_cosine_find_nearest():
    seen = {}

    class _Snap:
        def __init__(self, i):
            self.id = i

    class _Chain:
        def collection(self, _name):
            return self

        def document(self, _name):
            return self

        def find_nearest(self, *, vector_field, query_vector, distance_measure,
                         limit):
            seen.update(
                field=vector_field, dm=str(distance_measure), limit=limit
            )
            return self

        def stream(self):
            return iter([_Snap("m2"), _Snap("m5")])

    out = media_embed.find_similar_media(_Chain(), "u1", [0.1, 0.2], limit=3)
    assert out == ["m2", "m5"]
    assert seen["field"] == "embedding"
    assert "COSINE" in seen["dm"]
    assert seen["limit"] == 3
