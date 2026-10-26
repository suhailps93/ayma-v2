"""Vertex AI Search (Discovery Engine) over a public-website data store.

Second discovery source for :mod:`deep_dive_public_profiles`, next to the
grounded Gemini search. The data store (``scripts/vertex_search_setup.py``) is a
``PUBLIC_WEBSITE`` store of up to 50 URI patterns — major social platforms,
developer / creative portfolios, blogging and personal-site hosts, news. Google
crawls and indexes those pages itself (so robots.txt is Google's concern, there
is no login, and nothing here fetches a third-party page); a query returns
profile URLs plus the ``og:image`` Google already indexed.

Cost control: every query is billed (Enterprise tier, per 1,000 queries), so a
per-UTC-day counter in Firestore (``vertex_search_usage/{YYYY-MM-DD}``) caps
spend at ``vertex_ai_search_daily_cap`` queries across all instances. At the
cap, or on any error, the source simply returns nothing.
"""

from __future__ import annotations

import asyncio
import logging
import re
import urllib.parse
from datetime import datetime, timezone

import feature_flags
from config import CONFIG

logger = logging.getLogger("ayma.vertex_search")

USAGE_COLLECTION = "vertex_search_usage"
_API = "https://discoveryengine.googleapis.com/v1"
_PAGE_SIZE = 10
_TIMEOUT_SECONDS = 15
_SCOPES = ["https://www.googleapis.com/auth/cloud-platform"]

_session = None


def _authed_session():
    global _session
    if _session is None:
        import google.auth
        from google.auth.transport.requests import AuthorizedSession

        creds, _ = google.auth.default(scopes=_SCOPES)
        _session = AuthorizedSession(creds)
    return _session


def _serving_config() -> str:
    project = CONFIG.project_id
    if not project:
        raise RuntimeError("vertex_search needs GOOGLE_CLOUD_PROJECT")
    return (
        f"{_API}/projects/{project}/locations/global/collections/default_collection"
        f"/engines/{CONFIG.vertex_ai_search_engine}/servingConfigs/default_search"
    )


def _reserve_query() -> bool:
    """Count this query against today's cap; False when the cap is reached."""
    from google.cloud import firestore

    from db import get_db

    cap = feature_flags.get("vertex_ai_search_daily_cap")
    if cap <= 0:
        return False
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    ref = get_db().collection(USAGE_COLLECTION).document(day)
    ref.set({"count": firestore.Increment(1)}, merge=True)
    count = int((ref.get().to_dict() or {}).get("count", 0))
    if count > cap:
        logger.warning("vertex_search daily cap reached (%d/%d)", count, cap)
        return False
    logger.info("vertex_search query reserved (%d/%d today)", count, cap)
    return True


def _image_of(derived: dict) -> str:
    pagemap = derived.get("pagemap") or {}
    for meta in pagemap.get("metatags") or []:
        for key in ("og:image", "twitter:image"):
            val = meta.get(key)
            if isinstance(val, str) and val.startswith(("http://", "https://")):
                return val
    for key in ("cse_image", "cse_thumbnail"):
        for item in pagemap.get(key) or []:
            src = item.get("src")
            if isinstance(src, str) and src.startswith(("http://", "https://")):
                return src
    return ""


def parse_results(payload: dict, name: str) -> list[dict]:
    """``[{url, image}]`` for results whose title / snippet / URL mention every
    token of ``name``. ``image`` is the indexed og:image or ``""``."""
    tokens = [t for t in re.split(r"\W+", name.lower()) if len(t) > 1]
    out: list[dict] = []
    for res in payload.get("results") or []:
        derived = (res.get("document") or {}).get("derivedStructData") or {}
        link = str(derived.get("link") or "").strip()
        if not link.startswith(("http://", "https://")):
            continue
        snippets = " ".join(
            str(s.get("snippet") or "") for s in derived.get("snippets") or []
        )
        hay = f"{derived.get('title', '')} {snippets} {urllib.parse.unquote(link)}".lower()
        if tokens and not all(t in hay for t in tokens):
            continue
        out.append({"url": link, "image": _image_of(derived)})
    return out


def _search_sync(query: str, name: str) -> list[dict]:
    if not _reserve_query():
        return []
    resp = _authed_session().post(
        f"{_serving_config()}:search",
        json={"query": query, "pageSize": _PAGE_SIZE},
        timeout=_TIMEOUT_SECONDS,
    )
    resp.raise_for_status()
    return parse_results(resp.json(), name)


async def search_profiles(
    name: str, extra_terms: str = "", stats: dict | None = None
) -> list[dict]:
    """Public pages for ``name`` from the website data store: ``[{url, image}]``.
    ``[]`` when the flag is off, the cap is reached or anything fails. When
    ``stats`` is given it receives ``vertex_status`` (``off`` / ``ok`` /
    ``cap_or_empty`` / ``error``) and ``vertex_results``."""
    stats = stats if stats is not None else {}
    if not feature_flags.enabled("vertex_ai_search"):
        stats["vertex_status"] = "off"
        logger.info("vertex_search skipped: flag off")
        return []
    name = (name or "").strip()
    if not name:
        return []
    query = f"{name} {extra_terms}".strip()
    try:
        found = await asyncio.to_thread(_search_sync, query, name)
    except Exception:  # noqa: BLE001 - discovery is best-effort
        logger.warning("vertex_search failed", exc_info=True)
        stats["vertex_status"] = "error"
        stats["vertex_results"] = 0
        return []
    stats["vertex_status"] = "ok" if found else "cap_or_empty"
    stats["vertex_results"] = len(found)
    logger.info(
        "vertex_search returned %d matching pages (%d with an indexed image)",
        len(found), sum(1 for f in found if f["image"]),
    )
    return found
