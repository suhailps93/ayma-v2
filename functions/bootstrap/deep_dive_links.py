"""Deep-dive link hygiene: de-duplicate the Links and Social profiles lists
and make sure every URL a report shows actually works.

Two jobs, both free of any Firestore access:

* :func:`clean_links_and_socials` - normalise URLs (scheme, ``www``, tracking
  params, trailing slash, case), keep ONE social profile per platform (the
  best-verified wins) and keep Links to non-social pages only.
* :func:`validate_report_urls` - check each URL over the SSRF-safe
  ``public_url`` helper (honest UA, robots.txt, HEAD then GET, <= 5
  redirects, short timeouts, bounded parallelism, a total time budget). Dead
  (404/410/5xx/DNS/timeout), soft-404 and redirect-to-homepage/login URLs are
  dropped. Login-walled platforms (LinkedIn, Instagram, Facebook, X) answer
  bots with a wall, so those are kept only when the URL came from a grounded
  search result and has a profile-shaped path. :func:`resolve_sources` first
  turns Google grounding redirects into their real destination. Results are
  cached per URL for 24h. Never invents or guesses a URL.
"""
from __future__ import annotations

import logging
import re
import threading
import time
import urllib.error
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, wait
from datetime import datetime, timezone

import deep_dive_public_profiles as _profiles
import feature_flags
import deep_dive_social
import public_url

logger = logging.getLogger("ayma.deepdive.links")

USER_AGENT = _profiles.USER_AGENT
CACHE_TTL_SECONDS = 24 * 3600
MAX_WORKERS = 8
TOTAL_BUDGET_SECONDS = 25.0
REQUEST_TIMEOUT = 6
MAX_BODY_BYTES = 64 * 1024
GROUNDING_HOSTS = ("vertexaisearch.cloud.google.com",)
GROUNDING_PATH_MARKER = "grounding-api-redirect"

# Platforms that answer bots with a login wall / 401 / 403 / 429 / 999.
_LOGIN_WALLED = {"linkedin", "instagram", "facebook", "x"}
_BOT_STATUS = {401, 403, 429, 999}
_TRACKING_PARAMS = {
    "fbclid", "gclid", "dclid", "msclkid", "igshid", "igsh", "mc_cid",
    "mc_eid", "ref", "ref_src", "ref_url", "si", "feature", "trk",
    "trkinfo", "cmpid", "_hsenc", "_hsmi", "spm",
}
_SOFT_404_RE = re.compile(
    r"(<title[^>]*>[^<]*\b(404|not found|page unavailable)\b)"
    r"|(\b(page|profile|account|user|channel)\s+"
    r"(not found|isn.t available|is unavailable|doesn.t exist|does not exist|"
    r"no longer available|could not be found)\b)"
    r"|(\bthis (page|profile|account) (isn.t available|doesn.t exist|"
    r"is not available)\b)",
    re.I,
)

_cache: dict[str, tuple[float, bool]] = {}
_cache_lock = threading.Lock()


def _reset_cache() -> None:
    with _cache_lock:
        _cache.clear()


# --- normalisation ----------------------------------------------------------


def url_key(url: str) -> str:
    """Comparison key: no scheme, no ``www``/``m``, lower-cased host, no
    fragment, no tracking params, sorted remaining query, no trailing slash."""
    raw = (url or "").strip()
    if not raw:
        return ""
    if "//" not in raw:
        raw = "https://" + raw
    try:
        p = urllib.parse.urlsplit(raw)
    except ValueError:
        return ""
    host = re.sub(r"^(www|m|mobile)\.", "", (p.hostname or "").lower())
    if not host:
        return ""
    pairs = sorted(
        (k, v)
        for k, v in urllib.parse.parse_qsl(p.query)
        if k.lower() not in _TRACKING_PARAMS and not k.lower().startswith("utm_")
    )
    query = urllib.parse.urlencode(pairs)
    path = urllib.parse.unquote(p.path or "").rstrip("/")
    return host + path + (("?" + query) if query else "")


def _profile_of(url: str) -> dict | None:
    return deep_dive_social._candidate_from_url(url)


def _social_rank(s: dict) -> tuple:
    return (
        0 if s.get("confidence") == "high" else 1,
        -len(s.get("verified_by") or []),
    )


