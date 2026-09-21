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


async def _no_web_images(*a, **k):
    return []


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
        deep_dive_images, "find_web_images", _no_web_images
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


def test_self_run_hands_a_known_linkedin_url_to_research(monkeypatch):
    """§ Your Story career timeline: when the user has given Ayma their own
    LinkedIn URL, a self dive appends it to the research prompt so Gemini's
    already-attached `url_context` tool can read that page directly — never a
    scraper, never an unofficial API call."""
    import career_timeline

    seen = {}

    async def _research(prompt, system_prompt=None, **kw):
        seen["prompt"] = prompt
        return ("notes", [])

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return {"summary": "", "confidence": "not_found", "facts": [], "links": []}

    monkeypatch.setattr(gemini, "research", _research)
    monkeypatch.setattr(gemini, "generate_json", _json)
    monkeypatch.setattr(
        career_timeline, "get_linkedin_url",
        lambda db, uid: "https://www.linkedin.com/in/dana-reis/",
    )
    monkeypatch.setattr(deep_dive_images, "find_web_images", _no_web_images)
    monkeypatch.setattr(deep_dive_social, "find_social_handles", lambda *a, **k: [])

    _run(deep_dive.run(
        "Dana Reis", db=object(), uid="u1", is_self=True,
    ))
    assert "https://www.linkedin.com/in/dana-reis/" in seen["prompt"]


def test_self_run_without_a_linkedin_url_never_mentions_one(monkeypatch):
    import career_timeline

    seen = {}

    async def _research(prompt, system_prompt=None, **kw):
        seen["prompt"] = prompt
        return ("notes", [])

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return {"summary": "", "confidence": "not_found", "facts": [], "links": []}

    monkeypatch.setattr(gemini, "research", _research)
    monkeypatch.setattr(gemini, "generate_json", _json)
    monkeypatch.setattr(career_timeline, "get_linkedin_url", lambda db, uid: "")
    monkeypatch.setattr(deep_dive_images, "find_web_images", _no_web_images)
    monkeypatch.setattr(deep_dive_social, "find_social_handles", lambda *a, **k: [])

    _run(deep_dive.run("Dana Reis", db=object(), uid="u1", is_self=True))
    assert "linkedin" not in seen["prompt"].lower()


def test_run_wires_links_into_images_and_carries_social(monkeypatch):
    async def _research(prompt, system_prompt=None, **kw):
        return ("notes", [{"url": "https://oceanario.pt/team", "title": "T"}])

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return _DIGEST

    monkeypatch.setattr(gemini, "research", _research)
    monkeypatch.setattr(gemini, "generate_json", _json)

    seen = {}

    async def _imgs(db, target_uid, name, *, extra_terms="", links=None, **kw):
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


def test_run_never_reuses_the_cache_for_a_self_dive(_patch, monkeypatch):
    # Someone researching *themselves* always gets a fresh search, even with
    # a same-day cache entry sitting right there — only a dive on someone
    # else (or reopening the saved report) may read the cache.
    import time as _t

    calls = {"research": 0}
    real_research = gemini.research

    async def _counting_research(*a, **k):
        calls["research"] += 1
        return await real_research(*a, **k)

    monkeypatch.setattr(gemini, "research", _counting_research)

    db = _CacheDb()
    key = deep_dive._cache_key("", "Dana Reis")

    d1 = _run(deep_dive.run("Dana Reis", db=db, uid="u1", is_self=True))
    assert calls["research"] == 1
    assert d1.get("from_cache") is not True
    # A same-day cache entry (the fake db's SERVER_TIMESTAMP write needs a
    # real one for the age check — same trick as the other cache tests).
    db.store[key]["created_at"] = _Ts(_t.time() - 1 * 86400)

    # Same-day cache, but is_self=True -> re-searches anyway.
    d2 = _run(deep_dive.run("Dana Reis", db=db, uid="u1", is_self=True))
    assert calls["research"] == 2
    assert d2.get("from_cache") is not True
    db.store[key]["created_at"] = _Ts(_t.time() - 1 * 86400)

    # The fresh self dive still overwrites the same cache doc, so a later
    # lookup on this person by someone else reuses the newest copy.
    d3 = _run(deep_dive.run("Dana Reis", db=db, uid="u1"))
    assert calls["research"] == 2
    assert d3["from_cache"] is True


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


