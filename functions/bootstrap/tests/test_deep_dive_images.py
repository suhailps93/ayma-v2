import types

import deep_dive_images
import media_embed


class _Snap:
    def __init__(self, data):
        self._d = data

    def to_dict(self):
        return dict(self._d)


class _Col:
    def __init__(self, docs):
        self._docs = docs

    def stream(self):
        return [_Snap(d) for d in self._docs]


class _Doc:
    def __init__(self, media):
        self._media = media

    def collection(self, name):
        assert name == "user_media"
        return _Col(self._media)


class _Db:
    def __init__(self, media):
        self._media = media

    def collection(self, name):
        assert name == "users"
        return self

    def document(self, _uid):
        return _Doc(self._media)


def _patch_common(monkeypatch, *, embeds):
    """`embeds` maps candidate url -> the embedding vector to return."""
    monkeypatch.setattr(
        deep_dive_images, "_search_image_urls",
        lambda q, n: [
            {"url": "https://a.example/1.jpg", "source_page": "https://a.example"},
            {"url": "https://b.example/2.jpg", "source_page": "https://b.example"},
        ],
    )
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda url: (b"jpegbytes", "image/jpeg")
    )
    calls = {"n": 0}

    def _embed(_img, _mime="image/jpeg"):
        calls["n"] += 1
        # first candidate matches, second doesn't
        return embeds[calls["n"] - 1]
    monkeypatch.setattr(media_embed, "embed_image_bytes", _embed)


def test_no_key_is_a_noop(monkeypatch):
    monkeypatch.setattr(
        deep_dive_images, "CONFIG",
        types.SimpleNamespace(image_search_api_key="", image_search_cse_id=""),
    )
    warned = []
    monkeypatch.setattr(
        deep_dive_images.logger, "warning",
        lambda msg, *a, **k: warned.append(msg),
    )
    # No key -> _search_image_urls returns [] with a warning -> no images.
    out = deep_dive_images.find_web_images(_Db([]), "u1", "Dana Reyes")
    assert out == []
    assert warned  # logged, didn't raise


def test_keeps_only_face_verified_matches(monkeypatch):
    ref = [1.0, 0.0, 0.0]
    _patch_common(monkeypatch, embeds=[[0.99, 0.01, 0.0], [0.0, 1.0, 0.0]])
    db = _Db([{"embedding": ref}])

    out = deep_dive_images.find_web_images(db, "u1", "Dana Reyes")
    assert len(out) == 1
    assert out[0]["url"] == "https://a.example/1.jpg"
    assert out[0]["verified"] is True
    assert out[0]["similarity"] > 0.9


def test_runs_for_another_target_using_their_embeddings(monkeypatch):
    # target 'other' has a reference embedding; caller is 'me'.
    ref = [0.0, 1.0, 0.0]
    _patch_common(monkeypatch, embeds=[[0.0, 0.98, 0.02], [1.0, 0.0, 0.0]])
    db = _Db([{"embedding": ref}])

    out = deep_dive_images.find_web_images(db, "other", "Sam Vale")
    assert [im["url"] for im in out] == ["https://a.example/1.jpg"]
    assert out[0]["verified"] is True


def test_no_reference_embedding_marks_candidates_unverified(monkeypatch):
    _patch_common(monkeypatch, embeds=[[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]])
    db = _Db([])  # target has no user_media / embeddings

    out = deep_dive_images.find_web_images(db, "u1", "Dana Reyes")
    assert out and all(im["verified"] is False for im in out)
    assert all(im["similarity"] is None for im in out)