def clean_links_and_socials(
    links: list[dict] | None, socials: list[dict] | None
) -> tuple[list[dict], list[dict]]:
    """``(links, socials)`` de-duplicated across both lists. Socials: one per
    platform, best (verified, most evidence) wins, first seen breaks ties.
    Links: only non-profile pages, one per normalised URL."""
    best: dict[str, dict] = {}
    for s in socials or []:
        if not isinstance(s, dict) or not s.get("url"):
            continue
        cand = _profile_of(str(s["url"]))
        platform = str(s.get("platform") or (cand or {}).get("platform") or "")
        platform = platform.strip().lower()
        if not platform:
            continue
        s = dict(s)
        s["platform"] = platform
        if cand and not s.get("handle"):
            s["handle"] = cand["handle"]
        cur = best.get(platform)
        if cur is None or _social_rank(s) < _social_rank(cur):
            best[platform] = s

    seen: set[str] = set()
    out_links: list[dict] = []
    for ln in links or []:
        if not isinstance(ln, dict) or not ln.get("url"):
            continue
        url = str(ln["url"])
        if _profile_of(url) is not None:
            continue
        key = url_key(url)
        if not key or key in seen:
            continue
        seen.add(key)
        out_links.append(ln)
    return out_links, list(best.values())


# --- grounding redirects ----------------------------------------------------


def is_grounding_url(url: str) -> bool:
    try:
        p = urllib.parse.urlsplit(url or "")
    except ValueError:
        return False
    return (p.hostname or "") in GROUNDING_HOSTS or GROUNDING_PATH_MARKER in (
        p.path or ""
    )


