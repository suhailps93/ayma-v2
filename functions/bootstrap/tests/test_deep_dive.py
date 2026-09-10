import asyncio

import deep_dive
import deep_dive_images
import deep_dive_social
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
    # The image + social steps make their own HTTP calls — neutralise them for
    # the plain `run()` tests. Dedicated tests below exercise the real wiring
    # with the network mocked one layer down.
    monkeypatch.setattr(
        deep_dive_images, "find_web_images", lambda *a, **k: []
    )
    monkeypatch.setattr(
        deep_dive_social, "find_social_handles", lambda *a, **k: []
    )


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


def test_run_wires_links_into_images_and_carries_social(monkeypatch):
    async def _research(prompt, system_prompt=None, **kw):
        return ("notes", [{"url": "https://oceanario.pt/team", "title": "T"}])

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return _DIGEST

    monkeypatch.setattr(gemini, "research", _research)
    monkeypatch.setattr(gemini, "generate_json", _json)

    seen = {}

    def _imgs(db, target_uid, name, *, extra_terms="", links=None, **kw):
        seen["links"] = links
        return [{"url": "https://oceanario.pt/og.jpg",
                 "source_page": "https://oceanario.pt/team",
                 "similarity": None, "verified": False}]

    def _social(digest_links, facts, name, **kw):
        seen["social_name"] = name
        return [{"platform": "instagram", "handle": "dana.reis",
                 "url": "https://www.instagram.com/dana.reis/",
                 "display_name": "Dana Reis", "confidence": "high",
                 "verified_by": ["face", "name"]}]

    monkeypatch.setattr(deep_dive_images, "find_web_images", _imgs)
    monkeypatch.setattr(deep_dive_social, "find_social_handles", _social)

    db = _CacheDb()
    d = _run(deep_dive.run("Dana Reis", db=db, uid="u1", context="Lisbon"))

    # links from the digest are handed to the image step (the no-CSE fallback).
    assert seen["links"] and seen["links"][0]["url"] == "https://oceanario.pt/team"
    assert seen["social_name"] == "Dana Reis"
    assert d["web_images"][0]["source_page"] == "https://oceanario.pt/team"
    assert d["social_handles"][0]["handle"] == "dana.reis"

    # …and both are persisted in the stored digest.
    stored = db.store[deep_dive._cache_key("", "Dana Reis")]["digest"]
    assert stored["web_images"] and stored["social_handles"]


def test_run_always_has_a_social_handles_key(_patch):
    d = _run(deep_dive.run("Dana Reis", uid="u1"))
    assert d["social_handles"] == []


def test_render_lists_confident_social_profiles():
    text = deep_dive.render({
        **_DIGEST, "name": "Dana", "is_self": False,
        "social_handles": [
            {"platform": "instagram", "handle": "dana.reis",
             "url": "https://www.instagram.com/dana.reis/",
             "display_name": "Dana Reis", "confidence": "high",
             "verified_by": ["face"]},
        ],
    })
    assert "Profiles I'm fairly sure are them:" in text
    assert "instagram.com/dana.reis" in text
    assert "(verified)" in text


def test_render_omits_social_block_when_empty():
    text = deep_dive.render({**_DIGEST, "name": "Dana", "social_handles": []})
    assert "Profiles I'm fairly sure" not in text


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


def test_endpoint_queues_a_fresh_dive_and_the_job_drops_it_into_chat(monkeypatch):
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "Suhail Pallath")
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(main.deep_dive, "cached_dive", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "save_web_findings", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "promote", lambda *a, **k: None)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")

    async def _fake_run(name, *, uid, context, is_self, db=None, target_uid="",
                        force=False):
        assert name == "Suhail Pallath" and is_self is True
        return {**_DIGEST, "name": name, "is_self": True}

    async def _no_notify(*a, **k):
        return None

    monkeypatch.setattr(main.deep_dive, "run", _fake_run)
    monkeypatch.setattr(
        main.notifications_triggers, "notify_skill_done", _no_notify
    )
    appended = []
    monkeypatch.setattr(
        main.chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append((role, text)),
    )

    # TestClient runs background tasks synchronously after the response.
    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    body = r.json()
    assert body["queued"] is True
    assert body["is_self"] is True
    assert body["tool_label"] == "Researched yourself online"
    assert appended and appended[0][0] == "ayma"


