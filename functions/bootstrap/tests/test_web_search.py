"""web_search.py — the capped Programmable Search restore (founder
2026-11-07), plus the chat-tool and research-report rewiring that rides
on it.

The guarantees under test are the founder's approved spend shape:

* calls 1-100 of a day go through; call 101 is blocked BEFORE any
  provider call (the counter is the only door to the provider);
* a counter-store failure means NO provider call (fail closed);
* the day boundary is midnight America/Los_Angeles;
* a paused day produces the honest "used up, back tomorrow" wording —
  never a fake internal error;
* the chat `web_search` tool runs on the capped path while
  `gemini.research()` (direct-Google grounding) still raises;
* the deep-dive sweep and public-profile discovery consume the same
  capped search and degrade honestly when it is paused.

Firestore and the provider HTTP call are faked — no network.
"""

from __future__ import annotations

import asyncio
import json
import urllib.error
from datetime import datetime
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest

import deep_dive
import deep_dive_public_profiles as pp
import gemini
import web_search

PT = ZoneInfo("America/Los_Angeles")
NOW = datetime(2026, 11, 7, 10, 0, tzinfo=PT)
RESULT = web_search.SearchResult(
    "Dana Reis — profile", "https://example.com/dana", "About Dana."
)


def _run(coro):
    return asyncio.run(coro)


async def _no_sleep(*a, **k):
    return None


# --- Firestore fake: just the surface web_search._reserve uses ---------


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _Txn:
    """Buffers writes and applies them on commit, like the real client."""

    def __init__(self, db):
        self._db = db
        self._writes = []

    def set(self, ref, data, merge=False):
        self._writes.append((ref.key, dict(data)))

    def update(self, ref, data):
        self._writes.append((ref.key, dict(data)))

    def commit(self):
        if self._db.fail_commit is not None:
            raise self._db.fail_commit
        for key, data in self._writes:
            cur = dict(self._db.docs.get(key) or {})
            cur.update(data)
            self._db.docs[key] = cur
        self._writes = []


class _Ref:
    def __init__(self, db, key):
        self._db = db
        self.key = key

    def get(self, transaction=None):
        if self._db.fail_get is not None:
            raise self._db.fail_get
        return _Snap(self._db.docs.get(self.key))


class _Collection:
    def __init__(self, db, name):
        self._db = db
        self._name = name

    def document(self, doc_id):
        return _Ref(self._db, (self._name, doc_id))


class _Db:
    def __init__(self):
        self.docs = {}
        self.fail_get = None
        self.fail_commit = None

    def collection(self, name):
        return _Collection(self, name)

    def transaction(self):
        return _Txn(self)


class Aborted(Exception):
    """Named like google.api_core's Aborted so contention handling sees it."""


def _settings(monkeypatch, *, key="k", engine="e", cap=100, provider="google_cse"):
    monkeypatch.setattr(
        web_search,
        "CONFIG",
        SimpleNamespace(
            web_search_provider=provider,
            web_search_api_key=key,
            web_search_cse_id=engine,
            web_search_daily_cap=cap,
            image_search_api_key="",
            image_search_cse_id="",
        ),
    )


def _stub_provider(monkeypatch, calls, results=None):
    def _call(query, *, api_key, engine_id, num):
        calls.append(query)
        return list(results if results is not None else [RESULT])

    monkeypatch.setitem(web_search._PROVIDERS, "google_cse", _call)


def _outcome(status, results=None, code=None, message=""):
    return web_search.SearchOutcome(
        status, results=results or [], message=message, error_code=code
    )


# --- the hard cap --------------------------------------------------------


def test_calls_1_to_100_go_through_and_101_is_blocked_before_any_call(
    monkeypatch,
):
    _settings(monkeypatch)
    db = _Db()
    calls = []
    _stub_provider(monkeypatch, calls)
    outcomes = [
        _run(web_search.search(f"q{i}", db=db, now=NOW)) for i in range(101)
    ]
    assert all(o.status == web_search.STATUS_OK for o in outcomes[:100])
    assert outcomes[100].status == web_search.STATUS_PAUSED
    assert len(calls) == 100  # the 101st search never reached the provider
    assert db.docs[("web_search_usage", "2026-11-07")]["count"] == 100


