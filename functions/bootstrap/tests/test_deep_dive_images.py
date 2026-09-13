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


# --- broader recall: paging + the always-also-bare-name query -------------


def test_search_image_urls_pages_until_a_short_page(monkeypatch):
    """A common name shouldn't be starved to Google's first 10 results —
    _search_image_urls pages (start=1,11,21) until it has enough or a page
    comes back short."""
    pages = {1: [{"url": f"https://x/{i}.jpg", "source_page": ""} for i in range(10)],
             11: [{"url": f"https://x/{i}.jpg", "source_page": ""} for i in range(10, 20)],
             21: [{"url": "https://x/20.jpg", "source_page": ""}]}  # short page -> stop
    seen_starts = []

    def _page(q, start, num):
        seen_starts.append(start)
        return pages.get(start, [])

    monkeypatch.setattr(deep_dive_images, "_search_image_urls_page", _page)
    out = deep_dive_images._search_image_urls("Common Name", 30)
    assert seen_starts == [1, 11, 21]
    assert len(out) == 21


def test_find_web_images_also_tries_the_bare_name_when_located(monkeypatch):
    """A located query ("name city") is narrow — the bare name must always
    also be searched so a match isn't missed just because it wasn't
    captioned with a location."""
    queries_seen = []

    def _search(q, n):
        queries_seen.append(q)
        return []

    monkeypatch.setattr(deep_dive_images, "_search_image_urls", _search)
    monkeypatch.setattr(deep_dive_images, "_fetch_image",
                         lambda url: (b"jpegbytes", "image/jpeg"))
    db = _Db([])
    deep_dive_images.find_web_images(db, "u1", "Jane Doe", extra_terms="Denver")
    assert queries_seen == ["Jane Doe Denver", "Jane Doe"]


# --- the no-CSE og:image fallback (link-derived images) -------------------


def _no_cse(monkeypatch):
    """CSE off — every candidate must come from the link fallback."""
    monkeypatch.setattr(deep_dive_images, "_search_image_urls", lambda q, n: [])


def test_link_ogimage_face_verified_becomes_a_web_image(monkeypatch):
    _no_cse(monkeypatch)
    monkeypatch.setattr(
        deep_dive_images, "_page_meta",
        lambda url: {"image": "https://pics.example/og.jpg", "title": "Jane"},
    )
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda url: (b"img", "image/jpeg")
    )
    monkeypatch.setattr(
        media_embed, "embed_image_bytes", lambda *a, **k: [1.0, 0.0, 0.0]
    )
    db = _Db([{"embedding": [1.0, 0.0, 0.0]}])
    links = [{"url": "https://site.example/jane", "is_them": "likely"}]

    out = deep_dive_images.find_web_images(db, "u1", "Jane Doe", links=links)
    assert len(out) == 1
    assert out[0]["url"] == "https://pics.example/og.jpg"
    assert out[0]["source_page"] == "https://site.example/jane"
    assert out[0]["verified"] is True


def test_link_ogimage_that_does_not_match_the_face_is_dropped(monkeypatch):
    _no_cse(monkeypatch)
    monkeypatch.setattr(
        deep_dive_images, "_page_meta",
        lambda url: {"image": "https://pics.example/og.jpg", "title": ""},
    )
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda url: (b"img", "image/jpeg")
    )
    monkeypatch.setattr(
        media_embed, "embed_image_bytes", lambda *a, **k: [0.0, 1.0, 0.0]
    )
    db = _Db([{"embedding": [1.0, 0.0, 0.0]}])
    links = [{"url": "https://site.example/jane", "is_them": "likely"}]

    out = deep_dive_images.find_web_images(db, "u1", "Jane Doe", links=links)
    assert out == []


def test_link_ogimage_returned_unverified_when_no_reference_embedding(monkeypatch):
    _no_cse(monkeypatch)
    monkeypatch.setattr(
        deep_dive_images, "_page_meta",
        lambda url: {"image": "https://pics.example/og.jpg", "title": ""},
    )
    monkeypatch.setattr(
        deep_dive_images, "_fetch_image", lambda url: (b"img", "image/jpeg")
    )
    monkeypatch.setattr(
        media_embed, "embed_image_bytes", lambda *a, **k: [0.2, 0.1, 0.0]
    )
    db = _Db([])  # no user_media -> no reference embedding
    links = [{"url": "https://site.example/jane", "is_them": "likely"}]

    out = deep_dive_images.find_web_images(db, "u1", "Jane Doe", links=links)
    assert len(out) == 1
    assert out[0]["verified"] is False
    assert out[0]["similarity"] is None


