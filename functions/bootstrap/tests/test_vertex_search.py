"""vertex_search.py + its use as a second source in deep_dive_public_profiles.
The Discovery Engine call and Firestore are faked — no network."""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone
from types import SimpleNamespace

import deep_dive_public_profiles as pp
import gemini
import vertex_search

PAYLOAD = {
    "results": [
        {"document": {"derivedStructData": {
            "link": "https://github.com/dana-reyes",
            "title": "Dana Reyes (dana-reyes) - GitHub",
            "snippets": [{"snippet": "Dana Reyes has 4 repositories."}],
            "pagemap": {"metatags": [{"og:image": "https://avatars.example/dana.png"}]},
        }}},
        {"document": {"derivedStructData": {
            "link": "https://github.com/someone-else",
            "title": "Someone Else - GitHub",
        }}},
        {"document": {"derivedStructData": {
            "link": "https://dana-reyes.github.io/",
            "title": "Dana Reyes - portfolio",
            "pagemap": {"cse_image": [{"src": "https://dana.github.io/me.jpg"}]},
        }}},
        {"document": {"derivedStructData": {"link": "ftp://nope", "title": "Dana Reyes"}}},
    ]
}


def _run(coro):
    return asyncio.run(coro)


def test_parse_results_requires_every_name_token_and_extracts_the_indexed_image():
    got = vertex_search.parse_results(PAYLOAD, "Dana Reyes")
    assert got == [
        {"url": "https://github.com/dana-reyes", "image": "https://avatars.example/dana.png"},
        {"url": "https://dana-reyes.github.io/", "image": "https://dana.github.io/me.jpg"},
    ]


def test_flag_off_makes_no_call(monkeypatch):
    monkeypatch.setattr(
        vertex_search, "_search_sync",
        lambda *a: (_ for _ in ()).throw(AssertionError("called")),
    )
    assert _run(vertex_search.search_profiles("Dana Reyes")) == []


def test_daily_cap_blocks_queries_and_counts_per_utc_day(monkeypatch):
    monkeypatch.setenv("FLAG_VERTEX_AI_SEARCH_DAILY_CAP", "2")
    counts: dict[str, int] = {}

    class _Ref:
        def __init__(self, day):
            self.day = day

        def set(self, data, merge=False):
            assert merge and "count" in data  # a firestore.Increment sentinel
            counts[self.day] = counts.get(self.day, 0) + 1

        def get(self):
            return SimpleNamespace(to_dict=lambda: {"count": counts[self.day]})

    class _Db:
        def collection(self, name):
            assert name == vertex_search.USAGE_COLLECTION
            return SimpleNamespace(document=_Ref)

    import db as db_mod

    monkeypatch.setattr(db_mod, "get_db", lambda: _Db())
    assert [vertex_search._reserve_query() for _ in range(4)] == [True, True, False, False]
    assert list(counts) == [datetime.now(timezone.utc).strftime("%Y-%m-%d")]


def test_zero_cap_disables_without_touching_firestore(monkeypatch):
    monkeypatch.setenv("FLAG_VERTEX_AI_SEARCH_DAILY_CAP", "0")
    assert vertex_search._reserve_query() is False


def test_search_failure_returns_empty(monkeypatch):
    monkeypatch.setenv("FLAG_VERTEX_AI_SEARCH", "true")

    def boom(*a):
        raise RuntimeError("403")

    monkeypatch.setattr(vertex_search, "_search_sync", boom)
    assert _run(vertex_search.search_profiles("Dana Reyes")) == []


def test_deep_dive_merges_vertex_results_with_grounded_ones(monkeypatch):
    monkeypatch.setenv("FLAG_DEEPDIVE_PUBLIC_PROFILES", "true")
    pp._cache.clear()

    async def research(*a, **k):
        return '{"profiles":[{"platform":"linkedin","url":"https://www.linkedin.com/in/dana"}]}', []

    async def search(name, extra_terms=""):
        return vertex_search.parse_results(PAYLOAD, name)

    monkeypatch.setattr(gemini, "research", research)
    monkeypatch.setattr(vertex_search, "search_profiles", search)
    fetched = []
    monkeypatch.setattr(
        pp, "profile_image", lambda p: fetched.append(p["url"]) or "https://img/li.png"
    )
    out = _run(pp.find_public_profile_images("Dana Reyes"))
    by_platform = {c["platform"]: c for c in out}
    # grounded linkedin page is fetched; the indexed github / personal-site
    # images come straight from the search index with no page fetch.
    assert fetched == ["https://www.linkedin.com/in/dana"]
    assert by_platform["github"]["url"] == "https://avatars.example/dana.png"
    assert by_platform["personal_site"]["source_page"] == "https://dana-reyes.github.io/"
    assert set(by_platform) == {"linkedin", "github", "personal_site"}


def test_deep_dive_works_with_vertex_only_when_grounded_call_fails(monkeypatch):
    monkeypatch.setenv("FLAG_DEEPDIVE_PUBLIC_PROFILES", "true")
    pp._cache.clear()

    async def research(*a, **k):
        raise RuntimeError("down")

    async def search(name, extra_terms=""):
        return vertex_search.parse_results(PAYLOAD, name)

    monkeypatch.setattr(gemini, "research", research)
    monkeypatch.setattr(vertex_search, "search_profiles", search)
    monkeypatch.setattr(pp, "profile_image", lambda p: "")
    out = _run(pp.find_public_profile_images("Dana Reyes"))
    assert {c["platform"] for c in out} == {"github", "personal_site"}


def test_deep_dive_failure_of_both_sources_is_not_cached(monkeypatch):
    monkeypatch.setenv("FLAG_DEEPDIVE_PUBLIC_PROFILES", "true")
    pp._cache.clear()

    async def research(*a, **k):
        raise RuntimeError("down")

    async def search(name, extra_terms=""):
        return []

    monkeypatch.setattr(gemini, "research", research)
    monkeypatch.setattr(vertex_search, "search_profiles", search)
    assert _run(pp.find_public_profile_images("Dana Reyes")) == []
    assert pp._cache == {}
