import asyncio
import types

import deep_dive_images
import face_match


def _run(coro):
    return asyncio.run(coro)


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
        self.exists = bool(media)

    def to_dict(self):
        return {}

    def get(self):
        return self

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


def _patch_common(monkeypatch, *, verdicts=None):
    """`verdicts` maps candidate index -> check_same_person result dict.
    Default: first candidate matches ('self'), second does not ('not_self')."""
    if verdicts is None:
        verdicts = [
            {"verdict": "self", "confidence": "high", "face_visible": True, "reason": "match"},
            {"verdict": "not_self", "confidence": "high", "face_visible": True, "reason": "different"},
        ]
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

    async def _check(ref, cand, uid=None, feature=None):
        calls["n"] += 1
        idx = min(calls["n"] - 1, len(verdicts) - 1)
        return verdicts[idx]

    monkeypatch.setattr(face_match, "check_same_person", _check)


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
    out = _run(deep_dive_images.find_web_images(_Db([]), "u1", "Dana Reyes"))
    assert out == []
    assert warned  # logged, didn't raise


def test_keeps_only_face_verified_matches(monkeypatch):
    _patch_common(monkeypatch)
    db = _Db([{"storage_path": "users/u1/media/1.jpg"}])

    out = _run(deep_dive_images.find_web_images(db, "u1", "Dana Reyes"))
    assert len(out) == 1
    assert out[0]["url"] == "https://a.example/1.jpg"
    assert out[0]["verified"] is True


def test_runs_for_another_target_using_their_embeddings(monkeypatch):
    _patch_common(monkeypatch)
    db = _Db([{"storage_path": "users/other/media/1.jpg"}])

    out = _run(deep_dive_images.find_web_images(db, "other", "Sam Vale"))
    assert [im["url"] for im in out] == ["https://a.example/1.jpg"]
    assert out[0]["verified"] is True


def test_no_reference_embedding_marks_candidates_unverified(monkeypatch):
    _patch_common(monkeypatch)
    db = _Db([])  # target has no user_media / photos

    out = _run(deep_dive_images.find_web_images(db, "u1", "Dana Reyes"))
    assert out and all(im["verified"] is False for im in out)


# --- face-detection gate ---------------------------------------------------
# Regression coverage for the "GitHub identicon passed as a face match" bug:
# a candidate must show a visible face (face_visible=True) to be marked verified.


def test_faceless_high_similarity_candidate_is_not_verified(monkeypatch):
    """A candidate where face_visible is False must still be excluded."""
    _patch_common(
        monkeypatch,
        verdicts=[
            {"verdict": "self", "confidence": "high", "face_visible": False, "reason": "no face"},
            {"verdict": "not_self", "confidence": "high", "face_visible": True, "reason": "different"},
        ],
    )
    db = _Db([{"storage_path": "users/u1/media/1.jpg"}])

    out = _run(deep_dive_images.find_web_images(db, "u1", "Dana Reyes"))
    assert out == []  # face_visible is False -> vetoed


def test_real_face_candidate_still_verifies_as_before(monkeypatch):
    """A genuine face-bearing match clears the check and verifies."""
    _patch_common(
        monkeypatch,
        verdicts=[
            {"verdict": "self", "confidence": "high", "face_visible": True, "reason": "match"},
            {"verdict": "not_self", "confidence": "high", "face_visible": True, "reason": "different"},
        ],
    )
    db = _Db([{"storage_path": "users/u1/media/1.jpg"}])

    out = _run(deep_dive_images.find_web_images(db, "u1", "Dana Reyes"))
    assert len(out) == 1
    assert out[0]["url"] == "https://a.example/1.jpg"
    assert out[0]["verified"] is True


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
    _run(deep_dive_images.find_web_images(db, "u1", "Jane Doe", extra_terms="Denver"))
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
    async def _check(ref, cand, uid=None, feature=None):
        return {"verdict": "self", "confidence": "high", "face_visible": True, "reason": "match"}
    monkeypatch.setattr(face_match, "check_same_person", _check)

    db = _Db([{"storage_path": "users/u1/media/1.jpg"}])
    links = [{"url": "https://site.example/jane", "is_them": "likely"}]

    out = _run(deep_dive_images.find_web_images(db, "u1", "Jane Doe", links=links))
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
    async def _check(ref, cand, uid=None, feature=None):
        return {"verdict": "not_self", "confidence": "high", "face_visible": True, "reason": "different"}
    monkeypatch.setattr(face_match, "check_same_person", _check)

    db = _Db([{"storage_path": "users/u1/media/1.jpg"}])
    links = [{"url": "https://site.example/jane", "is_them": "likely"}]

    out = _run(deep_dive_images.find_web_images(db, "u1", "Jane Doe", links=links))
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
    db = _Db([])  # no user_media -> no reference photos
    links = [{"url": "https://site.example/jane", "is_them": "likely"}]

    out = _run(deep_dive_images.find_web_images(db, "u1", "Jane Doe", links=links))
    assert len(out) == 1
    assert out[0]["verified"] is False


def test_a_link_that_will_not_fetch_is_skipped_and_the_dive_survives(monkeypatch):
    _no_cse(monkeypatch)

    def _boom(url):
        raise RuntimeError("timeout")

    monkeypatch.setattr(deep_dive_images, "_page_meta", _boom)
    db = _Db([{"storage_path": "users/u1/media/1.jpg"}])
    links = [{"url": "https://site.example/jane", "is_them": "likely"}]

    out = _run(deep_dive_images.find_web_images(db, "u1", "Jane Doe", links=links))
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
    _run(deep_dive_images.find_web_images(db, "u1", "Jane", links=links))
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
