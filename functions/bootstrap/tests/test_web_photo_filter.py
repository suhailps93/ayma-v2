"""web_photo_filter.is_renderable_image_url — the gate that keeps obvious
non-image page URLs out of the web-research photo set (Leg 33). Pins the exact
host classes Scout saw render as broken tiles: a real image extension passes, a
scholarly entity / plain page URL is dropped, and a hotlink-blocked but real
image CDN URL is *kept* (the client's error fallback covers that class)."""

import web_photo_filter as wpf


def test_real_image_extensions_pass():
    for u in [
        "https://cdn.sanity.io/images/ab/cd/photo-1200x800.png",
        "https://framerusercontent.com/images/abc.png",
        "https://media.nngroup.com/media/editor/2023/x.png",
        "https://example.com/pic.JPG",
        "https://example.com/a/b/c.webp?w=400",
    ]:
        assert wpf.is_renderable_image_url(u) is True, u


def test_non_image_page_urls_dropped():
    # The exact classes that rendered as broken tiles: a scholarly entity URL
    # and plain institution/people pages (no image extension, not an image CDN).
    for u in [
        "https://openalex.org/W2741809807",
        "https://www.cockcroft.ac.uk/people/jane-doe",
        "https://www.tuwien.at/en/research/some-group",
        "https://www.maxiv.lu.se/beamlines/balder",
        "https://example.com/about.html",
        "https://example.com/profile",
        "https://example.com/works/",
    ]:
        assert wpf.is_renderable_image_url(u) is False, u


def test_extensionless_known_image_cdn_kept():
    # Transform/CDN URLs that serve images without a file extension.
    for u in [
        "https://lh3.googleusercontent.com/a-/AOh14abc123=s400",
        "https://pbs.twimg.com/profile_images/123/abc",
    ]:
        assert wpf.is_renderable_image_url(u) is True, u


def test_garbage_and_non_http_rejected():
    for u in ["", "   ", "ftp://host/x.jpg", "data:image/png;base64,AAAA", "not a url"]:
        assert wpf.is_renderable_image_url(u) is False, u