def test_endpoint_returns_a_cached_dive_inline(monkeypatch):
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "Suhail Pallath")
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(
        main.deep_dive, "cached_dive",
        lambda *a, **k: {**_DIGEST, "name": "Suhail Pallath", "from_cache": True},
    )
    monkeypatch.setattr(main.skill_memory, "save_web_findings", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "promote", lambda *a, **k: None)
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    body = r.json()
    assert body.get("queued") is not True
    assert body["digest"]["confidence"] == "high"


def test_endpoint_400_when_there_is_no_name(monkeypatch):
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "")
    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 400


def test_cached_dive_response_carries_a_report_id_and_chat_marker(monkeypatch):
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "Suhail Pallath")
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(
        main.deep_dive, "cached_dive",
        lambda *a, **k: {**_DIGEST, "name": "Suhail Pallath", "from_cache": True},
    )
    monkeypatch.setattr(main.skill_memory, "save_web_findings", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "promote", lambda *a, **k: None)
    appended = []
    monkeypatch.setattr(
        main.chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append(text),
    )

    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    body = r.json()
    # Same id the dive is cached under (a self dive keys by name slug).
    assert body["report_id"] == "name_suhail-pallath"
    assert appended and appended[0].endswith("[deep_dive:name_suhail-pallath]")
    # The inline `summary` stays clean — the client parses the marker from the
    # stored chat text, not from here.
    assert "[deep_dive:" not in body["summary"]


def test_non_self_dive_drops_an_interactions_breadcrumb_not_wiki(monkeypatch):
    """Research on someone else must not touch the user's wiki (no
    save_web_findings / promote); it leaves one `interactions` breadcrumb the
    next ingest folds in."""
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.story, "_photo_url_safe", lambda _p: "")
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    def _boom(*a, **k):  # wiki writes are self-only
        raise AssertionError("wiki must not be written for a non-self dive")

    monkeypatch.setattr(main.skill_memory, "save_web_findings", _boom)
    monkeypatch.setattr(main.skill_memory, "promote", _boom)

    notes = []
    monkeypatch.setattr(
        main.skill_memory, "note_interaction",
        lambda _db, uid, text, **kw: notes.append((uid, text)),
    )

    out = _run(
        main._finish_deep_dive(
            "me", {**_DIGEST, "name": "Jordan"},
            is_self=False, target="other", name="Jordan", notify=False,
        )
    )
    assert out["is_self"] is False
    assert notes == [("me", "ran a deep dive on Jordan")]


def test_self_dive_writes_wiki_and_no_breadcrumb(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.story, "_photo_url_safe", lambda _p: "")
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_runs, "record", lambda *a, **k: None)

    calls = []
    monkeypatch.setattr(
        main.skill_memory, "save_web_findings",
        lambda *a, **k: calls.append("save"),
    )
    monkeypatch.setattr(
        main.skill_memory, "promote", lambda *a, **k: calls.append("promote"),
    )
    monkeypatch.setattr(
        main.skill_memory, "note_interaction",
        lambda *a, **k: calls.append("note"),
    )

    _run(
        main._finish_deep_dive(
            "me", {**_DIGEST, "name": "Me"},
            is_self=True, target="", name="Me", notify=False,
        )
    )
    assert calls == ["save", "promote"]  # no interactions breadcrumb


def test_deep_dive_report_endpoint_reads_and_404s(monkeypatch):
    stored = {
        "digest": {**_DIGEST, "name": "Dana Reyes"},
        "name": "Dana Reyes",
        "target_uid": "other",
        "created_at": None,
    }
    monkeypatch.setattr(
        main.deep_dive, "read_dive",
        lambda _db, uid, rid: stored if rid == "uid_other" else None,
    )
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.story, "_photo_url_safe", lambda _p: "")

    ok = _client.get("/deep-dive-report/uid_other", headers=_auth(monkeypatch))
    assert ok.status_code == 200
    body = ok.json()
    assert body["name"] == "Dana Reyes"
    assert body["digest"]["confidence"] == "high"
    assert body["is_self"] is False

    miss = _client.get("/deep-dive-report/uid_ghost", headers=_auth(monkeypatch))
    assert miss.status_code == 404
