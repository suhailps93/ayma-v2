"""Deep-dive discovery of a person's PUBLIC social-profile photos.

Replaces the closed Custom Search JSON API as a candidate source for
:mod:`deep_dive_images`. Two steps, both strictly public and unauthenticated:

1. **Discovery** — one Gemini call grounded with Google Search + URL context
   (:func:`gemini.research`) lists public profile pages on major platforms.
2. **Image extraction** — each listed page is fetched once with a plain,
   honest-User-Agent GET (robots.txt respected, no cookies, no login) and its
   ``og:image`` / ``twitter:image`` is the candidate image. Pages that answer
   with a login wall / auth redirect / 401 / 403 / 429 / 999 are skipped.

Candidates are *not* trusted: the caller still runs the face-verification gate
(cosine threshold + ``_has_detectable_face``) unchanged. Downloaded image bytes
are never stored by this module — it only returns image URLs.

Privacy: matching faces of people who have not consented is regulated
(Illinois BIPA, Texas CUBI, GDPR art. 9, ...). The feature is OFF unless
the ``deepdive_public_profiles`` flag is on, and is skipped for any region listed
in ``deepdive_blocked_regions`` (default ``illinois,texas,eu``). See
docs/DEEPDIVE_PUBLIC_PROFILES.md and docs/FEATURE_FLAGS.md. Both flags are read
at call time (:mod:`feature_flags`), so rollback is a flip with no deploy.

A second discovery source, Vertex AI Search over a public-website data store
(:mod:`vertex_search`, flag ``vertex_ai_search``), runs alongside the grounded
Gemini call; its results add platforms the model did not list and often carry
the already-indexed profile image, so no page fetch is needed for them.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
from functools import lru_cache
from pathlib import Path

import feature_flags
import gemini
import vertex_search
from token_ledger import FEATURE_DEEPDIVE

logger = logging.getLogger("ayma.deepdive.public_profiles")

USER_AGENT = "AymaDeepDive/1.0 (public-profile lookup; honors robots.txt)"
_PROMPT_PATH = Path(__file__).with_name("prompts") / "deep_dive_public_profiles.md"

MAX_PROFILES = 8
MAX_PAGE_BYTES = 1024 * 1024
CACHE_TTL_SECONDS = 24 * 3600
_CACHE_MAX_ENTRIES = 256

# platform key -> hostnames (exact or subdomain) accepted for that platform.
PLATFORM_HOSTS: dict[str, tuple[str, ...]] = {
    "instagram": ("instagram.com",),
    "facebook": ("facebook.com", "fb.com"),
    "linkedin": ("linkedin.com",),
    "x": ("x.com", "twitter.com"),
    "tiktok": ("tiktok.com",),
    "github": ("github.com",),
    "youtube": ("youtube.com",),
    "pinterest": ("pinterest.com",),
    "reddit": ("reddit.com",),
    "threads": ("threads.net", "threads.com"),
    "snapchat": ("snapchat.com",),
    "medium": ("medium.com",),
    "behance": ("behance.net",),
    "dribbble": ("dribbble.com",),
}
PERSONAL_SITE = "personal_site"
# Personal-site / portfolio hosts the Vertex AI Search data store covers; a
# result on one of these is accepted as a personal site.
PERSONAL_SITE_HOSTS: tuple[str, ...] = (
    "github.io", "linktr.ee", "about.me", "carrd.co", "notion.site",
    "wixsite.com", "vercel.app", "netlify.app", "wordpress.com",
    "blogspot.com", "substack.com", "tumblr.com", "dev.to", "hashnode.com",
    "gitlab.com", "stackoverflow.com", "twitch.tv", "vimeo.com",
    "soundcloud.com", "bandcamp.com", "deviantart.com", "artstation.com",
    "500px.com", "flickr.com", "unsplash.com", "wellfound.com",
    "crunchbase.com", "researchgate.net",
)
_LOGIN_PATH_RE = re.compile(
    r"/(login|log-in|signin|sign-in|signup|accounts/login|authwall|checkpoint|uas/login)\b",
    re.I,
)
_LOGIN_STATUS = {401, 403, 429, 999}

_META_IMG_RE = re.compile(
    r"<meta\b[^>]*?(?:property|name)\s*=\s*[\"']"
    r"(?:og:image(?::secure_url)?|twitter:image(?::src)?)[\"'][^>]*>",
    re.I | re.S,
)
_CONTENT_RE = re.compile(r"content\s*=\s*[\"']([^\"']+)[\"']", re.I)
_JSON_OBJ_RE = re.compile(r"\{.*\}", re.S)

_cache: dict[str, tuple[float, list[dict]]] = {}


def enabled() -> bool:
    """The ``deepdive_public_profiles`` flag."""
    return feature_flags.enabled("deepdive_public_profiles")


def region_blocked(location: str) -> bool:
    """Whether ``location`` (free text) matches a token in the
    ``deepdive_blocked_regions`` flag (e.g. ``illinois,texas,eu``),
    case-insensitive substring match."""
    tokens = feature_flags.get("deepdive_blocked_regions")
    loc = (location or "").lower()
    return any(t in loc for t in tokens)


@lru_cache(maxsize=1)
def _prompt() -> str:
    return _PROMPT_PATH.read_text(encoding="utf-8").strip()


def _host(url: str) -> str:
    try:
        return (urllib.parse.urlsplit(url).hostname or "").lower()
    except ValueError:
        return ""


def classify_platform(url: str, claimed: str = "") -> str:
    """The platform key for ``url``, ``personal_site`` for a non-listed host the
    model labelled a personal site, else ``""`` (reject)."""
    if not url.startswith(("http://", "https://")):
        return ""
    host = _host(url)
    if not host:
        return ""
    for key, hosts in PLATFORM_HOSTS.items():
        if any(host == h or host.endswith("." + h) for h in hosts):
            return key
    if (claimed or "").strip().lower().replace(" ", "_") == PERSONAL_SITE:
        return PERSONAL_SITE
    return ""


def parse_profiles(text: str) -> list[dict]:
    """``[{platform, url}]`` from the model's JSON reply — validated, deduped,
    one per platform, capped at :data:`MAX_PROFILES`. ``[]`` on garbage."""
    m = _JSON_OBJ_RE.search(text or "")
    if not m:
        return []
    try:
        data = json.loads(m.group(0))
    except ValueError:
        return []
    items = data.get("profiles") if isinstance(data, dict) else None
    out: list[dict] = []
    seen: set[str] = set()
    for it in items if isinstance(items, list) else []:
        if not isinstance(it, dict):
            continue
        url = str(it.get("url") or "").strip()
        platform = classify_platform(url, str(it.get("platform") or ""))
        if not platform or platform in seen:
            continue
        seen.add(platform)
        out.append({"platform": platform, "url": url})
        if len(out) >= MAX_PROFILES:
            break
    return out


class _NoRedirectToLogin(urllib.request.HTTPRedirectHandler):
    """Follows redirects but refuses to follow one into a login/auth URL."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if _LOGIN_PATH_RE.search(urllib.parse.urlsplit(newurl).path or ""):
            raise urllib.error.HTTPError(newurl, 401, "login wall", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _robots_allows(url: str) -> bool:
    """robots.txt check with our honest UA. A 404 means no restrictions; any
    other failure to read robots.txt fails closed."""
    parts = urllib.parse.urlsplit(url)
    robots_url = f"{parts.scheme}://{parts.netloc}/robots.txt"
    req = urllib.request.Request(robots_url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read(MAX_PAGE_BYTES).decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code in (404, 410)
    except (urllib.error.URLError, TimeoutError, OSError):
        return False
    rp = urllib.robotparser.RobotFileParser()
    rp.parse(body.splitlines())
    return rp.can_fetch(USER_AGENT, url)


def _fetch_public_html(url: str) -> str:
    """Plain public GET. Raises on login wall / error / non-HTML."""
    opener = urllib.request.build_opener(_NoRedirectToLogin)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with opener.open(req, timeout=15) as resp:
        if resp.status in _LOGIN_STATUS or _LOGIN_PATH_RE.search(
            urllib.parse.urlsplit(resp.geturl()).path or ""
        ):
            raise ValueError("login wall")
        ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
        if ctype and not ctype.startswith("text/html"):
            raise ValueError(f"not html: {ctype}")
        raw = resp.read(MAX_PAGE_BYTES + 1)[:MAX_PAGE_BYTES]
    return raw.decode("utf-8", "replace")


def extract_profile_image(page_url: str, html: str) -> str:
    """Absolute og:image / twitter:image URL, or ``""``."""
    for m in _META_IMG_RE.finditer(html):
        cm = _CONTENT_RE.search(m.group(0))
        if cm and cm.group(1).strip():
            img = urllib.parse.urljoin(page_url, cm.group(1).strip())
            return img if img.startswith(("http://", "https://")) else ""
    return ""


def profile_image(profile: dict) -> str:
    """The public profile image URL for one profile, or ``""``. Never raises."""
    url = profile["url"]
    try:
        if not _robots_allows(url):
            logger.info(
                "public-profile skip (robots/unreachable): %s", profile["platform"]
            )
            return ""
        return extract_profile_image(url, _fetch_public_html(url))
    except Exception as exc:  # noqa: BLE001 - one bad page must not break a dive
        logger.info("public-profile skip (%s): %s", profile["platform"], exc)
        return ""


def _personal_site(url: str) -> str:
    host = _host(url)
    if any(host == h or host.endswith("." + h) for h in PERSONAL_SITE_HOSTS):
        return PERSONAL_SITE
    return ""


async def _grounded_profiles(who: str, uid: str | None) -> list[dict] | None:
    """Discovery source 1: one Gemini call grounded with Google Search.
    ``None`` when the call failed (the result must not be cached)."""
    try:
        text, _sources = await gemini.research(
            f"Find the public profile pages of: {who}",
            system_prompt=_prompt(),
            uid=uid,
            feature=FEATURE_DEEPDIVE,
            max_output_tokens=1024,
        )
        return parse_profiles(text)
    except Exception:  # noqa: BLE001
        logger.warning("public-profile discovery failed", exc_info=True)
        return None


async def find_public_profile_images(
    name: str, *, extra_terms: str = "", uid: str | None = None
) -> list[dict]:
    """``[{url, source_page, platform}]`` candidate profile images for ``name``.

    ``[]`` when the flag is off, the name is empty, or anything fails. Results
    (URLs only, never image bytes) are cached in-process for 24h. Costs one
    grounded Gemini call, at most one Vertex AI Search query and at most
    :data:`MAX_PROFILES` page fetches."""
    if not enabled():
        return []
    name = (name or "").strip()
    if not name:
        return []
    extra_terms = (extra_terms or "").strip()
    key = f"{name.lower()}|{extra_terms.lower()}"
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < CACHE_TTL_SECONDS:
        return [dict(c) for c in hit[1]]
    who = f"{name} ({extra_terms})" if extra_terms else name
    grounded, indexed = await asyncio.gather(
        _grounded_profiles(who, uid),
        vertex_search.search_profiles(name, extra_terms),
    )
    if grounded is None and not indexed:
        return []
    profiles = list(grounded or [])
    seen = {p["platform"] for p in profiles}
    known_images: dict[str, str] = {}
    # Profile pages (short paths) before posts / repos on the same platform.
    indexed.sort(key=lambda h: len(urllib.parse.urlsplit(h["url"]).path.strip("/").split("/")))
    for found in indexed:
        platform = classify_platform(found["url"]) or _personal_site(found["url"])
        if not platform or platform in seen or len(profiles) >= MAX_PROFILES:
            continue
        seen.add(platform)
        profiles.append({"platform": platform, "url": found["url"]})
        if found["image"]:
            known_images[found["url"]] = found["image"]
    out: list[dict] = []
    for p in profiles:
        img = known_images.get(p["url"]) or await asyncio.to_thread(
            profile_image, p
        )
        if img:
            out.append(
                {"url": img, "source_page": p["url"], "platform": p["platform"]}
            )
    if len(_cache) >= _CACHE_MAX_ENTRIES:
        _cache.pop(next(iter(_cache)))
    _cache[key] = (time.time(), [dict(c) for c in out])
    return out