def test_counter_read_failure_fails_closed(monkeypatch):
    _settings(monkeypatch)
    db = _Db()
    db.fail_get = RuntimeError("firestore down")
    calls = []
    _stub_provider(monkeypatch, calls)
    outcome = _run(web_search.search("anything", db=db, now=NOW))
    assert outcome.status == web_search.STATUS_ERROR
    assert calls == []  # no budget check, no search — fail closed


def test_counter_commit_failure_fails_closed(monkeypatch):
    _settings(monkeypatch)
    db = _Db()
    db.fail_commit = RuntimeError("firestore down")
    calls = []
    _stub_provider(monkeypatch, calls)
    outcome = _run(web_search.search("anything", db=db, now=NOW))
    assert outcome.status == web_search.STATUS_ERROR
    assert calls == []


def test_counter_contention_exhaustion_fails_closed(monkeypatch):
    _settings(monkeypatch)
    db = _Db()
    db.fail_commit = Aborted("contended")
    calls = []
    _stub_provider(monkeypatch, calls)
    outcome = _run(web_search.search("anything", db=db, now=NOW))
    assert outcome.status == web_search.STATUS_ERROR
    assert calls == []


def test_day_boundary_is_midnight_pacific(monkeypatch):
    _settings(monkeypatch, cap=2)
    db = _Db()
    calls = []
    _stub_provider(monkeypatch, calls)
    late = datetime(2026, 11, 7, 23, 59, tzinfo=PT)
    early = datetime(2026, 11, 8, 0, 1, tzinfo=PT)
    assert _run(web_search.search("a", db=db, now=late)).status == "ok"
    assert _run(web_search.search("b", db=db, now=late)).status == "ok"
    assert _run(web_search.search("c", db=db, now=late)).status == "paused"
    assert _run(web_search.search("d", db=db, now=early)).status == "ok"
    assert db.docs[("web_search_usage", "2026-11-07")]["count"] == 2
    assert db.docs[("web_search_usage", "2026-11-08")]["count"] == 1
    assert len(calls) == 3


def test_unconfigured_search_never_reserves_and_never_calls(monkeypatch):
    _settings(monkeypatch, key="", engine="")
    db = _Db()
    calls = []
    _stub_provider(monkeypatch, calls)
    outcome = _run(web_search.search("anything", db=db, now=NOW))
    assert outcome.status == web_search.STATUS_UNCONFIGURED
    assert calls == []
    assert db.docs == {}  # an unconfigured server burns no quota


def test_paused_wording_is_honest():
    text = web_search.PAUSED_MESSAGE.lower()
    assert "used up for today" in text
    assert "tomorrow" in text
    assert "internal error" not in text
    assert "temporary technical problem" not in text.replace(
        "do not call it a glitch or a temporary technical problem", ""
    )


# --- the provider caller ---------------------------------------------------


def test_google_cse_payload_parsing_and_request_shape(monkeypatch):
    payload = {
        "items": [
            {"title": "A", "link": "https://a.example", "snippet": "sa"},
            {"title": "B", "link": "", "snippet": "sb"},
            {"title": "C", "link": "https://c.example"},
        ]
    }
    seen = {}

    class _Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return json.dumps(payload).encode()

    def _urlopen(url, timeout=None):
        seen["url"] = url
        return _Resp()

    monkeypatch.setattr(web_search.urllib.request, "urlopen", _urlopen)
    got = web_search._google_cse_search(
        "dana reis", api_key="K", engine_id="E", num=5
    )
    assert [r.url for r in got] == ["https://a.example", "https://c.example"]
    assert "cx=E" in seen["url"] and "key=K" in seen["url"]
    assert "searchType" not in seen["url"]  # web search, not image search


def test_google_cse_http_error_carries_its_code(monkeypatch):
    def _urlopen(url, timeout=None):
        raise urllib.error.HTTPError(url, 503, "unavailable", {}, None)

    monkeypatch.setattr(web_search.urllib.request, "urlopen", _urlopen)
    with pytest.raises(web_search._ProviderError) as excinfo:
        web_search._google_cse_search(
            "x", api_key="K", engine_id="E", num=5
        )
    assert excinfo.value.code == 503


# --- the chat tool ---------------------------------------------------------


