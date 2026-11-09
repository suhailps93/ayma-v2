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
    """Mirrors the real client's transaction contract (google-cloud-
    firestore 2.x): a transaction handed out by db.transaction() is NOT
    in progress, and any read or write through it raises "Transaction
    not in progress, cannot be used in API requests." until it has been
    begun — which in the real client only the firestore.transactional
    machinery does (via _clean_up/_begin/_commit/_rollback).

    The pre-fix fake ignored transaction state entirely, so the unit
    tests stayed green while production web search failed closed on
    every single call on 2026-11-07: web_search._reserve used a
    hand-rolled transaction that was never begun, its first read
    raised, and the module (by design) turned that into a failed
    search. Chat and the deep-dive sweep both died on it.
    """

    def __init__(self, db):
        self._db = db
        self._writes = []
        self.in_progress = False
        self._id = None
        self._read_only = False
        self._max_attempts = 5

    # -- surface used by firestore.transactional ----------------------
    def _clean_up(self):
        self._writes = []
        self.in_progress = False

    def _begin(self, retry_id=None):
        self._id = ("txn", id(self))
        self.in_progress = True

    def _commit(self):
        self.commit()

    def _rollback(self):
        self._writes = []
        self.in_progress = False

    # -- write surface --------------------------------------------------
    def _require_in_progress(self):
        if not self.in_progress:
            raise ValueError(
                "Transaction not in progress, cannot be used in API requests."
            )

    def set(self, ref, data, merge=False):
        self._require_in_progress()
        self._writes.append((ref.key, dict(data)))

    def update(self, ref, data):
        self._require_in_progress()
        self._writes.append((ref.key, dict(data)))

    def commit(self):
        self._require_in_progress()
        self.in_progress = False
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
        if transaction is not None and not transaction.in_progress:
            raise ValueError(
                "Transaction not in progress, cannot be used in API requests."
            )
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


def test_search_succeeds_against_a_client_faithful_transaction(monkeypatch):
    """Regression for the 2026-11-07 live failure. The quota reserve ran
    its read-check-increment on a hand-rolled Firestore transaction that
    the real client library never begins, so the first read raised
    "Transaction not in progress" and EVERY search failed closed — the
    founder's chat ask and his research-report rerun both died while the
    old fake (which ignored transaction state) kept the suite green.
    The fake now enforces the real contract, so this only passes when
    the reserve runs inside a properly begun transaction."""
    _settings(monkeypatch, key="serper-key", engine="", provider="serper")
    db = _Db()
    calls = []
    _stub_serper(monkeypatch, calls)
    first = _run(web_search.search("one", db=db, now=NOW))
    second = _run(web_search.search("two", db=db, now=NOW))
    assert first.status == web_search.STATUS_OK
    assert second.status == web_search.STATUS_OK
    assert calls == ["one", "two"]
    assert db.docs[("web_search_usage", "2026-11-07")]["count"] == 2


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


def test_counter_error_before_transaction_starts_denies_the_call(monkeypatch):
    """Regression test for ledger websearch-reserve: a counter error raised
    BEFORE the transaction starts (e.g. collection lookup or transaction
    creation fails) must fail closed — denying the search and making no
    provider call."""
    _settings(monkeypatch)

    class _BrokenCollectionDb:
        def collection(self, name):
            raise RuntimeError("firestore collection down")

    calls = []
    _stub_provider(monkeypatch, calls)
    outcome = _run(web_search.search("anything", db=_BrokenCollectionDb(), now=NOW))
    assert outcome.status == web_search.STATUS_ERROR
    assert calls == []

    class _BrokenTxnDb:
        def collection(self, name):
            return _Collection(self, name)

        def transaction(self):
            raise RuntimeError("firestore transaction down")

    outcome2 = _run(web_search.search("anything", db=_BrokenTxnDb(), now=NOW))
    assert outcome2.status == web_search.STATUS_ERROR
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


def _bound_tool():
    """The web_search tool as both surfaces receive it: the registry
    skill bound to a session (db, uid)."""
    from skills import web_search as web_search_skill

    return web_search_skill.SKILL.bind(_Db(), "u1")


def test_chat_tool_uses_capped_search_not_research(monkeypatch):
    async def _fake_search(query, **kw):
        return _outcome(web_search.STATUS_OK, [RESULT])

    async def _boom(*a, **k):
        raise AssertionError("the tool must not call gemini.research")

    monkeypatch.setattr(web_search, "search", _fake_search)
    monkeypatch.setattr(gemini, "research", _boom)
    out = _run(_bound_tool()("who is Dana Reis"))
    assert "https://example.com/dana" in out
    assert "Dana Reis — profile" in out


