"""Deep-dive web image search + face verification.

For a deep dive on a person (self *or* an Explore user), search the open web for
photos of that person and keep only the ones whose face matches that person's
own profile photos. Returns ``[{url, source_page, similarity, verified}]``.

No-op — returns ``[]`` and logs one warning — when the Programmable Search key
(``IMAGE_SEARCH_API_KEY`` / ``IMAGE_SEARCH_CSE_ID``) isn't configured; the flagged public-profile source
(``DEEPDIVE_PUBLIC_PROFILES``) is its working replacement. The deep
dive still runs; it just carries no web images.

A candidate's multimodal embedding is compared against the person's reference
embedding(s) purely by cosine similarity — that embedding model happily
returns *some* vector for any image, faces or not, so a flat-color avatar
(e.g. a GitHub default identicon) can coincidentally land above the
similarity threshold. :func:`_has_detectable_face` is the gate that catches
that: a candidate is never marked ``verified`` unless a real photographed
face is actually visible in it, no matter how high its similarity score.
"""

from __future__ import annotations

import json
import logging
import re
import urllib.error
import urllib.parse
import urllib.request

import biometric_consent
import deep_dive_public_profiles
import face_match
import public_url
import schema
from config import CONFIG
from token_ledger import FEATURE_DEEPDIVE

logger = logging.getLogger("ayma.deepdive.images")

# Google's JSON API caps a single request at 10 results (`num`) but allows
# paging further back via `start` (1, 11, 21, …) — pull up to 3 pages so a
# common name isn't starved down to whatever fits in the first 10.
_MAX_CANDIDATES = 30
_RESULTS_PER_PAGE = 10
_MAX_IMAGE_BYTES = 6 * 1024 * 1024
_KEEP_UNVERIFIED = 6
# The no-key fallback: the primary image of each link the dive already tied to
# this person. Bounded so a dive with many links doesn't fan out forever.
_MAX_LINK_IMAGES = 6
_MAX_PAGE_BYTES = 3 * 1024 * 1024
_VERIFY_THRESHOLD = 0.55

_META_IMG_RE = re.compile(
    r"<meta\b[^>]*?(?:property|name)\s*=\s*[\"']"
    r"(?:og:image(?::secure_url)?|twitter:image(?::src)?)[\"'][^>]*>",
    re.I | re.S,
)
_META_TITLE_RE = re.compile(
    r"<meta\b[^>]*?(?:property|name)\s*=\s*[\"']"
    r"(?:og:title|twitter:title)[\"'][^>]*>",
    re.I | re.S,
)
_CONTENT_RE = re.compile(r"content\s*=\s*[\"']([^\"']+)[\"']", re.I)
_IMG_TAG_RE = re.compile(r"<img\b[^>]*>", re.I)
_SRC_RE = re.compile(r"\bsrc\s*=\s*[\"']([^\"']+)[\"']", re.I)
_TITLE_TAG_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.I | re.S)


def _search_image_urls_page(query: str, start: int, num: int) -> list[dict]:
    """One page of the Google Custom Search JSON API, ``searchType=image``.
    Returns ``[{url, source_page}]``. Empty on any failure or missing
    config."""
    key, cx = CONFIG.image_search_api_key, CONFIG.image_search_cse_id
    if not key or not cx:
        logger.warning(
            "deep-dive image search skipped: IMAGE_SEARCH_API_KEY / "
            "IMAGE_SEARCH_CSE_ID not set"
        )
        return []
    params = urllib.parse.urlencode(
        {
            "key": key,
            "cx": cx,
            "q": query,
            "searchType": "image",
            "num": max(1, min(10, num)),
            "start": max(1, start),
            "safe": "active",
        }
    )
    url = f"https://www.googleapis.com/customsearch/v1?{params}"
    try:
        with urllib.request.urlopen(url, timeout=15) as resp:
            data = json.loads(resp.read())
    except (urllib.error.URLError, ValueError, TimeoutError) as exc:
        logger.warning("deep-dive image search failed: %s", exc)
        return []
    out: list[dict] = []
    for item in data.get("items", []) or []:
        link = str(item.get("link") or "").strip()
        if not link:
            continue
        ctx = item.get("image", {}) or {}
        out.append(
            {
                "url": link,
                "source_page": str(ctx.get("contextLink") or "").strip(),
            }
        )
    return out