def test_endpoint_returns_a_cached_dive_inline_for_someone_else(monkeypatch):
    # Caching only ever short-circuits a dive on *someone else* — see
    # test_self_dive_never_uses_the_cache below for the self case.
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(
        main.deep_dive, "cached_dive",
        lambda *a, **k: {**_DIGEST, "name": "Dana Reyes", "from_cache": True},
    )
    monkeypatch.setattr(main.skill_memory, "note_interaction", lambda *a, **k: None)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    r = _client.post(
        "/deep-dive", headers=_auth(monkeypatch),
        json={"target_uid": "other", "name": "Dana Reyes"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body.get("queued") is not True
    assert body["digest"]["confidence"] == "high"


def test_self_dive_never_uses_the_cache(monkeypatch):
    # Researching yourself always runs fresh, even with a cached dive on hand
    # — only someone else looking *you* up (or reopening the saved report)
    # should ever see the cached copy.
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "Suhail Pallath")
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    calls = []
    monkeypatch.setattr(
        main.deep_dive, "cached_dive",
        lambda *a, **k: calls.append(1) or {
            **_DIGEST, "name": "Suhail Pallath", "from_cache": True,
        },
    )
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
    monkeypatch.setattr(main.notifications_triggers, "notify_skill_done", _no_notify)
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    # TestClient runs background tasks synchronously after the response.
    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    assert r.json().get("queued") is True
    assert not calls  # cached_dive is never even consulted for a self dive


def test_endpoint_400_when_there_is_no_name(monkeypatch):
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "")
    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 400


def test_cached_dive_response_carries_a_report_id_and_chat_marker(monkeypatch):
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(
        main.deep_dive, "cached_dive",
        lambda *a, **k: {**_DIGEST, "name": "Dana Reyes", "from_cache": True},
    )
    monkeypatch.setattr(main.skill_memory, "note_interaction", lambda *a, **k: None)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    appended = []
    monkeypatch.setattr(
        main.chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append(text),
    )

    r = _client.post(
        "/deep-dive", headers=_auth(monkeypatch),
        json={"target_uid": "other", "name": "Dana Reyes"},
    )
    assert r.status_code == 200
    body = r.json()
    # Same id the dive is cached under (an other-person dive keys by uid).
    assert body["report_id"] == "uid_other"
    assert appended and appended[0].endswith("[deep_dive:uid_other]")
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