def test_chat_tool_reports_a_pause_honestly(monkeypatch):
    async def _paused(query, **kw):
        return _outcome(
            web_search.STATUS_PAUSED, message=web_search.PAUSED_MESSAGE
        )

    monkeypatch.setattr(web_search, "search", _paused)
    out = _run(_bound_tool()("news today"))
    assert "used up for today" in out
    assert "internal error" not in out.lower()


def test_web_search_tool_in_both_surfaces_only_when_switch_on(monkeypatch):
    """Regression for the 2026-11-07 voice gap: web_search used to be
    hand-appended to the TEXT tool set inside gemini.py, so the voice
    tool set (built from this same registry composition) never had it —
    asked to search mid voice call, Ayma had no search tool at all.
    The tool must now ride the shared composition both surfaces draw
    from, and only while the GEMINI_WEB_SEARCH switch is on."""
    import dataclasses

    import config
    import skills

    monkeypatch.setattr(
        config,
        "CONFIG",
        dataclasses.replace(config.CONFIG, gemini_web_search=True),
    )
    assert "web_search" in {
        d["name"] for d in skills.session_tool_declarations()
    }
    assert skills._web_search_skills(), "voice composition lost the tool"

    monkeypatch.setattr(
        config,
        "CONFIG",
        dataclasses.replace(config.CONFIG, gemini_web_search=False),
    )
    assert "web_search" not in {
        d["name"] for d in skills.session_tool_declarations()
    }
    assert skills._web_search_skills() == []


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


# --- the Serper provider ---------------------------------------------------


def _stub_serper(monkeypatch, calls, results=None):
    def _call(query, *, api_key, engine_id, num):
        calls.append(query)
        return list(results if results is not None else [RESULT])

    monkeypatch.setitem(web_search._PROVIDERS, "serper", _call)


def test_serper_payload_parsing_and_request_shape(monkeypatch):
    payload = {
        "organic": [
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

    def _urlopen(req, timeout=None):
        seen["req"] = req
        return _Resp()

    monkeypatch.setattr(web_search.urllib.request, "urlopen", _urlopen)
    got = web_search._serper_search(
        "dana reis", api_key="K", engine_id="", num=5
    )
    assert [r.url for r in got] == ["https://a.example", "https://c.example"]
    req = seen["req"]
    assert req.full_url == "https://google.serper.dev/search"
    assert req.get_method() == "POST"
    assert req.get_header("X-api-key") == "K"
    assert json.loads(req.data) == {"q": "dana reis", "num": 5}


def test_serper_missing_organic_is_empty_not_an_error(monkeypatch):
    class _Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b"{}"

    monkeypatch.setattr(
        web_search.urllib.request, "urlopen", lambda req, timeout=None: _Resp()
    )
    assert (
        web_search._serper_search("x", api_key="K", engine_id="", num=5) == []
    )


def test_serper_http_error_carries_its_code(monkeypatch):
    def _urlopen(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 429, "quota", {}, None)

    monkeypatch.setattr(web_search.urllib.request, "urlopen", _urlopen)
    with pytest.raises(web_search._ProviderError) as excinfo:
        web_search._serper_search("x", api_key="K", engine_id="", num=5)
    assert excinfo.value.code == 429


def test_serper_search_ok_and_empty_results(monkeypatch):
    _settings(monkeypatch, key="serper-key", engine="", provider="serper")
    db = _Db()
    calls = []
    _stub_serper(monkeypatch, calls, results=[])
    outcome = _run(web_search.search("nothing", db=db, now=NOW))
    assert outcome.status == web_search.STATUS_OK
    assert outcome.results == []
    assert calls == ["nothing"]


def test_serper_cap_reached_pauses_before_any_call(monkeypatch):
    _settings(monkeypatch, key="serper-key", engine="", cap=1, provider="serper")
    db = _Db()
    calls = []
    _stub_serper(monkeypatch, calls)
    first = _run(web_search.search("one", db=db, now=NOW))
    second = _run(web_search.search("two", db=db, now=NOW))
    assert first.status == web_search.STATUS_OK
    assert second.status == web_search.STATUS_PAUSED
    assert calls == ["one"]  # the capped call never reached Serper


def test_serper_without_its_key_is_unconfigured_and_never_falls_back(monkeypatch):
    # The image-search key belongs to the Google CSE account; Serper must
    # not be handed it when WEB_SEARCH_API_KEY is unset.
    _settings(monkeypatch, key="", engine="", provider="serper")
    db = _Db()
    calls = []
    _stub_serper(monkeypatch, calls)
    outcome = _run(web_search.search("anything", db=db, now=NOW))
    assert outcome.status == web_search.STATUS_UNCONFIGURED
    assert calls == []
    assert db.docs == {}
