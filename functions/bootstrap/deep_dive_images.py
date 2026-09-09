"""Deep-dive web image search + face verification.

For a deep dive on a person (self *or* an Explore user), search the open web for
photos of that person and keep only the ones whose face matches that person's
own profile photos. Returns ``[{url, source_page, similarity, verified}]``.

No-op — returns ``[]`` and logs one warning — when the Programmable Search key
(``IMAGE_SEARCH_API_KEY`` / ``IMAGE_SEARCH_CSE_ID``) isn't configured. The deep
dive still runs; it just carries no web images.
"""

from __future__ import annotations

import json
import logging
import math
import urllib.error
import urllib.parse
import urllib.request

import media_embed
from config import CONFIG

logger = logging.getLogger("ayma.deepdive.images")

# Multimodal-embedding cosine over two real face crops of the same person sits
# comfortably above this; different people land well below.
_VERIFY_THRESHOLD = 0.55
_MAX_CANDIDATES = 10
_MAX_IMAGE_BYTES = 6 * 1024 * 1024
_KEEP_UNVERIFIED = 3


def _search_image_urls(query: str, count: int) -> list[dict]:
    """Google Custom Search JSON API, ``searchType=image``. Returns
    ``[{url, source_page}]``. Empty on any failure or missing config."""
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
            "num": max(1, min(10, count)),
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
    return out[:count]


def _fetch_image(url: str) -> tuple[bytes, str]:
    """Download a web image. Raises on failure / non-image / oversize."""
    req = urllib.request.Request(
        url, headers={"User-Agent": "Mozilla/5.0 (AymaDeepDive)"}
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        mime = (resp.headers.get("Content-Type") or "image/jpeg").split(";")[0]
        if not mime.startswith("image/"):
            raise ValueError(f"not an image: {mime}")
        data = resp.read(_MAX_IMAGE_BYTES + 1)
    if len(data) > _MAX_IMAGE_BYTES:
        raise ValueError("image too large")
    return data, mime


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


def _cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def find_web_images(
    db,
    target_uid: str,
    name: str,
    *,
    extra_terms: str = "",
    max_candidates: int = _MAX_CANDIDATES,
    threshold: float = _VERIFY_THRESHOLD,
) -> list[dict]:
    """Search + face-verify. Returns the verified matches (or, when the target
    has no usable reference embedding, up to a few candidates marked
    ``verified: False``). Never raises."""
    name = (name or "").strip()
    if not name:
        return []
    query = f"{name} {extra_terms}".strip()
    try:
        candidates = _search_image_urls(query, max_candidates)
    except Exception:  # noqa: BLE001
        logger.exception("deep-dive image search crashed")
        return []
    if not candidates:
        return []

    refs = _reference_embeddings(db, target_uid) if (db and target_uid) else []

    scored: list[dict] = []
    for c in candidates:
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
        scored.append(
            {
                "url": c["url"],
                "source_page": c.get("source_page", ""),
                "similarity": round(sim, 4) if refs else None,
                "verified": bool(refs) and sim >= threshold,
            }
        )

    if refs:
        verified = [s for s in scored if s["verified"]]
        verified.sort(key=lambda s: s["similarity"] or 0.0, reverse=True)
        return verified
    # No reference embedding to check against — hand back a few, clearly
    # unverified, so the UI can label them.
    return scored[:_KEEP_UNVERIFIED]
