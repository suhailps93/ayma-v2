"""Capped web search — the founder-approved restore of Ayma web search
(2026-11-07), built so the November 4 billing leak cannot repeat.

How it works:

* Ayma's brain stays on LiveKit Inference for ALL model work (permanent
  founder rule). The brain decides to search; this module then performs
  ONE lookup against a search provider and hands the results back to the
  model, which reads them and answers. A lookup is data retrieval, not
  inference — the same class as the kept Vertex AI Search and
  Programmable Search image paths (``docs/DIRECT_GOOGLE_KILL_AUDIT.md``).
  Grounded research on direct Google (:func:`gemini.research`) stays
  disabled; nothing here re-enables it.
* The provider is Google Programmable Search (Custom Search JSON API) —
  the retrieval path already wired for the deep-dive image step
  (:mod:`deep_dive_images`), so the key + engine id resolve from the same
  config, with ``WEB_SEARCH_*`` overrides. Google retires this API on
  2027-01-01, so the provider sits behind a small seam: config names it
  (``web_search_provider``) and :data:`_PROVIDERS` maps the name to its
  caller. Swapping to Brave/Tavily later is one new caller + config.
* HARD CAP (the point of the design): a Firestore counter at
  ``web_search_usage/{YYYY-MM-DD}`` — the America/Los_Angeles day, in
  this environment's own Firestore project — is checked AND incremented
  inside a single transaction BEFORE any provider call. The limit is the
  provider's free daily quota (100 by default). Call 101 is never made.
  If the counter store is unreachable or errors, the search FAILS
  CLOSED: no provider call. There is no path from :func:`search` to a
  provider that skips the counter, and no configuration removes the cap:
  the daily cap always resolves to a concrete number, and a cap of 0
  pauses search outright rather than lifting the limit.
* Honest states: callers get a typed :class:`SearchOutcome` — ``ok``
  (results), ``paused`` (today's free searches are used up; the day
  resets at midnight Pacific), ``unconfigured`` (no provider key/engine
  on this server), ``error`` (the lookup or the counter failed). This
  module never raises for those states, and never dresses a pause up as
  a temporary glitch or an internal error.
"""

from __future__ import annotations

import asyncio
import json
import logging
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime
from zoneinfo import ZoneInfo

from config import CONFIG

logger = logging.getLogger("ayma.web_search")

USAGE_COLLECTION = "web_search_usage"
_DAY_TZ = ZoneInfo("America/Los_Angeles")
_DEFAULT_CAP = 100
_TIMEOUT_SECONDS = 15
_RESULTS_PER_CALL = 10
_CSE_API_URL = "https://www.googleapis.com/customsearch/v1"
_RESERVE_ATTEMPTS = 3

STATUS_OK = "ok"
STATUS_PAUSED = "paused"
STATUS_UNCONFIGURED = "unconfigured"
STATUS_ERROR = "error"

PAUSED_MESSAGE = (
    "Web search is used up for today: Ayma gets 100 free searches a day "
    "and today's are all gone. It comes back tomorrow — the count resets "
    "at midnight Pacific. Tell the user exactly that, in plain words; do "
    "not call it a glitch or a temporary technical problem."
)
UNCONFIGURED_MESSAGE = (
    "Web search is not available right now: it is not set up on this "
    "server yet. Tell the user you cannot search the web at the moment; "
    "do not invent results."
)
ERROR_MESSAGE = (
    "The web search did not go through this time. Tell the user the "
    "search failed; do not invent results."
)


class SearchQuotaUnavailable(RuntimeError):
    """The daily-counter store failed; the caller must not search."""


class _ProviderError(RuntimeError):
    """One provider lookup failed; ``code`` is the HTTP status when known."""

    def __init__(self, message: str, *, code: int | None = None):
        super().__init__(message)
        self.code = code


@dataclass
class SearchResult:
    title: str
    url: str
    snippet: str


@dataclass
class SearchOutcome:
    status: str
    results: list[SearchResult] = field(default_factory=list)
    message: str = ""
    error_code: int | None = None


@dataclass
class _Settings:
    provider: str
    api_key: str
    engine_id: str
    cap: int


def _settings() -> _Settings:
    """Resolve the provider seam from config. The Programmable Search
    key/engine fall back to the deep-dive image step's pair (same
    account) unless the ``WEB_SEARCH_*`` overrides are set."""
    provider = (CONFIG.web_search_provider or "").strip() or "google_cse"
    api_key = (CONFIG.web_search_api_key or CONFIG.image_search_api_key or "").strip()
    engine_id = (CONFIG.web_search_cse_id or CONFIG.image_search_cse_id or "").strip()
    cap = CONFIG.web_search_daily_cap
    if not isinstance(cap, int):
        cap = _DEFAULT_CAP
    return _Settings(
        provider=provider, api_key=api_key, engine_id=engine_id, cap=cap
    )


def _today_pt(now: datetime | None = None) -> str:
    """The current America/Los_Angeles calendar day (``YYYY-MM-DD``) —
    the counter's day boundary is midnight Pacific, per the design."""
    if now is None:
        now = datetime.now(_DAY_TZ)
    elif now.tzinfo is None:
        now = now.replace(tzinfo=_DAY_TZ)
    return now.astimezone(_DAY_TZ).strftime("%Y-%m-%d")


def _is_contention(exc: Exception) -> bool:
    """Firestore transaction contention (aborted/conflict) is worth a
    fresh transaction; anything else from the store fails closed."""
    return type(exc).__name__ in ("Aborted", "Conflict")


