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
import math
import re
import urllib.error
import urllib.parse
import urllib.request
from functools import lru_cache
from pathlib import Path

import biometric_consent
import gemini
import deep_dive_public_profiles
import media_embed
import public_url
import schema
from config import CONFIG
from token_ledger import FEATURE_DEEPDIVE

logger = logging.getLogger("ayma.deepdive.images")

_FACE_CHECK_PROMPT_PATH = (
    Path(__file__).with_name("prompts") / "web_image_face_check.md"
)
_FACE_CHECK_SCHEMA = {
    "type": "object",
    "properties": {"has_face": {"type": "boolean"}},
    "required": ["has_face"],
}

# Multimodal-embedding cosine over two real face crops of the same person sits
# comfortably above this; different people land well below.
_VERIFY_THRESHOLD = 0.55
# The gap below `_VERIFY_THRESHOLD` that still counts as "can't tell" rather
# than a confident "not them" — shared with every other same-person check in
# the app (main._classify_shared_photo, auto_analysis's photo gating) so the
# margin lives in exactly one place.
_VERIFY_MARGIN = 0.08
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


def _reference_embeddings(db, uid: str) -> list[list[float]]:
    """The person's own profile-photo face embeddings (``user_media`` docs)."""
    try:
        snaps = list(
            db.collection("users").document(uid).collection("user_media").stream()
        )
    except Exception:  # noqa: BLE001
        return []
    vecs: list[list[float]] = []
    for s in snaps:
        raw = (s.to_dict() or {}).get("embedding")
        if raw is None:
            continue
        try:
            vec = list(raw)  # firestore Vector is iterable
        except TypeError:
            vec = list(getattr(raw, "value", []) or [])
        if vec:
            vecs.append([float(x) for x in vec])
    return vecs


def _vec_from_raw(raw) -> list[float] | None:
    """A plain ``list[float]`` from a Firestore ``Vector`` (or anything else
    iterable) field — the same shape ``user_media.embedding`` and
    ``users/{uid}.face_verification.embedding`` are stored in."""
    if raw is None:
        return None
    try:
        return [float(x) for x in raw]
    except TypeError:
        v = getattr(raw, "value", None)
        return [float(x) for x in v] if v else None


def reference_embeddings_for(db, uid: str) -> list[list[float]]:
    """The most authoritative face-match reference available for ``uid``:

    * a verified selfie embedding (``users/{uid}.face_verification``,
      §"pre-boarding verification") when one exists — a single, deliberately
      captured, front-camera reference photo;
    * nothing (``[]``) when ``uid`` has no biometric consent
      (:mod:`biometric_consent`) — every caller then skips its face match;
    * otherwise the legacy behavior: every profile-photo embedding
      (:func:`_reference_embeddings`), so unverified/legacy accounts keep
      working exactly as before — no regression, no blocking.

    Best-effort: any read failure falls back to the profile-photo path
    (itself best-effort, returning ``[]`` on error)."""
    if not biometric_consent.has_consent(db, uid):
        return []
    try:
        snap = db.collection("users").document(uid).get()
        data = (snap.to_dict() or {}) if getattr(snap, "exists", False) else {}
        fv = data.get(schema.FIELD_FACE_VERIFICATION) or {}
        vec = _vec_from_raw(fv.get(schema.FACE_VERIFICATION_EMBEDDING))
        if vec:
            return [vec]
    except Exception:  # noqa: BLE001
        logger.warning(
            "reference_embeddings_for: face_verification read failed for %s",
            uid, exc_info=True,
        )
    return _reference_embeddings(db, uid)


def classify_face_match(
    embedding: list[float],
    refs: list[list[float]],
    *,
    threshold: float = _VERIFY_THRESHOLD,
    margin: float = _VERIFY_MARGIN,
) -> str:
    """``"self"`` / ``"not_self"`` / ``"unknown"`` for one face embedding
    against a set of reference embeddings for the same account.

    ``"unknown"`` whenever there is nothing to compare against, or the
    similarity falls in the band between "confidently them" and "confidently
    not them". Never raises."""
    if not refs or not embedding:
        return "unknown"
    try:
        sim = max((_cosine(embedding, r) for r in refs), default=0.0)
    except Exception:  # noqa: BLE001
        return "unknown"
    if sim >= threshold:
        return "self"
    if sim < threshold - margin:
        return "not_self"
    return "unknown"


def _cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


@lru_cache(maxsize=1)
def _face_check_prompt() -> str:
    return _FACE_CHECK_PROMPT_PATH.read_text(encoding="utf-8").strip()


async def _has_detectable_face(
    image_bytes: bytes, mime_type: str, *, uid: str | None = None
) -> bool:
    """Whether a web-found candidate image actually shows a real, photographed
    human face — the gate a bare embedding-similarity score can't provide (see
    module docstring). Fails **closed**: any model/parse failure counts as "no
    face" rather than letting an unverifiable image through as a person-match.
    ``enforce_cap=False`` — this is Ayma-initiated background verification
    work, not something that should fail a legitimate match just because the
    account is out of credits."""
    try:
        result = await gemini.generate_json(
            "Does this image contain at least one real, photographed human "
            "face?",
            system_prompt=_face_check_prompt(),
            response_schema=_FACE_CHECK_SCHEMA,
            image=(image_bytes, mime_type),
            uid=uid,
            feature=FEATURE_DEEPDIVE,
            enforce_cap=False,
        )
    except Exception:  # noqa: BLE001
        logger.warning(
            "web-image face check failed — treating as no face", exc_info=True
        )
        return False
    return isinstance(result, dict) and bool(result.get("has_face"))


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
    name = (name or "").strip()
    if not name:
        return []
    if not (db and target_uid and biometric_consent.has_consent(db, target_uid)):
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
    if not deep_dive_public_profiles.region_blocked(location):
        try:
            candidates.extend(
                await deep_dive_public_profiles.find_public_profile_images(
                    name, extra_terms=extra_terms, uid=uid
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
    if not deduped:
        return []

    refs = reference_embeddings_for(db, target_uid) if (db and target_uid) else []

    scored: list[dict] = []
    for c in deduped:
        try:
            img, mime = _fetch_image(c["url"])
        except Exception:  # noqa: BLE001
            continue
        if not img:
            continue
        try:
            emb = media_embed.embed_image_bytes(img, mime)
        except Exception:  # noqa: BLE001
            continue
        sim = max((_cosine(emb, r) for r in refs), default=0.0) if refs else 0.0
        would_verify = bool(refs) and sim >= threshold
        # Only spend a face-check call on candidates that would otherwise be
        # marked verified — a similarity miss is already excluded, so there's
        # nothing this gate needs to add for it.
        has_face = (
            await _has_detectable_face(img, mime, uid=uid)
            if would_verify
            else True
        )
        scored.append(
            {
                "url": c["url"],
                "source_page": c.get("source_page", ""),
                **({"platform": c["platform"]} if c.get("platform") else {}),
                "similarity": round(sim, 4) if refs else None,
                "verified": would_verify and has_face,
            }
        )

    if refs:
        verified = [s for s in scored if s["verified"]]
        for s in verified:
            if s.get("platform"):
                logger.info(
                    "deep-dive verified image from platform=%s sim=%s",
                    s["platform"], s["similarity"],
                )
        verified.sort(key=lambda s: s["similarity"] or 0.0, reverse=True)
        return verified
    # No reference embedding to check against — hand back a few, clearly
    # unverified, so the UI can label them.
    return scored[:_KEEP_UNVERIFIED]