def test_deep_dive_mine_resolves_by_name_never_by_uid(monkeypatch):
    monkeypatch.setattr(
        main.deep_dive, "profile_full_name", lambda _db, _uid: "Suhail Pallath"
    )
    expected_id = deep_dive.dive_report_id(name="Suhail Pallath")
    stored = {
        "digest": {**_DIGEST, "name": "Suhail Pallath"},
        "name": "Suhail Pallath",
        "target_uid": "",
        "created_at": None,
    }

    def _read_dive(_db, uid, rid):
        # Regression guard: the exact uid-vs-name bug already fixed once in
        # _ai_view_photos — a self dive must be looked up by the deterministic
        # name-keyed id, never by the caller's own uid.
        assert rid == expected_id
        assert rid != uid
        return stored

    monkeypatch.setattr(main.deep_dive, "read_dive", _read_dive)

    r = _client.get("/deep-dive/mine", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json() == {
        "exists": True,
        "report_id": expected_id,
        "summary": _DIGEST["summary"],
        "confidence": "high",
        "created_at": None,
    }


def test_deep_dive_mine_reports_nothing_yet(monkeypatch):
    monkeypatch.setattr(
        main.deep_dive, "profile_full_name", lambda _db, _uid: "Suhail Pallath"
    )
    monkeypatch.setattr(main.deep_dive, "read_dive", lambda *a, **k: None)
    r = _client.get("/deep-dive/mine", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json() == {"exists": False}

    # No name on the profile at all — never even resolves an id.
    monkeypatch.setattr(main.deep_dive, "profile_full_name", lambda *a, **k: "")
    r2 = _client.get("/deep-dive/mine", headers=_auth(monkeypatch))
    assert r2.status_code == 200
    assert r2.json() == {"exists": False}


# --- Part 1: wiki-derived disambiguation context ---------------------------


class _FakeSnap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data
        self.exists = data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _FakeDoc:
    def __init__(self, db, path):
        self._db, self._path = db, path

    def collection(self, name):
        return _FakeCollection(self._db, self._path + (name,))

    def get(self):
        return _FakeSnap(self._path[-1], self._db.data.get(self._path))

    def set(self, patch, merge=False):
        cur = dict(self._db.data.get(self._path) or {}) if merge else {}
        cur.update(patch)
        self._db.data[self._path] = cur


class _FakeCollection:
    def __init__(self, db, path):
        self._db, self._path = db, path

    def document(self, doc_id):
        return _FakeDoc(self._db, self._path + (doc_id,))

    def stream(self):
        prefix = self._path
        return iter(
            _FakeSnap(path[-1], data)
            for path, data in self._db.data.items()
            if len(path) == len(prefix) + 1 and path[:-1] == prefix
        )


class _FakeDb:
    """A generic multi-collection fake Firestore — every doc keyed by its full
    path tuple, so unlike ``_CacheDb`` above this supports profile + wiki_pages
    + deep_dives all on one instance."""

    def __init__(self):
        self.data: dict[tuple, dict] = {}

    def collection(self, name):
        return _FakeCollection(self, (name,))

    def seed(self, path: tuple, data: dict) -> None:
        self.data[path] = data


def test_wiki_dive_context_pulls_one_line_per_relevant_page():
    db = _FakeDb()
    db.seed(
        ("users", "u1", "wiki_pages", "career"),
        {"page_type": "career", "ai_body": "Works as a robotics engineer at "
         "Acme. Has been there five years and loves the team."},
    )
    db.seed(
        ("users", "u1", "wiki_pages", "identity"),
        {"page_type": "identity", "ai_body": "Lives in Austin, Texas."},
    )
    db.seed(
        ("users", "u1", "wiki_pages", "interests"),
        {"page_type": "interests", "ai_body": "Big into bouldering and "
         "vinyl records."},
    )
    # A page type not in the disambiguation list must not leak in.
    db.seed(
        ("users", "u1", "wiki_pages", "sensitive"),
        {"page_type": "sensitive", "ai_body": "Manages chronic back pain."},
    )
    out = deep_dive.wiki_dive_context(db, "u1")
    assert "robotics engineer at Acme" in out
    assert "Austin" in out
    assert "bouldering" in out
    assert "back pain" not in out
    # only the first sentence of each page, not the full body
    assert "five years" not in out


def test_wiki_dive_context_stays_within_its_cap():
    db = _FakeDb()
    for pt in ("identity", "career", "interests"):
        db.seed(
            ("users", "u1", "wiki_pages", pt),
            {"page_type": pt, "ai_body": ("x" * 500) + "."},
        )
    out = deep_dive.wiki_dive_context(db, "u1")
    assert len(out) <= deep_dive._MAX_WIKI_CONTEXT


def test_wiki_dive_context_empty_when_no_pages():
    assert deep_dive.wiki_dive_context(_FakeDb(), "u1") == ""
    assert deep_dive.wiki_dive_context(_FakeDb(), "") == ""


def test_wiki_dive_context_read_failure_is_swallowed():
    class _Boom:
        def collection(self, *_):
            raise RuntimeError("firestore down")

    assert deep_dive.wiki_dive_context(_Boom(), "u1") == ""


def test_profile_dive_context_combines_location_wiki_and_disputes():
    db = _FakeDb()
    db.seed(("users", "u1", "profile", "main"), {"location": "Austin, TX"})
    db.seed(
        ("users", "u1", "wiki_pages", "career"),
        {"page_type": "career", "ai_body": "Works as a robotics engineer."},
    )
    key = deep_dive._cache_key("", "Dana Reis")
    db.seed(
        ("users", "u1", "deep_dives", key),
        {
            "digest": {"facts": []},
            "target_uid": "",
            "disputed_facts": [
                {"claim": "Went to MIT", "category": "education"},
            ],
        },
    )
    out = deep_dive.profile_dive_context(db, "u1", "Dana Reis")
    assert "Location: Austin, TX." in out
    assert "robotics engineer" in out
    assert "Went to MIT" in out
    assert "WRONG" in out
    assert len(out) <= deep_dive._MAX_CONTEXT


def test_profile_dive_context_without_name_skips_disputed_lookup():
    db = _FakeDb()
    db.seed(("users", "u1", "profile", "main"), {"location": "Austin, TX"})
    out = deep_dive.profile_dive_context(db, "u1")
    assert out == "Location: Austin, TX."


def test_disputed_facts_context_empty_without_a_prior_report():
    assert deep_dive.disputed_facts_context(_FakeDb(), "u1", "Nobody") == ""


def test_prompt_frames_context_as_supplement_not_trusted_fact():
    from deep_dive import _DIGEST_SYSTEM, _RESEARCH_SYSTEM

    for text in (_RESEARCH_SYSTEM, _DIGEST_SYSTEM):
        low = text.lower()
        assert "supplement" in low or "disambiguat" in low
        assert "not trusted" in low or "never" in low
    assert "WRONG" not in _RESEARCH_SYSTEM  # sanity: no leaked runtime string
    assert "disputed" in _RESEARCH_SYSTEM.lower()
    assert "disputed" in _DIGEST_SYSTEM.lower()


# --- Part 2: mark-a-fact-incorrect ------------------------------------------


def test_run_assigns_stable_ids_to_facts(_patch):
    d1 = _run(deep_dive.run("Dana Reis", uid="u1"))
    d2 = _run(deep_dive.run("Dana Reis", uid="u1"))
    ids1 = [f["id"] for f in d1["facts"]]
    ids2 = [f["id"] for f in d2["facts"]]
    assert ids1 and all(ids1)
    assert ids1 == ids2  # same claim/category -> same id, run after run
    assert len(set(ids1)) == len(ids1)  # distinct facts -> distinct ids


def _seed_self_report(db, uid, name, facts):
    key = deep_dive._cache_key("", name)
    db.seed(
        ("users", uid, "deep_dives", key),
        {
            "digest": {"name": name, "facts": facts},
            "target_uid": "",
            "name": name,
        },
    )
    return key


def test_dispute_fact_removes_it_and_persists_the_correction():
    db = _FakeDb()
    facts = [
        {"id": "aaa111", "claim": "Went to MIT", "category": "education"},
        {"id": "bbb222", "claim": "Works at Acme", "category": "work"},
    ]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)

    result = deep_dive.dispute_fact(db, "u1", key, "aaa111")
    assert result is not None
    assert [f["id"] for f in result["digest"]["facts"]] == ["bbb222"]
    assert result["disputed_facts"][0]["claim"] == "Went to MIT"

    stored = db.data[("users", "u1", "deep_dives", key)]
    assert [f["id"] for f in stored["digest"]["facts"]] == ["bbb222"]
    assert stored["disputed_facts"][0]["category"] == "education"
    assert stored["disputed_facts"][0]["disputed_at"]


def test_dispute_fact_rejects_a_report_about_someone_else():
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "Went to MIT", "category": "education"}]
    key = "uid_other"
    db.seed(
        ("users", "u1", "deep_dives", key),
        {"digest": {"name": "Jordan", "facts": facts}, "target_uid": "other"},
    )
    with pytest.raises(PermissionError):
        deep_dive.dispute_fact(db, "u1", key, "aaa111")
    # nothing was mutated
    assert db.data[("users", "u1", "deep_dives", key)]["digest"]["facts"] == facts


