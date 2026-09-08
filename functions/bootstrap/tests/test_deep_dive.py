import asyncio

import deep_dive
import gemini
import pytest
import token_ledger
from skills import make_session_tool_fns, session_tool_declarations


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


_DIGEST = {
    "summary": "Dana is a marine biologist in Lisbon.",
    "confidence": "high",
    "facts": [
        {"claim": "Works at the Lisbon Oceanarium", "category": "work",
         "source_url": "https://oceanario.pt/team", "confidence": "high"},
        {"claim": "Gave a TEDx talk in 2023", "category": "press",
         "source_url": "https://ted.com/x", "confidence": "medium"},
    ],
    "links": [
        {"url": "https://oceanario.pt/team", "title": "Team — Oceanário",
         "is_them": "likely", "note": ""},
    ],
    "caveats": "Two people share the name; picked the Lisbon one.",
}


@pytest.fixture
def _patch(monkeypatch):
    async def _research(prompt, system_prompt=None, **kw):
        assert "Dana" in prompt
        return ("web notes about Dana…", [{"url": "https://oceanario.pt/team",
                                           "title": "Team"}])

    async def _json(contents, system_prompt, response_schema=None, **kw):
        assert "RESEARCH NOTES" in contents
        return _DIGEST

    monkeypatch.setattr(gemini, "research", _research)
    monkeypatch.setattr(gemini, "generate_json", _json)


def test_run_returns_a_structured_digest(_patch):
    d = _run(deep_dive.run("Dana Reis", uid="u1", context="Lisbon"))
    assert d["name"] == "Dana Reis"
    assert d["is_self"] is False
    assert d["confidence"] == "high"
    assert [f["claim"] for f in d["facts"]][0].startswith("Works at")
    assert d["links"][0]["url"] == "https://oceanario.pt/team"


def test_run_requires_a_name(_patch):
    with pytest.raises(ValueError):
        _run(deep_dive.run("   ", uid="u1"))


# --- the ≤2-month reuse cache -------------------------------------------


class _CacheDoc:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def collection(self, _n):
        return self

    def document(self, name):
        return _CacheDoc(self.store, name)

    def get(self):
        data = self.store.get(self.key)

        class _S:
            exists = data is not None

            def to_dict(_self):
                return dict(data or {})

        return _S()

    def set(self, patch, merge=False):  # noqa: ARG002
        self.store[self.key] = {**self.store.get(self.key, {}), **patch}


class _CacheDb:
    """collection('users').document(uid).collection('deep_dives').document(key)
    all lands on one keyed store."""

    def __init__(self):
        self.store: dict = {}
        self._key = None

    def collection(self, _n):
        return self

    def document(self, name):
        self._key = name
        return _CacheDoc(self.store, name)


class _Ts:
    def __init__(self, secs):
        self._s = secs

    def timestamp(self):
        return self._s


def test_run_reuses_a_recent_dive_without_searching(_patch, monkeypatch):
    import time as _t

    calls = {"research": 0}
    real_research = gemini.research

    async def _counting_research(*a, **k):
        calls["research"] += 1
        return await real_research(*a, **k)

    monkeypatch.setattr(gemini, "research", _counting_research)

    db = _CacheDb()
    # First run: searches + stores.
    d1 = _run(deep_dive.run("Dana Reis", db=db, uid="u1", context="Lisbon"))
    assert calls["research"] == 1
    assert d1.get("from_cache") is not True
    # make the stored created_at look ~10 days old
    key = deep_dive._cache_key("", "Dana Reis")
    db.store[key]["created_at"] = _Ts(_t.time() - 10 * 86400)

    # Second run: served from cache, no new search.
    d2 = _run(deep_dive.run("Dana Reis", db=db, uid="u1", context="Lisbon"))
    assert calls["research"] == 1
    assert d2["from_cache"] is True
    assert [f["claim"] for f in d2["facts"]] == [f["claim"] for f in d1["facts"]]