class _CaptureRedirect(public_url.PublicOnlyRedirectHandler):
    """Stops at the first redirect so its ``Location`` can be read."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(newurl, code, msg, headers, fp)


def resolve_grounding_url(url: str) -> str:
    """The real destination of a Google grounding redirect, or ``""`` when it
    cannot be resolved (never guessed). Other URLs pass through unchanged."""
    current = (url or "").strip()
    for _ in range(5):
        if not is_grounding_url(current):
            return current
        try:
            with public_url.open_public(
                current,
                headers={"User-Agent": USER_AGENT},
                timeout=REQUEST_TIMEOUT,
                redirect_handler=_CaptureRedirect(),
                method="HEAD",
            ):
                return ""
        except urllib.error.HTTPError as exc:
            loc = exc.headers.get("Location") if exc.headers else None
            if exc.code in (301, 302, 303, 307, 308) and loc:
                current = urllib.parse.urljoin(current, loc)
                continue
            return ""
        except (public_url.BlockedURL, urllib.error.URLError, TimeoutError, OSError):
            return ""
    return ""


def resolve_sources(sources: list[dict]) -> list[dict]:
    """``sources`` with grounding redirects replaced by their final URL
    (unresolvable ones get ``url == ""``). Parallel, order preserved."""
    if not sources:
        return []
    pool = ThreadPoolExecutor(max_workers=MAX_WORKERS)
    futures = [pool.submit(resolve_grounding_url, s.get("url", "")) for s in sources]
    wait(futures, timeout=TOTAL_BUDGET_SECONDS)
    pool.shutdown(wait=False, cancel_futures=True)
    finals = [
        f.result() if f.done() and not f.cancelled() and not f.exception() else ""
        for f in futures
    ]
    return [{**s, "url": u} for s, u in zip(sources, finals)]


# --- validation ---------------------------------------------------------------


class _Max5Redirects(public_url.PublicOnlyRedirectHandler):
    max_redirections = 5


def _fetch(url: str, method: str):
    return public_url.open_public(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "text/html,*/*;q=0.5"},
        timeout=REQUEST_TIMEOUT,
        redirect_handler=_Max5Redirects(),
        method=method,
    )


def _redirected_to_generic(original: str, final: str) -> bool:
    o, f = urllib.parse.urlsplit(original), urllib.parse.urlsplit(final)
    if (o.path or "/").strip("/") and not (f.path or "/").strip("/"):
        return True
    return bool(_profiles._LOGIN_PATH_RE.search(f.path or ""))


def _check(url: str, grounded: bool) -> bool:
    """Whether ``url`` is a working page (see module doc). Never raises."""
    try:
        host = deep_dive_social._norm_host(urllib.parse.urlsplit(url).netloc)
    except ValueError:
        return False
    if deep_dive_social._HOST_PLATFORM.get(host) in _LOGIN_WALLED:
        return grounded and _profile_of(url) is not None
    try:
        if not _profiles._robots_allows(url):
            return grounded
        try:
            with _fetch(url, "HEAD"):
                pass
        except urllib.error.HTTPError as exc:
            if exc.code in (404, 410) or 500 <= exc.code < 600 and exc.code != 501:
                return False
        with _fetch(url, "GET") as resp:
            if _redirected_to_generic(url, resp.geturl()):
                return False
            body = resp.read(MAX_BODY_BYTES).decode("utf-8", "replace")
        return _SOFT_404_RE.search(body) is None
    except urllib.error.HTTPError as exc:
        return grounded if exc.code in _BOT_STATUS else False
    except (public_url.BlockedURL, urllib.error.URLError, TimeoutError, OSError):
        return False
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive link check crashed")
        return False


def _check_cached(url: str, grounded: bool) -> bool:
    key = f"{url_key(url)}|{int(grounded)}"
    with _cache_lock:
        hit = _cache.get(key)
        if hit and time.monotonic() - hit[0] < CACHE_TTL_SECONDS:
            return hit[1]
    ok = _check(url, grounded)
    with _cache_lock:
        _cache[key] = (time.monotonic(), ok)
    return ok


def check_urls(urls: dict[str, bool]) -> dict[str, bool]:
    """``{url: ok}`` for ``{url: grounded}``. Parallel, bounded by
    ``MAX_WORKERS`` and ``TOTAL_BUDGET_SECONDS``; a URL still pending when
    the budget ends counts as not working."""
    if not urls:
        return {}
    pool = ThreadPoolExecutor(max_workers=MAX_WORKERS)
    futures = {u: pool.submit(_check_cached, u, g) for u, g in urls.items()}
    wait(list(futures.values()), timeout=TOTAL_BUDGET_SECONDS)
    pool.shutdown(wait=False, cancel_futures=True)
    return {
        u: bool(f.done() and not f.cancelled() and not f.exception() and f.result())
        for u, f in futures.items()
    }


def validate_report_urls(
    links: list[dict],
    socials: list[dict],
    images: list[dict],
    facts: list[dict],
    grounded_urls: set[str],
    *,
    trust_login_walled: bool = False,
) -> tuple[list[dict], list[dict], list[dict], list[dict]]:
    """Drop dead links / socials / photos whose source page is dead, and
    blank a fact's dead ``source_url``. ``grounded_urls`` are URLs from search
    citations; ``trust_login_walled`` treats every URL as grounded (used when
    re-validating a stored report, whose grounding is no longer known). Logs
    counts only."""
    grounded_keys = {url_key(u) for u in grounded_urls}

    def is_grounded(u: str) -> bool:
        return trust_login_walled or url_key(u) in grounded_keys

    wanted: dict[str, bool] = {}
    for item in links + socials:
        wanted[item["url"]] = is_grounded(item["url"])
    for item in images:
        if item.get("source_page"):
            wanted[item["source_page"]] = is_grounded(item["source_page"])
    for item in facts:
        if item.get("source_url"):
            wanted[item["source_url"]] = is_grounded(item["source_url"])
    ok = check_urls(wanted)

    kept_links = [x for x in links if ok.get(x["url"])]
    kept_socials = [x for x in socials if ok.get(x["url"])]
    kept_images = [
        x for x in images if not x.get("source_page") or ok.get(x["source_page"])
    ]
    new_facts = [
        {**f, "source_url": ""}
        if f.get("source_url") and not ok.get(f["source_url"])
        else f
        for f in facts
    ]
    logger.info(
        "deep-dive links validated: links %d/%d, socials %d/%d, photos %d/%d, "
        "fact sources dropped %d",
        len(kept_links), len(links), len(kept_socials), len(socials),
        len(kept_images), len(images),
        sum(1 for a, b in zip(facts, new_facts) if a.get("source_url") != b.get("source_url")),
    )
    return kept_links, kept_socials, kept_images, new_facts


# --- stored reports -----------------------------------------------------------

_inflight: set[str] = set()
_inflight_lock = threading.Lock()


def _revalidate(db, uid: str, report_id: str, digest: dict) -> None:
    import deep_dive

    links, socials = clean_links_and_socials(
        digest.get("links"), digest.get("social_handles")
    )
    links, socials, images, facts = validate_report_urls(
        links,
        socials,
        [i for i in digest.get("web_images") or [] if isinstance(i, dict)],
        [f for f in digest.get("facts") or [] if isinstance(f, dict)],
        set(),
        trust_login_walled=True,
    )
    updated = {
        **digest,
        "links": links,
        "social_handles": socials,
        "web_images": images,
        "facts": facts,
        "links_validated_at": datetime.now(timezone.utc).isoformat(),
    }
    deep_dive._cache_ref(db, uid, report_id).set({"digest": updated}, merge=True)


def revalidate_in_background(db, uid: str, report_id: str, digest: dict) -> None:
    """Validate a stored report's URLs off the request path when it has never
    been validated (older reports), writing the cleaned digest back so the
    next open shows only working links. Best-effort; a no-op when the
    ``deepdive_validate_links`` flag is off, the report is already validated,
    or a run for it is in flight."""
    if db is None or digest.get("links_validated_at"):
        return
    if not feature_flags.enabled("deepdive_validate_links"):
        return
    key = f"{uid}/{report_id}"
    with _inflight_lock:
        if key in _inflight:
            return
        _inflight.add(key)

    def work() -> None:
        try:
            _revalidate(db, uid, report_id, digest)
        except Exception:  # noqa: BLE001
            logger.exception("deep-dive stored-report link revalidation failed")
        finally:
            with _inflight_lock:
                _inflight.discard(key)

    threading.Thread(target=work, name="deepdive-link-revalidate", daemon=True).start()