def test_dispute_fact_404s_style_none_for_missing_report_or_fact():
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "Went to MIT", "category": "education"}]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)

    assert deep_dive.dispute_fact(db, "u1", "no-such-key", "aaa111") is None
    assert deep_dive.dispute_fact(db, "u1", key, "no-such-fact") is None


def test_dispute_fact_backfills_id_for_a_legacy_fact_without_one():
    db = _FakeDb()
    legacy_fact = {"claim": "Went to MIT", "category": "education"}
    fid = deep_dive.fact_id(legacy_fact)
    key = _seed_self_report(db, "u1", "Dana Reis", [legacy_fact])

    result = deep_dive.dispute_fact(db, "u1", key, fid)
    assert result is not None
    assert result["digest"]["facts"] == []


def test_disputed_fact_is_picked_up_by_the_next_run_context(_patch, monkeypatch):
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "Went to MIT", "category": "education"}]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)
    deep_dive.dispute_fact(db, "u1", key, "aaa111")

    seen_context = {}

    async def _research(prompt, system_prompt=None, **kw):
        seen_context["prompt"] = prompt
        return ("notes", [])

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return {"summary": "", "confidence": "not_found", "facts": [], "links": []}

    monkeypatch.setattr(gemini, "research", _research)
    monkeypatch.setattr(gemini, "generate_json", _json)

    context = deep_dive.profile_dive_context(db, "u1", "Dana Reis")
    _run(deep_dive.run("Dana Reis", db=db, uid="u1", context=context, is_self=True))
    assert "Went to MIT" in seen_context["prompt"]
    assert "WRONG" in seen_context["prompt"]