def _search_image_urls(query: str, count: int) -> list[dict]:
    """Google Custom Search JSON API, ``searchType=image``, paged as needed to
    reach ``count`` results (10 per request, up to 3 pages) — a single page
    of 10 starves a common name down to whatever Google happened to rank
    first. Returns ``[{url, source_page}]``; empty on any failure or missing
    config. Stops early once a page comes back short (no more results)."""
    out: list[dict] = []
    start = 1
    while len(out) < count and start <= 21:
        page = _search_image_urls_page(
            query, start, min(_RESULTS_PER_PAGE, count - len(out))
        )
        if not page:
            break
        out.extend(page)
        if len(page) < _RESULTS_PER_PAGE:
            break
        start += _RESULTS_PER_PAGE
    return out[:count]


def _fetch_image(url: str) -> tuple[bytes, str]:
    """Download a web image. Raises on failure / non-image / oversize, and on
    a non-public address (:mod:`public_url`, SSRF guard)."""
    with public_url.open_public(
        url, headers={"User-Agent": "Mozilla/5.0 (AymaDeepDive)"}, timeout=15
    ) as resp:
        mime = (resp.headers.get("Content-Type") or "image/jpeg").split(";")[0]
        if not mime.startswith("image/"):
            raise ValueError(f"not an image: {mime}")
        data = resp.read(_MAX_IMAGE_BYTES + 1)
    if len(data) > _MAX_IMAGE_BYTES:
        raise ValueError("image too large")
    return data, mime


def _fetch_page_html(url: str) -> str:
    """Download an HTML page (UA + size cap). Raises on failure / non-HTML,
    and on a non-public address (:mod:`public_url`, SSRF guard)."""
    with public_url.open_public(
        url, headers={"User-Agent": "Mozilla/5.0 (AymaDeepDive)"}, timeout=15
    ) as resp:
        ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
        if ctype and not (
            ctype.startswith("text/html") or ctype.endswith("xml")
        ):
            raise ValueError(f"not html: {ctype}")
        raw = resp.read(_MAX_PAGE_BYTES + 1)[:_MAX_PAGE_BYTES]
    return raw.decode("utf-8", "replace")


def _first_content(pattern: re.Pattern, html: str) -> str:
    for m in pattern.finditer(html):
        cm = _CONTENT_RE.search(m.group(0))
        if cm and cm.group(1).strip():
            return cm.group(1).strip()
    return ""


def _page_meta(page_url: str) -> dict:
    """``{'image': <abs url or ''>, 'title': <str>}`` for a page — the
    ``og:image`` / ``twitter:image`` (else the first non-data ``<img>``) and
    the ``og:title`` / ``twitter:title`` / ``<title>``. Fetch errors raise;
    a page with nothing usable returns empty strings."""
    html = _fetch_page_html(page_url)

    img = _first_content(_META_IMG_RE, html)
    if not img:
        for m in _IMG_TAG_RE.finditer(html):
            sm = _SRC_RE.search(m.group(0))
            if not sm:
                continue
            src = sm.group(1).strip()
            if src and not src.startswith("data:"):
                img = src
                break
    if img:
        img = urllib.parse.urljoin(page_url, img)
        if not img.startswith(("http://", "https://")):
            img = ""

    title = _first_content(_META_TITLE_RE, html)
    if not title:
        tm = _TITLE_TAG_RE.search(html)
        if tm:
            title = re.sub(r"\s+", " ", tm.group(1)).strip()
    return {"image": img, "title": title}


def _link_derived_candidates(links: list[dict] | None) -> list[dict]:
    """``[{url, source_page}]`` — the primary image of every dive link tagged
    as (likely) this person. Best-effort; a link that won't fetch is skipped."""
    out: list[dict] = []
    seen_pages: set[str] = set()
    for ln in links or []:
        if not isinstance(ln, dict):
            continue
        if str(ln.get("is_them") or "").strip().lower() != "likely":
            continue
        page = str(ln.get("url") or "").strip()
        if not page.startswith(("http://", "https://")) or page in seen_pages:
            continue
        seen_pages.add(page)
        try:
            img = _page_meta(page).get("image") or ""
        except Exception:  # noqa: BLE001 - a bad link must never break a dive
            continue
        if img:
            out.append({"url": img, "source_page": page})
        if len(out) >= _MAX_LINK_IMAGES:
            break
    return out


