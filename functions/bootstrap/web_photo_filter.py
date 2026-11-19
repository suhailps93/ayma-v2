"""Renderability filter for web-research photo candidates (Leg 33).

The deep-dive web search and reverse-image search stage *photo candidates* that
end up rendered as image tiles in the "Web research" report (``report_adapters.
deep_dive_blocks`` → the Node-Visualiser photo carousel). Some captured
candidates are not renderable images at all — a scholarly API/entity URL
(``openalex.org/W…``) or a plain web *page* (``www.cockcroft.ac.uk/people/…``,
``www.tuwien.at/…``, ``www.maxiv.lu.se/…``) that a client's ``Image.network``
can only fail on, showing a broken-image tile.

:func:`is_renderable_image_url` is the cheap, pure gate that keeps those obvious
*page* URLs out of the photo set, while letting real image URLs through — a
path ending in a known image extension, a known image-CDN/transform host, or an
*image-host subdomain* (``i.insider.com``, ``media.nngroup.com``) that serves
extensionless image URLs. It errs toward KEEPING: it deliberately does **not**
try to catch a host that *is* a real image but blocks hotlinking (``cdn.sanity.
io`` / ``framerusercontent.com`` / ``media.nngroup.com`` serve a valid image to
the collector yet 403 a client), nor a URL that is image-shaped but returns an
HTTP error on download (NOTE 258: ``spenet`` 402 / ``brightervision`` 404) —
those can only be known at render/fetch time and are handled downstream (the
collector's :func:`deep_dive_images._fetch_image` drops HTTP errors; the
client's clean error fallback covers a hotlink block). Dropping only the
unmistakable non-image page URLs keeps every legitimate photo rendering —
including a valid JPEG on an extensionless slug URL (NOTE 258: ``i.insider.com``
was wrongly dropped by a missing-extension-alone heuristic).
"""

from __future__ import annotations

import urllib.parse

# A URL path whose last segment ends in one of these is a real raster/vector
# image and renders.
_IMAGE_EXTS = {
    ".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", ".bmp", ".svg",
    ".heic", ".heif", ".jfif", ".tif", ".tiff", ".ico",
}
# A URL path whose last segment ends in one of these is a document/page, never
# a renderable image — reject outright.
_PAGE_EXTS = {
    ".html", ".htm", ".php", ".asp", ".aspx", ".jsp", ".cfm", ".pdf",
    ".xml", ".json", ".txt", ".rss", ".atom",
}
# Hosts that serve images through extensionless transform/CDN URLs. An
# extensionless path from one of these is still an image, so it's kept.
_IMAGE_HOSTS = (
    "googleusercontent.com", "gstatic.com", "ggpht.com", "fbcdn.net",
    "cdninstagram.com", "licdn.com", "twimg.com", "pinimg.com", "imgur.com",
    "cloudinary.com", "imgix.net", "staticflickr.com", "cloudfront.net",
    "akamaized.net", "sanity.io", "framerusercontent.com", "substackcdn.com",
    "ytimg.com", "wp.com", "unsplash.com", "pexels.com",
    # Business Insider / Insider serve real JPEGs on this extensionless image
    # host (``i.insider.com/<slug>?width=…&format=jpeg``). Named explicitly so
    # it is never confused with the ``www.insider.com`` article pages.
    "i.insider.com",
)
# Host *subdomains* that conventionally front an image/CDN origin and serve
# extensionless image URLs (``i.insider.com``, ``media.nngroup.com``,
# ``img.example.com``). When the first host label is one of these, an
# extensionless URL is kept — it is almost always a transformed image, and the
# client's error fallback covers the rare miss. Page URLs that must stay
# dropped (``openalex.org``, ``www.cockcroft.ac.uk``, ``www.tuwien.at``,
# ``www.maxiv.lu.se``) are apex/``www`` hosts and never match here.
_IMAGE_SUBDOMAINS = {
    "i", "img", "imgs", "image", "images", "pic", "pics", "photo", "photos",
    "media", "cdn", "static", "assets", "thumb", "thumbs",
}


def is_renderable_image_url(url: str) -> bool:
    """True when ``url`` is plausibly a renderable image, False for an obvious
    non-image *page* URL (so it's never staged as a photo candidate).

    Conservative on purpose — a URL is dropped only when it is clearly a page
    (a page extension, or an extensionless path on a host that isn't a known
    image CDN). A real image that happens to be hotlink-blocked still passes
    here (the client's error fallback is what guarantees no broken tile shows)."""
    url = (url or "").strip()
    if not url.lower().startswith(("http://", "https://")):
        return False
    try:
        parsed = urllib.parse.urlparse(url)
    except ValueError:
        return False
    host = (parsed.netloc or "").lower().split("@")[-1].split(":")[0]
    if not host:
        return False
    last = (parsed.path or "").rsplit("/", 1)[-1]
    dot = last.rfind(".")
    ext = last[dot:].lower() if dot >= 0 else ""
    if ext in _PAGE_EXTS:
        return False
    if ext in _IMAGE_EXTS:
        return True
    # No image extension: keep it when the host is a known image CDN, when its
    # leading label is an image-host subdomain (``i.insider.com`` →  ``i``), or
    # when the query carries an explicit image hint. Everything else
    # (openalex.org/W…, www.cockcroft.ac.uk/people/…, www.tuwien.at/…) is a
    # ``www``/apex page URL and is dropped.
    if any(host == h or host.endswith("." + h) for h in _IMAGE_HOSTS):
        return True
    if host.split(".", 1)[0] in _IMAGE_SUBDOMAINS:
        return True
    query = (parsed.query or "").lower()
    if "format=image" in query or "imgurl=" in query:
        return True
    for e in _IMAGE_EXTS:
        if e in query:
            return True
    return False