def test_chat_tool_uses_capped_search_not_research(monkeypatch):
    async def _fake_search(query, **kw):
        return _outcome(web_search.STATUS_OK, [RESULT])

    async def _boom(*a, **k):
        raise AssertionError("the tool must not call gemini.research")

    monkeypatch.setattr(web_search, "search", _fake_search)
    monkeypatch.setattr(gemini, "research", _boom)
    out = _run(
        gemini._web_search_tool("who is Dana Reis", uid="u1", feature="chat")
    )
    assert "https://example.com/dana" in out
    assert "Dana Reis — profile" in out


def test_chat_tool_reports_a_pause_honestly(monkeypatch):
    async def _paused(query, **kw):
        return _outcome(
            web_search.STATUS_PAUSED, message=web_search.PAUSED_MESSAGE
        )

    monkeypatch.setattr(web_search, "search", _paused)
    out = _run(gemini._web_search_tool("news today", uid="u1", feature="chat"))
    assert "used up for today" in out
    assert "internal error" not in out.lower()


def test_research_itself_still_raises_direct_google_disabled():
    import llm_routing

    with pytest.raises(llm_routing.DirectGoogleDisabledError):
        _run(gemini.research("anything", uid="u1", feature="chat"))


# --- the research-report pipeline (deep dive + public profiles) ------------


def test_dive_sweep_builds_notes_and_sources(monkeypatch):
    async def _fake(query, **kw):
        return _outcome(web_search.STATUS_OK, [RESULT])

    monkeypatch.setattr(web_search, "search", _fake)
    prose, sources = _run(
        deep_dive._grounded_research(
            "Full name: Dana Reis\nContext: Lisbon\n\nResearch Dana Reis",
            uid="u1",
            name="Dana Reis",
            context="Lisbon",
        )
    )
    assert "Dana Reis — profile" in prose
    assert sources == [
        {"url": "https://example.com/dana", "title": "Dana Reis — profile"}
    ]


def test_dive_sweep_paused_returns_empty_and_stops(monkeypatch):
    calls = {"n": 0}

    async def _paused(query, **kw):
        calls["n"] += 1
        return _outcome(
            web_search.STATUS_PAUSED, message=web_search.PAUSED_MESSAGE
        )

    monkeypatch.setattr(web_search, "search", _paused)
    got = _run(
        deep_dive._grounded_research(
            "ask", uid="u1", name="Dana Reis", context=""
        )
    )
    assert got == ("", [])
    assert calls["n"] == 1  # a paused day stops the sweep at once


def test_dive_sweep_transient_error_is_retried(monkeypatch):
    attempts = {"n": 0}

    async def _flaky(query, **kw):
        attempts["n"] += 1
        if attempts["n"] == 1:
            return _outcome(web_search.STATUS_ERROR, code=503)
        return _outcome(web_search.STATUS_OK, [RESULT])

    monkeypatch.setattr(web_search, "search", _flaky)
    monkeypatch.setattr(deep_dive.asyncio, "sleep", _no_sleep)
    prose, _sources = _run(
        deep_dive._grounded_research(
            "ask", uid="u1", name="Dana Reis", context=""
        )
    )
    assert "Dana Reis — profile" in prose
    assert attempts["n"] >= 2


def test_grounded_profiles_come_from_search_results(monkeypatch):
    async def _fake(query, **kw):
        return _outcome(
            web_search.STATUS_OK,
            [
                web_search.SearchResult(
                    "Dana on GitHub", "https://github.com/dana-reis", ""
                ),
                web_search.SearchResult(
                    "Dana elsewhere", "https://news.example/story", ""
                ),
            ],
        )

    monkeypatch.setattr(web_search, "search", _fake)
    got = _run(pp._grounded_profiles("Dana Reis", "u1"))
    assert {"platform": "github", "url": "https://github.com/dana-reis"} in got
    assert all(p["url"] != "https://news.example/story" for p in got)


def test_grounded_profiles_paused_returns_none(monkeypatch):
    async def _paused(query, **kw):
        return _outcome(
            web_search.STATUS_PAUSED, message=web_search.PAUSED_MESSAGE
        )

    monkeypatch.setattr(web_search, "search", _paused)
    assert _run(pp._grounded_profiles("Dana Reis", "u1")) is None