# --- POST /deep-dive/{report_id}/facts/{fact_id}/dispute --------------------


def test_dispute_endpoint_removes_the_fact(monkeypatch):
    updated_digest = {"name": "Me", "facts": []}
    monkeypatch.setattr(
        main.deep_dive, "dispute_fact",
        lambda *a, **k: {"report_id": "r1", "digest": updated_digest,
                          "disputed_facts": []},
    )
    r = _client.post(
        "/deep-dive/r1/facts/aaa111/dispute", headers=_auth(monkeypatch),
    )
    assert r.status_code == 200
    assert r.json() == {"ok": True, "digest": updated_digest}


def test_dispute_endpoint_404s_when_not_found(monkeypatch):
    monkeypatch.setattr(main.deep_dive, "dispute_fact", lambda *a, **k: None)
    r = _client.post(
        "/deep-dive/r1/facts/ghost/dispute", headers=_auth(monkeypatch),
    )
    assert r.status_code == 404


def test_dispute_endpoint_403s_for_someone_elses_report(monkeypatch):
    def _boom(*a, **k):
        raise PermissionError("nope")

    monkeypatch.setattr(main.deep_dive, "dispute_fact", _boom)
    r = _client.post(
        "/deep-dive/uid_other/facts/aaa111/dispute", headers=_auth(monkeypatch),
    )
    assert r.status_code == 403


# --- free-text corrections (tap-a-claim, in-your-own-words) -----------------


def test_correct_summary_revise(monkeypatch):
    db = _FakeDb()
    key = _seed_self_report(db, "u1", "Dana Reis", [])
    db.data[("users", "u1", "deep_dives", key)]["digest"]["summary"] = "Marine biologist."

    async def _json(contents, system_prompt, response_schema=None, **kw):
        assert "Marine biologist" in contents
        return {"action": "revise", "revised_text": "Marine biologist in Lisbon.",
                "reply": "Updated that for you."}

    monkeypatch.setattr(gemini, "generate_json", _json)
    result = _run(deep_dive.correct(db, "u1", key, "summary", "I moved to Lisbon"))
    assert result["action"] == "revise"
    assert result["reply"] == "Updated that for you."
    assert result["digest"]["summary"] == "Marine biologist in Lisbon."
    stored = db.data[("users", "u1", "deep_dives", key)]
    assert stored["digest"]["summary"] == "Marine biologist in Lisbon."


def test_correct_fact_remove_drops_it_and_records_the_dispute(monkeypatch):
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "Went to MIT", "category": "education"}]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return {"action": "remove", "revised_text": "", "reply": "Removed that."}

    monkeypatch.setattr(gemini, "generate_json", _json)
    result = _run(deep_dive.correct(db, "u1", key, "fact:aaa111", "that's wrong"))
    assert result["action"] == "remove"
    assert result["digest"]["facts"] == []
    stored = db.data[("users", "u1", "deep_dives", key)]
    assert stored["disputed_facts"][0]["claim"] == "Went to MIT"


