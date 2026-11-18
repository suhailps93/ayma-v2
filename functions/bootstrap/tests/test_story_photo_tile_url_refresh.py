"""NOTE 252 (Chunk 2) — Your Story photo tiles + header showed the broken-image
glyph because the image-node URL is frozen in the node's ``answer`` at ingest
and was served verbatim: a rotated Firebase download token (object re-upload /
demo ``--reset`` / prod↔staging copy) makes every frozen URL 403.

These pin the fix: image-node URLs are re-minted from their object path against
the bucket the backend serves, at serve time — on the ``/story/photos`` tile
path and in the person-graph tree payload NodeImage renders from.

Fails before the fix (the frozen stale URL is emitted unchanged); passes after
(the re-minted URL is emitted)."""

import public_profile
from routes import profile as profile_routes

_BUCKET = "ayma-ai.firebasestorage.app"
# A Story photo tile's stored URL, minted at ingest with a token that has since
# rotated — the exact thing that turns the tile into a broken-image glyph.
_STALE = (
    f"https://firebasestorage.googleapis.com/v0/b/{_BUCKET}"
    "/o/uploads%2Fu1%2Fseed_face.png?alt=media&token=STALE-OLD"
)
_FRESH = (
    f"https://firebasestorage.googleapis.com/v0/b/{_BUCKET}"
    "/o/uploads%2Fu1%2Fseed_face.png?alt=media&token=FRESH-NEW"
)


def _remint_by_path(monkeypatch):
    """Stand in for the Storage round-trip: the current object at ``path`` mints
    a URL carrying its CURRENT (fresh) token."""
    def fake(path: str):
        assert path == "uploads/u1/seed_face.png"  # decoded, bucket-agnostic
        return _FRESH
    monkeypatch.setattr(public_profile, "_photo_url", fake)


def test_refresh_remints_a_stale_token_url(monkeypatch):
    _remint_by_path(monkeypatch)
    assert public_profile.refresh_storage_url(_STALE) == _FRESH


def test_refresh_passes_through_an_external_web_photo(monkeypatch):
    # A web-search photo is some other site entirely — never re-minted.
    monkeypatch.setattr(public_profile, "_photo_url", lambda p: _FRESH)
    web = "https://example.com/some/photo.jpg"
    assert public_profile.refresh_storage_url(web) == web


def test_refresh_passes_through_empty(monkeypatch):
    monkeypatch.setattr(public_profile, "_photo_url", lambda p: _FRESH)
    assert public_profile.refresh_storage_url("") == ""
    assert public_profile.refresh_storage_url(None) == ""


def test_refresh_falls_back_to_original_when_unresolvable(monkeypatch):
    # The object genuinely can't be resolved (gone / not in this bucket): keep
    # the original URL — honest, never a fabricated placeholder, never worse
    # than the frozen URL.
    monkeypatch.setattr(public_profile, "_photo_url", lambda p: None)
    assert public_profile.refresh_storage_url(_STALE) == _STALE


def test_refresh_remints_a_cross_bucket_url(monkeypatch):
    # A URL minted in another environment's bucket (prod↔staging copy): the path
    # is still recovered and re-minted against the bucket we serve.
    _remint_by_path(monkeypatch)
    other = (
        "https://firebasestorage.googleapis.com/v0/b/ayma-staging.firebasestorage.app"
        "/o/uploads%2Fu1%2Fseed_face.png?alt=media&token=STAGING"
    )
    assert public_profile.refresh_storage_url(other) == _FRESH


def test_tree_payload_refreshes_image_urls_including_nested(monkeypatch):
    _remint_by_path(monkeypatch)
    # The person-graph tree NodeImage renders from: an image node with the stale
    # URL, and a nested image child — both must be re-minted; text nodes and
    # web photos are untouched.
    web = "https://example.com/web.jpg"
    tree = {
        "surface": "story",
        "sections": [
            {
                "page_type": "story",
                "nodes": [
                    {"id": "t1", "text": "a text node", "children": []},
                    {
                        "id": "img1",
                        "answer_type": "image",
                        "image_url": _STALE,
                        "children": [
                            {
                                "id": "img2",
                                "answer_type": "image",
                                "image_url": _STALE,
                                "children": [],
                            }
                        ],
                    },
                    {"id": "img3", "answer_type": "image", "image_url": web, "children": []},
                ],
            }
        ],
    }
    profile_routes._refresh_tree_image_urls(tree)
    nodes = tree["sections"][0]["nodes"]
    assert nodes[1]["image_url"] == _FRESH
    assert nodes[1]["children"][0]["image_url"] == _FRESH
    assert nodes[2]["image_url"] == web  # external photo untouched
    assert "image_url" not in nodes[0]  # text node untouched