async def find_web_images(
    db,
    target_uid: str,
    name: str,
    *,
    extra_terms: str = "",
    links: list[dict] | None = None,
    max_candidates: int = _MAX_CANDIDATES,
    threshold: float = _VERIFY_THRESHOLD,
    uid: str | None = None,
    location: str = "",
    stats: dict | None = None,
) -> list[dict]:
    """Find photos of the person on the open web, face-verified against their
    own profile photos. Three candidate sources, merged and deduped by URL:

    * public social-profile photos (:mod:`deep_dive_public_profiles`) — behind
      the ``DEEPDIVE_PUBLIC_PROFILES`` flag (default OFF) and skipped for
      ``location``s in ``DEEPDIVE_PUBLIC_PROFILES_BLOCKED_REGIONS``;

    * the Programmable Search image API — richer, but a no-op without
      ``IMAGE_SEARCH_API_KEY`` / ``IMAGE_SEARCH_CSE_ID``;
    * the primary image (``og:image`` / ``twitter:image``, else first
      ``<img>``) of each ``links`` entry the dive tagged ``is_them:"likely"``
      — always on, needs no key.

    Returns the verified matches, or — when the target has no usable reference
    embedding — a few candidates marked ``verified: False``. A candidate is
    only ever marked ``verified`` when it also clears the
    :func:`_has_detectable_face` gate — a high similarity score alone is never
    enough (a faceless image, e.g. a default-avatar identicon, can otherwise
    coincidentally land above the threshold).

    Runs only for a target Ayma account with a biometric consent
    (:mod:`biometric_consent`) — no target, or no consent, returns ``[]``
    before any web photo is fetched or embedded. Never raises."""
    stats = stats if stats is not None else {}
    name = (name or "").strip()
    if not name:
        return []
    if not (db and target_uid and biometric_consent.has_consent_fresh(db, target_uid)):
        stats["skipped"] = "no_target_or_consent"
        return []
    extra_terms = (extra_terms or "").strip()
    # A located query ("Jane Doe Denver") is precise but narrow — most photos
    # of someone online aren't captioned with their city. Always also search
    # the bare name so a real match isn't lost just because it's unlocated.
    queries = [name] if not extra_terms else [f"{name} {extra_terms}", name]
    candidates: list[dict] = []
    for query in queries:
        try:
            candidates.extend(_search_image_urls(query, max_candidates))
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive image search crashed for %r", query)
    if deep_dive_public_profiles.region_blocked(location):
        stats["public_profiles"] = "region_blocked"
    else:
        try:
            candidates.extend(
                await deep_dive_public_profiles.find_public_profile_images(
                    name, extra_terms=extra_terms, uid=uid, stats=stats
                )
            )
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive public-profile step crashed")
    try:
        candidates.extend(_link_derived_candidates(links))
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive link-image fallback crashed")

    # Dedupe by image URL, first occurrence wins (CSE before link-derived).
    seen: set[str] = set()
    deduped: list[dict] = []
    for c in candidates:
        u = str(c.get("url") or "").strip()
        if not u or u in seen:
            continue
        seen.add(u)
        deduped.append(c)
    stats["candidates"] = len(deduped)
    if not deduped:
        logger.info("deep-dive web images: no candidates stats=%s", stats)
        return []

    # Candidate gathering can take a while: re-check the consent right before
    # any web photo is matched, so a withdrawal stops it at once.
    if not biometric_consent.has_consent_fresh(db, target_uid):
        return []
    refs = face_match.get_reference_photos(db, target_uid) if (db and target_uid) else []

    scored: list[dict] = []
    for c in deduped:
        try:
            img, mime = _fetch_image(c["url"])
        except Exception:  # noqa: BLE001
            continue
        if not img:
            continue

        verified = False
        if refs:
            for r in refs:
                try:
                    res = await face_match.check_same_person(
                        r, (img, mime), uid=uid, feature=FEATURE_DEEPDIVE
                    )
                    if res.get("verdict") == "self" and res.get("face_visible", False):
                        verified = True
                        break
                except Exception:
                    logger.warning(
                        "deep_dive_images: face check failed for candidate",
                        exc_info=True,
                    )

        scored.append(
            {
                "url": c["url"],
                "source_page": c.get("source_page", ""),
                **({"platform": c["platform"]} if c.get("platform") else {}),
                "verified": verified,
            }
        )

    stats["scored"] = len(scored)
    stats["verified"] = sum(1 for s in scored if s["verified"])
    logger.info("deep-dive web images: stats=%s", stats)
    if refs:
        verified = [s for s in scored if s["verified"]]
        for s in verified:
            if s.get("platform"):
                logger.info(
                    "deep-dive verified image from platform=%s",
                    s["platform"],
                )
        return verified
    # No reference photos to check against — hand back a few, clearly
    # unverified, so the UI can label them.
    return scored[:_KEEP_UNVERIFIED]