def test_correct_fact_revise_updates_the_claim_keeping_its_id(monkeypatch):
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "Went to MIT", "category": "education"}]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return {"action": "revise", "revised_text": "Went to MIT Sloan",
                "reply": "Fixed it."}

    monkeypatch.setattr(gemini, "generate_json", _json)
    result = _run(deep_dive.correct(db, "u1", key, "fact:aaa111", "it was Sloan"))
    assert result["digest"]["facts"] == [
        {"id": "aaa111", "claim": "Went to MIT Sloan", "category": "education"}
    ]


def test_correct_keep_leaves_everything_unchanged(monkeypatch):
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "Went to MIT", "category": "education"}]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return {"action": "keep", "revised_text": "Went to MIT", "reply": "Got it."}

    monkeypatch.setattr(gemini, "generate_json", _json)
    result = _run(deep_dive.correct(db, "u1", key, "fact:aaa111", "why do you say that?"))
    assert result["action"] == "keep"
    assert result["digest"]["facts"] == facts


def test_correct_rejects_a_report_about_someone_else(monkeypatch):
    db = _FakeDb()
    key = "uid_other"
    db.seed(
        ("users", "u1", "deep_dives", key),
        {"digest": {"name": "Jordan", "summary": "x", "facts": []},
         "target_uid": "other"},
    )
    with pytest.raises(PermissionError):
        _run(deep_dive.correct(db, "u1", key, "summary", "wrong"))


def test_correct_unknown_target_raises_value_error(monkeypatch):
    db = _FakeDb()
    key = _seed_self_report(db, "u1", "Dana Reis", [])
    with pytest.raises(ValueError):
        _run(deep_dive.correct(db, "u1", key, "fact:ghost", "wrong"))
    with pytest.raises(ValueError):
        _run(deep_dive.correct(db, "u1", key, "bogus", "wrong"))


def test_correct_blank_feedback_raises_value_error():
    db = _FakeDb()
    key = _seed_self_report(db, "u1", "Dana Reis", [])
    with pytest.raises(ValueError):
        _run(deep_dive.correct(db, "u1", key, "summary", "   "))


def test_correct_missing_report_returns_none():
    db = _FakeDb()
    assert _run(deep_dive.correct(db, "u1", "no-such-key", "summary", "x")) is None


# --- POST /deep-dive/{report_id}/correct -------------------------------------


def test_correct_endpoint_returns_reply_and_digest(monkeypatch):
    async def _fake_correct(db, uid, report_id, target, feedback):
        return {"reply": "Updated.", "action": "revise", "digest": {"summary": "y"}}

    monkeypatch.setattr(main.deep_dive, "correct", _fake_correct)
    r = _client.post(
        "/deep-dive/r1/correct",
        json={"target": "summary", "feedback": "fix it"},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 200
    assert r.json() == {
        "ok": True, "reply": "Updated.", "action": "revise",
        "digest": {"summary": "y"},
    }


def test_correct_endpoint_422s_on_blank_feedback(monkeypatch):
    r = _client.post(
        "/deep-dive/r1/correct",
        json={"target": "summary", "feedback": "  "},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 422


def test_correct_endpoint_404s_when_not_found(monkeypatch):
    async def _none(*a, **k):
        return None

    monkeypatch.setattr(main.deep_dive, "correct", _none)
    r = _client.post(
        "/deep-dive/r1/correct",
        json={"target": "summary", "feedback": "fix it"},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 404


def test_correct_endpoint_403s_for_someone_elses_report(monkeypatch):
    async def _boom(*a, **k):
        raise PermissionError("nope")

    monkeypatch.setattr(main.deep_dive, "correct", _boom)
    r = _client.post(
        "/deep-dive/uid_other/correct",
        json={"target": "summary", "feedback": "fix it"},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 403


def test_correct_endpoint_reports_usage_capped(monkeypatch):
    async def _boom(*a, **k):
        raise main.token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(main.deep_dive, "correct", _boom)
    r = _client.post(
        "/deep-dive/r1/correct",
        json={"target": "summary", "feedback": "fix it"},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 200 and r.json() == {"usage_capped": True}