def _reserve(db, day: str, cap: int) -> bool:
    """Atomically count one search against ``day``'s cap.

    True means the caller may make exactly one provider call. False
    means the cap is already reached — nothing is counted and no call
    may follow. The read, the limit check and the increment happen in
    one Firestore transaction, so concurrent instances cannot slip past
    the cap together. Raises :class:`SearchQuotaUnavailable` on any
    store failure: an unverifiable budget means no search (fail closed).
    """
    if cap <= 0:
        return False
    ref = db.collection(USAGE_COLLECTION).document(day)
    last_exc: Exception | None = None
    for _attempt in range(_RESERVE_ATTEMPTS):
        txn = db.transaction()
        try:
            snap = ref.get(transaction=txn)
            data = snap.to_dict() if snap.exists else None
            count = int((data or {}).get("count", 0) or 0)
            if count >= cap:
                return False
            if snap.exists:
                txn.update(ref, {"count": count + 1})
            else:
                txn.set(ref, {"count": 1, "day": day, "cap": cap})
            txn.commit()
            logger.info(
                "web search reserved (%d/%d for %s)", count + 1, cap, day
            )
            return True
        except Exception as exc:  # noqa: BLE001 - classified just below
            last_exc = exc
            if not _is_contention(exc):
                raise SearchQuotaUnavailable(
                    f"web-search quota store failed: {exc}"
                ) from exc
    raise SearchQuotaUnavailable(
        f"web-search quota store stayed contended: {last_exc}"
    )


def _google_cse_search(
    query: str, *, api_key: str, engine_id: str, num: int
) -> list[SearchResult]:
    """One Google Programmable Search (Custom Search JSON API) lookup —
    the same endpoint/shape :mod:`deep_dive_images` uses for image
    search, minus ``searchType=image``. Raises :class:`_ProviderError`."""
    params = urllib.parse.urlencode(
        {
            "key": api_key,
            "cx": engine_id,
            "q": query,
            "num": max(1, min(10, num)),
            "safe": "active",
        }
    )
    url = f"{_CSE_API_URL}?{params}"
    try:
        with urllib.request.urlopen(url, timeout=_TIMEOUT_SECONDS) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        raise _ProviderError(
            f"search provider HTTP {exc.code}", code=exc.code
        ) from exc
    except (urllib.error.URLError, ValueError, TimeoutError) as exc:
        raise _ProviderError(f"search provider failed: {exc}") from exc
    out: list[SearchResult] = []
    for item in data.get("items", []) or []:
        link = str(item.get("link") or "").strip()
        if not link:
            continue
        out.append(
            SearchResult(
                title=str(item.get("title") or "").strip(),
                url=link,
                snippet=str(item.get("snippet") or "").strip(),
            )
        )
    return out


# The provider seam: config names one of these. Adding Brave/Tavily for
# the 2027-01-01 Programmable Search retirement is one new caller here
# (same signature) plus its config — nothing else in the module moves.
_PROVIDERS = {"google_cse": _google_cse_search}


def _search_sync(
    query: str,
    *,
    num: int = _RESULTS_PER_CALL,
    db=None,
    now: datetime | None = None,
) -> SearchOutcome:
    query = (query or "").strip()
    if not query:
        return SearchOutcome(STATUS_ERROR, message=ERROR_MESSAGE)
    settings = _settings()
    caller = _PROVIDERS.get(settings.provider)
    if caller is None or not settings.api_key or not settings.engine_id:
        logger.warning(
            "web search unconfigured (provider=%s, key set=%s, engine set=%s)",
            settings.provider,
            bool(settings.api_key),
            bool(settings.engine_id),
        )
        return SearchOutcome(STATUS_UNCONFIGURED, message=UNCONFIGURED_MESSAGE)
    if db is None:
        from db import get_db

        db = get_db()
    day = _today_pt(now)
    try:
        allowed = _reserve(db, day, settings.cap)
    except SearchQuotaUnavailable as exc:
        logger.warning("web search fail-closed: %s", exc)
        return SearchOutcome(STATUS_ERROR, message=ERROR_MESSAGE)
    if not allowed:
        logger.info(
            "web search paused: daily free cap %d reached for %s",
            settings.cap,
            day,
        )
        return SearchOutcome(STATUS_PAUSED, message=PAUSED_MESSAGE)
    try:
        results = caller(
            query,
            api_key=settings.api_key,
            engine_id=settings.engine_id,
            num=num,
        )
    except _ProviderError as exc:
        logger.warning("web search provider error: %s", exc)
        return SearchOutcome(
            STATUS_ERROR, message=ERROR_MESSAGE, error_code=exc.code
        )
    return SearchOutcome(STATUS_OK, results=results)


async def search(
    query: str,
    *,
    num: int = _RESULTS_PER_CALL,
    db=None,
    now: datetime | None = None,
) -> SearchOutcome:
    """One capped web search. Never raises for quota or provider states —
    the outcome's ``status`` says which state the search is in. The daily
    counter is consulted (and incremented) before the provider is
    called, every time; there is no way to reach a provider from here
    without it."""
    return await asyncio.to_thread(_search_sync, query, num=num, db=db, now=now)


def format_outcome(outcome: SearchOutcome, query: str) -> str:
    """The tool-result text the LiveKit model reads after a search:
    the results themselves on success, or the honest state message."""
    if outcome.status == STATUS_OK:
        if not outcome.results:
            return (
                f'The web search for "{query}" came back with no results. '
                "Tell the user nothing turned up; do not invent results."
            )
        lines = [f'Web search results for "{query}":']
        for i, r in enumerate(outcome.results, 1):
            lines.append(f"{i}. {r.title} — {r.url}")
            if r.snippet:
                lines.append(f"   {r.snippet}")
        lines.append(
            "Answer from these results, and name the links you relied on."
        )
        return "\n".join(lines)
    return outcome.message