def test_a_link_that_will_not_fetch_is_skipped_and_the_dive_survives(monkeypatch):
    _no_cse(monkeypatch)

    def _boom(url):
        raise RuntimeError("timeout")

    monkeypatch.setattr(deep_dive_images, "_page_meta", _boom)
    db = _Db([{"embedding": [1.0, 0.0, 0.0]}])
    links = [{"url": "https://site.example/jane", "is_them": "likely"}]

    out = deep_dive_images.find_web_images(db, "u1", "Jane Doe", links=links)
    assert out == []  # no crash


def test_only_likely_links_feed_the_fallback(monkeypatch):
    _no_cse(monkeypatch)
    seen = []
    monkeypatch.setattr(
        deep_dive_images, "_page_meta",
        lambda url: (seen.append(url), {"image": "", "title": ""})[1],
    )
    db = _Db([])
    links = [
        {"url": "https://a.example", "is_them": "maybe"},
        {"url": "https://b.example", "is_them": "unclear"},
        {"url": "https://c.example", "is_them": "likely"},
    ]
    deep_dive_images.find_web_images(db, "u1", "Jane", links=links)
    assert seen == ["https://c.example"]


def test_page_meta_pulls_ogimage_and_title(monkeypatch):
    html = (
        '<html><head><title>Home</title>'
        '<meta property="og:title" content="Jane Doe — Photographer">'
        '<meta property="og:image" content="/media/hero.jpg">'
        '</head><body><img src="data:image/gif;base64,AAAA">'
        '<img src="/other.jpg"></body></html>'
    )
    monkeypatch.setattr(deep_dive_images, "_fetch_page_html", lambda url: html)
    got = deep_dive_images._page_meta("https://ex.example/p")
    assert got["image"] == "https://ex.example/media/hero.jpg"
    assert got["title"] == "Jane Doe — Photographer"


def test_page_meta_falls_back_to_first_real_img(monkeypatch):
    html = (
        '<html><body><img src="data:image/gif;base64,AAAA">'
        '<img src="https://cdn.example/pic.jpg"></body></html>'
    )
    monkeypatch.setattr(deep_dive_images, "_fetch_page_html", lambda url: html)
    got = deep_dive_images._page_meta("https://ex.example/p")
    assert got["image"] == "https://cdn.example/pic.jpg"


# --- classify_face_match / reference_embeddings_for ------------------------


def test_classify_face_match_self_when_close():
    ref = [1.0, 0.0]
    assert deep_dive_images.classify_face_match([0.99, 0.01], [ref]) == "self"


def test_classify_face_match_not_self_when_far():
    ref = [1.0, 0.0]
    assert deep_dive_images.classify_face_match([0.0, 1.0], [ref]) == "not_self"


def test_classify_face_match_unknown_in_the_borderline_band():
    ref = [1.0, 0.0]
    # cosine == 0.5 — under threshold (0.55) but inside the not_self margin.
    assert (
        deep_dive_images.classify_face_match([0.5, 0.8660254], [ref])
        == "unknown"
    )


def test_classify_face_match_unknown_with_no_refs_or_no_embedding():
    assert deep_dive_images.classify_face_match([1.0, 0.0], []) == "unknown"
    assert deep_dive_images.classify_face_match([], [[1.0, 0.0]]) == "unknown"


class _VerifiedUserDoc:
    """A `users/{uid}` doc carrying a `face_verification.embedding`."""

    def __init__(self, embedding):
        self._embedding = embedding

    @property
    def exists(self):
        return True

    def to_dict(self):
        return {"face_verification": {"embedding": self._embedding}}


class _VerifiedDb:
    """Minimal db: `users/{uid}.get()` returns a verified doc; the
    `_reference_embeddings` fallback path (`.collection("user_media")`) is
    intentionally unsupported, so a test only reaches it if the fast path
    fails to short-circuit."""

    def __init__(self, embedding):
        self._embedding = embedding

    def collection(self, name):
        assert name == "users"
        return self

    def document(self, _uid):
        return self

    def get(self):
        return _VerifiedUserDoc(self._embedding)


def test_reference_embeddings_for_prefers_the_verified_selfie():
    db = _VerifiedDb([0.6, 0.8])
    refs = deep_dive_images.reference_embeddings_for(db, "u1")
    assert refs == [[0.6, 0.8]]


def test_reference_embeddings_for_falls_back_without_verification(monkeypatch):
    monkeypatch.setattr(
        deep_dive_images, "_reference_embeddings",
        lambda _db, _uid: [[1.0, 0.0]],
    )
    db = _Db([])  # no face_verification support, no user_media either
    refs = deep_dive_images.reference_embeddings_for(db, "u1")
    assert refs == [[1.0, 0.0]]
