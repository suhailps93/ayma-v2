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


def test_insider_extensionless_image_kept():
    # NOTE 258: i.insider.com serves a real JPEG on an extensionless slug URL;
    # the over-aggressive extension heuristic was dropping it. It must be kept,
    # both via the explicit allowlist host and the image-subdomain rule.
    for u in [
        "https://i.insider.com/632abc1def2345678",
        "https://i.insider.com/5f0a?width=1000&format=jpeg&auto=webp",
    ]:
        assert wpf.is_renderable_image_url(u) is True, u


def test_extensionless_image_subdomains_kept():
    # Generalized: a leading image-host subdomain fronts extensionless images.
    for u in [
        "https://media.nngroup.com/media/editor/2023/x",
        "https://img.example.com/a/b/c",
        "https://images.example.org/xyz?sig=1",
        "https://cdn.example.net/transform/abc",
    ]:
        assert wpf.is_renderable_image_url(u) is True, u


def test_insider_www_article_page_dropped():
    # The article host (www.insider.com) is NOT an image host — adding
    # i.insider.com must not accidentally keep its extensionless pages.
    for u in [
        "https://www.insider.com/some-article-2024-1",
        "https://www.businessinsider.com/profile/jane-doe",
    ]:
        assert wpf.is_renderable_image_url(u) is False, u


def test_garbage_and_non_http_rejected():
    for u in ["", "   ", "ftp://host/x.jpg", "data:image/png;base64,AAAA", "not a url"]:
        assert wpf.is_renderable_image_url(u) is False, u