def test_run_ignores_a_stale_cache_and_respects_force(_patch, monkeypatch):
    import time as _t

    calls = {"research": 0}
    real = gemini.research

    async def _counting(*a, **k):
        calls["research"] += 1
        return await real(*a, **k)

    monkeypatch.setattr(gemini, "research", _counting)

    db = _CacheDb()
    _run(deep_dive.run("Dana Reis", db=db, uid="u1"))
    key = deep_dive._cache_key("", "Dana Reis")

    # 70 days old -> past the 60-day window -> re-search.
    db.store[key]["created_at"] = _Ts(_t.time() - 70 * 86400)
    _run(deep_dive.run("Dana Reis", db=db, uid="u1"))
    assert calls["research"] == 2

    # Fresh again, but force=True still re-searches.
    db.store[key]["created_at"] = _Ts(_t.time() - 1 * 86400)
    _run(deep_dive.run("Dana Reis", db=db, uid="u1", force=True))
    assert calls["research"] == 3


def test_render_flags_a_reused_dive():
    text = deep_dive.render(
        {**_DIGEST, "name": "Dana", "from_cache": True, "cached_age_days": 12}
    )
    assert "Reusing the search" in text
    assert "about 12 days ago" in text


def test_render_lists_facts_links_and_a_confirm_prompt():
    text = deep_dive.render({**_DIGEST, "name": "Dana", "is_self": True})
    assert "marine biologist" in text
    assert "- Works at the Lisbon Oceanarium" in text
    assert "oceanario.pt/team" in text
    assert "Which of these are right" in text


def test_render_handles_a_thin_result():
    text = deep_dive.render(
        {"name": "Nobody Atall", "confidence": "not_found", "facts": [],
         "links": [], "summary": "", "is_self": False}
    )
    assert "didn't find much" in text


def test_skill_is_registered_async_and_runs_the_engine(monkeypatch):
    assert any(
        d["name"] == "deep_dive" for d in session_tool_declarations()
    )

    seen = {}

    async def _fake_run(name, *, uid, context, is_self, db=None, target_uid="", force=False):
        seen.update(name=name, uid=uid, is_self=is_self)
        return {**_DIGEST, "name": name, "is_self": is_self}

    monkeypatch.setattr(deep_dive, "run", _fake_run)

    fn = make_session_tool_fns(object(), "u9")["deep_dive"]
    out = _run(fn(full_name="Dana Reis", subject="self", context="Lisbon"))

    assert seen == {"name": "Dana Reis", "uid": "u9", "is_self": True}
    assert "marine biologist" in out


def test_skill_reports_when_out_of_credits(monkeypatch):
    async def _capped(*a, **k):
        raise token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(deep_dive, "run", _capped)
    fn = make_session_tool_fns(object(), "u9")["deep_dive"]
    out = _run(fn(full_name="X Y", subject="other"))
    assert "out of credits" in out


# --- POST /deep-dive -------------------------------------------------------

from fastapi.testclient import TestClient  # noqa: E402
from firebase_admin import auth as firebase_auth  # noqa: E402

import main  # noqa: E402

_client = TestClient(main.app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "me"}
    )
    return {"Authorization": "Bearer valid"}


def test_endpoint_runs_the_dive_and_drops_the_summary_into_chat(monkeypatch):
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "Suhail Pallath")

    async def _fake_run(name, *, uid, context, is_self, db=None, target_uid="", force=False):
        assert name == "Suhail Pallath" and is_self is True
        return {**_DIGEST, "name": name, "is_self": True}

    monkeypatch.setattr(main.deep_dive, "run", _fake_run)
    appended = []
    monkeypatch.setattr(
        main.chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append((role, text)),
    )

    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    body = r.json()
    assert body["is_self"] is True
    assert body["digest"]["confidence"] == "high"
    assert appended and appended[0][0] == "ayma"


def test_endpoint_400_when_there_is_no_name(monkeypatch):
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "")
    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 400
