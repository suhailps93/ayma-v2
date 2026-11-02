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


def test_run_trusts_source_index_over_a_mistyped_url(monkeypatch):
    """The digest pass retypes `source_url` / link `url` from a numbered
    SOURCE LINKS SEEN list it was shown. A model regenerating a long URL from
    memory can drift a character or swap in a *different* entry's URL while
    still getting the title right — exactly the "title is right, link opens
    the wrong site" bug. When the model also gives a `source_index`, that
    index must win over whatever string it retyped, since an index can only
    point at a URL that was actually seen."""
    sources = [
        {"url": "https://github.com/dana93/portfolio", "title": "GitHub — dana93"},
        {"url": "https://ted.com/x", "title": "TEDx talk"},
    ]

    async def _research(prompt, system_prompt=None, **kw):
        return ("web notes about Dana…", sources)

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return {
            "summary": "s", "confidence": "high",
            "facts": [
                {"claim": "Gave a TEDx talk", "category": "press",
                 "confidence": "medium",
                 # mistyped/scrambled url, but a correct source_index
                 "source_url": "https://ted.com/wrong-slug",
                 "source_index": 1},
            ],
            "links": [
                {"title": "GitHub Profile - dana93", "is_them": "likely",
                 "note": "",
                 # scrambled onto the TEDx url even though the title says
                 # GitHub — the index still points at the right entry
                 "url": "https://ted.com/x",
                 "source_index": 0},
            ],
        }

    monkeypatch.setattr(gemini, "research", _research)
    monkeypatch.setattr(gemini, "generate_json", _json)
    monkeypatch.setattr(deep_dive_images, "find_web_images", _no_web_images)
    monkeypatch.setattr(deep_dive_social, "find_social_handles", lambda *a, **k: [])

    d = _run(deep_dive.run("Dana Reis", uid="u1"))
    assert d["facts"][0]["source_url"] == "https://ted.com/x"
    assert d["links"][0]["url"] == "https://github.com/dana93/portfolio"
    assert d["links"][0]["title"] == "GitHub Profile - dana93"
    # the internal-only field never leaks into the stored/returned shape
    assert "source_index" not in d["facts"][0]
    assert "source_index" not in d["links"][0]


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


# --- one persistent report per SUBJECT, not per searcher -------------------
#
# A real Firestore path is `users/{owner}/deep_dives/{key}` — the owner
# matters. The simplified `_CacheDb` above collapses that (every uid lands on
# the same store), which is exactly how the original per-caller-cache bug hid
# from the old tests. This fake keeps owner and key separate so a test can
# tell "stored under the searcher" apart from "stored under the person being
# searched".


class _OwnerCacheDb:
    def __init__(self):
        self.store: dict[tuple[str, str], dict] = {}

    def collection(self, _n):
        return _OwnerTop(self.store)


class _OwnerTop:
    def __init__(self, store):
        self.store = store

    def document(self, owner):
        return _OwnerUserDoc(self.store, owner)


class _OwnerUserDoc:
    def __init__(self, store, owner):
        self.store, self.owner = store, owner

    def collection(self, _n):
        return self

    def document(self, key):
        return _OwnerDoc(self.store, self.owner, key)


class _OwnerDoc:
    def __init__(self, store, owner, key):
        self.store, self.owner, self.key = store, owner, key

    def get(self):
        data = self.store.get((self.owner, self.key))

        class _S:
            exists = data is not None

            def to_dict(_self):
                return dict(data or {})

        return _S()

    def set(self, patch, merge=False):  # noqa: ARG002
        k = (self.owner, self.key)
        self.store[k] = {**self.store.get(k, {}), **patch}


def test_report_owner_parses_a_known_app_user_id():
    assert deep_dive.report_owner("uid_b1", "a1") == "b1"


def test_report_owner_falls_back_to_requester_for_a_name_id():
    assert deep_dive.report_owner("name_dana-reis", "a1") == "a1"
    assert deep_dive.report_owner("", "a1") == "a1"


def test_subject_report_prefers_the_subjects_own_self_dive():
    db = _OwnerCacheDb()
    # B already ran (and corrected) their own self-dive.
    db.store[("b1", "name_dana-reis")] = {
        "digest": {**_DIGEST, "name": "Dana Reis", "summary": "corrected summary"},
        "name": "Dana Reis", "target_uid": "",
    }
    found = deep_dive.subject_report(db, "b1", "Dana Reis")
    assert found is not None
    assert found["mirror"] is True
    assert found["report_id"] == "uid_b1"
    assert found["digest"]["summary"] == "corrected summary"


def test_subject_report_falls_back_to_the_shared_cross_user_cache():
    import time as _t

    db = _OwnerCacheDb()
    db.store[("b1", "uid_b1")] = {
        "digest": {**_DIGEST, "name": "Dana Reis"},
        "name": "Dana Reis", "target_uid": "b1",
        "created_at": _Ts(_t.time() - 5 * 86400),
    }
    found = deep_dive.subject_report(db, "b1", "Dana Reis")
    assert found is not None
    assert found["mirror"] is False
    assert found["report_id"] == "uid_b1"


def test_subject_report_none_when_the_subject_has_no_report_at_all():
    db = _OwnerCacheDb()
    assert deep_dive.subject_report(db, "b1", "Dana Reis") is None


def test_run_reuses_the_subjects_own_self_dive_without_searching(monkeypatch):
    # A searches B, who already has a self-dive report (possibly corrected).
    # No Gemini call at all — B's own report is shared back to A as-is.
    calls = {"research": 0}

    async def _counting_research(*a, **k):
        calls["research"] += 1
        raise AssertionError("must not search — B already has a report")

    monkeypatch.setattr(gemini, "research", _counting_research)
    monkeypatch.setattr(
        deep_dive_images, "find_web_images", _no_web_images
    )
    monkeypatch.setattr(
        deep_dive_social, "find_social_handles", lambda *a, **k: []
    )

    db = _OwnerCacheDb()
    db.store[("b1", "name_dana-reis")] = {
        "digest": {**_DIGEST, "name": "Dana Reis",
                    "summary": "B's own corrected summary"},
        "name": "Dana Reis", "target_uid": "",
    }

    d = _run(deep_dive.run(
        "Dana Reis", db=db, uid="a1", target_uid="b1",
    ))
    assert calls["research"] == 0
    assert d["is_self"] is False
    assert d["summary"] == "B's own corrected summary"
    # Mirrored to the shared, self-describing "uid_b1" doc — still under B's
    # own collection, never A's — so the report_id A gets resolves for anyone.
    mirrored = db.store.get(("b1", "uid_b1"))
    assert mirrored is not None
    assert mirrored["digest"]["summary"] == "B's own corrected summary"
    assert ("a1", "uid_b1") not in db.store


def test_run_on_a_fresh_subject_becomes_their_own_persistent_report(_patch):
    # A searches B, who has no report yet. The search runs (as normal), and
    # the result is attributed to B — both the shared cross-user slot and
    # B's own self-dive slot — never a private artifact only A can see.
    db = _OwnerCacheDb()

    d = _run(deep_dive.run("Dana Reis", db=db, uid="a1", target_uid="b1"))
    assert d["is_self"] is False
    assert d["confidence"] == "high"

    assert ("b1", "uid_b1") in db.store
    assert ("b1", "name_dana-reis") in db.store
    assert ("a1", "uid_b1") not in db.store
    assert db.store[("b1", "name_dana-reis")]["digest"]["summary"] == d["summary"]


def test_endpoint_reusable_report_short_circuits_someone_elses_search(monkeypatch):
    """The `/deep-dive` endpoint's own inline-cache check (separate from
    `run()`'s) must use the same subject-first logic, so a repeat search on a
    person who already has a report comes back inline, no queued job."""
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    seen = {}

    def _fake_reusable(_db, _uid, *, target_uid, name, is_self):
        seen["target_uid"] = target_uid
        seen["is_self"] = is_self
        return {**_DIGEST, "name": name, "is_self": False, "from_cache": True}

    monkeypatch.setattr(main.deep_dive, "reusable_report", _fake_reusable)
    monkeypatch.setattr(main.skill_memory, "note_interaction", lambda *a, **k: None)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    r = _client.post(
        "/deep-dive", headers=_auth(monkeypatch),
        json={"target_uid": "b1", "name": "Dana Reyes"},
    )
    assert r.status_code == 200
    assert r.json().get("queued") is not True
    assert seen == {"target_uid": "b1", "is_self": False}


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


# --- teaser() — the chat-message pointer, never the report's contents ------


def test_teaser_never_leaks_the_reports_contents():
    text = deep_dive.teaser({**_DIGEST, "name": "Dana", "is_self": True})
    assert "marine biologist" not in text
    assert "Oceanarium" not in text
    assert "oceanario.pt" not in text
    assert "I looked you up online" in text


def test_teaser_names_the_other_person():
    text = deep_dive.teaser({**_DIGEST, "name": "Dana Reis", "is_self": False})
    assert "Dana Reis" in text
    assert "marine biologist" not in text


def test_teaser_flags_a_reused_report_without_dumping_it():
    text = deep_dive.teaser(
        {**_DIGEST, "name": "Dana", "is_self": False, "from_cache": True}
    )
    assert "Dana" in text
    assert "Oceanarium" not in text


def test_teaser_handles_a_thin_result():
    text = deep_dive.teaser(
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
    # A short teaser + the `[deep_dive:<id>]` sentinel — never the summary/
    # facts/links dumped into the reply itself (§ founder: keep report-result
    # chat messages to a teaser + link).
    assert "marine biologist" not in out
    assert "I looked you up online" in out
    assert out.endswith("[deep_dive:name_dana-reis]")


def test_skill_reports_when_out_of_credits(monkeypatch):
    async def _capped(*a, **k):
        raise token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(deep_dive, "run", _capped)
    fn = make_session_tool_fns(object(), "u9")["deep_dive"]
    out = _run(fn(full_name="X Y", subject="other"))
    # Routes through the shared out-of-credits copy (token_ledger.py) rather
    # than a hand-typed string, worded for this specific action.
    assert out == token_ledger.out_of_credits_message(token_ledger.CONTEXT_DEEP_DIVE)


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


def test_finished_deep_dive_push_points_at_the_report(monkeypatch):
    """The background job's push deep-links straight to the report the dive
    produced, not the chat tab (tapping the notification should open the
    report directly, not the Ayma chat)."""
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "Suhail Pallath")
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(main.deep_dive, "cached_dive", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "save_web_findings", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "promote", lambda *a, **k: None)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    async def _fake_run(name, *, uid, context, is_self, db=None, target_uid="",
                        force=False):
        return {**_DIGEST, "name": name, "is_self": True}

    monkeypatch.setattr(main.deep_dive, "run", _fake_run)

    calls = []

    async def _capture_notify(_db, uid, preview, deep_link):
        calls.append((uid, preview, deep_link))

    monkeypatch.setattr(
        main.notifications_triggers, "notify_skill_done", _capture_notify
    )

    # TestClient runs background tasks synchronously after the response.
    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    assert len(calls) == 1
    _uid, preview, deep_link = calls[0]
    assert preview == "Your web search on yourself is ready."
    # Same id the "View research" report opens at, not the generic "chat".
    assert deep_link == (
        f"deep_dive/{main.deep_dive.dive_report_id('', 'Suhail Pallath')}"
    )


def test_finished_deep_dive_falls_back_to_chat_when_nothing_found(monkeypatch):
    """A "not found" dive never gets a report_id, so the push has nowhere to
    deep-link to and should fall back to the chat tab, same as before."""
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "Suhail Pallath")
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(main.deep_dive, "cached_dive", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "save_web_findings", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "promote", lambda *a, **k: None)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    async def _fake_run(name, *, uid, context, is_self, db=None, target_uid="",
                        force=False):
        return {"summary": "", "confidence": "not_found", "facts": [],
                "name": name, "is_self": True}

    monkeypatch.setattr(main.deep_dive, "run", _fake_run)

    calls = []

    async def _capture_notify(_db, uid, preview, deep_link):
        calls.append((uid, preview, deep_link))

    monkeypatch.setattr(
        main.notifications_triggers, "notify_skill_done", _capture_notify
    )

    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    assert len(calls) == 1
    assert calls[0][2] == "chat"


def test_refresh_self_dive_notification_deep_links_to_the_report(monkeypatch):
    """SWEEP91-J1R: the web-research screen's REFRESH is `POST /deep-dive`
    `{force: true}` for the caller themselves. Its completion notification must
    carry the SAME `deep_dive/{report_id}` the auto path emits — the exact id
    the stored self-dive report opens at — not the chat fallback. (Verifies the
    refresh entry point emits an identical, resolvable record; the earlier
    reopened-bug claim that refresh wrote a different/chat-routing record does
    not hold in code.)"""
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "Suhail Pallath")
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(main.deep_dive, "cached_dive", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "save_web_findings", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "promote", lambda *a, **k: None)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    seen_force = []

    async def _fake_run(name, *, uid, context, is_self, db=None, target_uid="",
                        force=False):
        seen_force.append((is_self, target_uid, force))
        return {**_DIGEST, "name": name, "is_self": True}

    monkeypatch.setattr(main.deep_dive, "run", _fake_run)

    calls = []

    async def _capture_notify(_db, uid, preview, deep_link):
        calls.append((uid, preview, deep_link))

    monkeypatch.setattr(
        main.notifications_triggers, "notify_skill_done", _capture_notify
    )

    # A self refresh: empty target_uid, force=true (the screen's 🔄 action).
    r = _client.post(
        "/deep-dive", headers=_auth(monkeypatch), json={"force": True},
    )
    assert r.status_code == 200
    # Resolved as a self, forced (cache-skipping) dive.
    assert seen_force == [(True, "", True)]
    assert len(calls) == 1
    _uid, _preview, deep_link = calls[0]
    expected = f"deep_dive/{main.deep_dive.dive_report_id('', 'Suhail Pallath')}"
    assert deep_link == expected
    assert deep_link != "chat" and deep_link.endswith("name_suhail-pallath")


def test_endpoint_returns_a_cached_dive_inline_for_someone_else(monkeypatch):
    # Caching only ever short-circuits a dive on *someone else* — see
    # test_self_dive_never_uses_the_cache below for the self case.
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(
        main.deep_dive, "reusable_report",
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
        main.deep_dive, "reusable_report",
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
    assert not calls  # reusable_report is never even consulted for a self dive


def test_endpoint_400_when_there_is_no_name(monkeypatch):
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "")
    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 400


def test_cached_dive_response_carries_a_report_id_and_chat_marker(monkeypatch):
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(
        main.deep_dive, "reusable_report",
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
    # The skill name is correct for a web-search/deep-dive result — never a
    # different skill's label (§ founder bug: "Researched X online" followed
    # by "Here's your Appearance report" — wrong skill entirely).
    assert body["tool_label"] == "Researched Dana Reyes online"
    assert appended and appended[0].endswith("[deep_dive:uid_other]")
    # The chat text is a short teaser + the link — never the summary/facts
    # dumped inline (§ founder: keep report-result chat messages to a teaser
    # + link).
    assert "marine biologist" not in appended[0]
    assert "Oceanarium" not in appended[0]
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


# --- reliable finish: side-effect delivery + bounded retry (QA 00:41 drop) ---


def _patch_finish_env(monkeypatch):
    """Common stubs for driving `_finish_deep_dive` / `_deep_dive_job` directly:
    a dummy db, neutralised photo + timeline helpers, benign wiki bookkeeping,
    and instant backoff so the retry loop doesn't sleep in tests."""
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.story, "_photo_url_safe", lambda _p: "")
    monkeypatch.setattr(main.skill_memory, "save_web_findings", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_memory, "promote", lambda *a, **k: None)
    monkeypatch.setattr(main.skill_runs, "record", lambda *a, **k: None)

    async def _no_timeline(*a, **k):
        return None

    monkeypatch.setattr(main.career_timeline, "extract", _no_timeline)

    async def _instant(_seconds):
        return None

    monkeypatch.setattr(main.asyncio, "sleep", _instant)


def test_finish_delivers_card_and_push_even_when_wiki_write_throws(monkeypatch):
    """A throw in the non-essential wiki write (save_web_findings) must NOT skip
    the user-visible card + push that follow. Pre-fix the unguarded write
    propagated and dropped both (QA 00:41)."""
    _patch_finish_env(monkeypatch)

    def _boom(*a, **k):
        raise RuntimeError("firestore blip on the wiki write")

    monkeypatch.setattr(main.skill_memory, "save_web_findings", _boom)

    appended = []
    monkeypatch.setattr(
        main.chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append((role, text)),
    )
    notes = []

    async def _notify(_db, uid, preview, deep_link):
        notes.append((preview, deep_link))

    monkeypatch.setattr(main.notifications_triggers, "notify_skill_done", _notify)

    out = _run(
        main._finish_deep_dive(
            "me", {**_DIGEST, "name": "Me"},
            is_self=True, target="", name="Me", notify=True,
        )
    )
    assert out["delivered"] is True
    assert appended and appended[0][0] == "ayma"  # card still appended
    assert len(notes) == 1  # push still sent
    assert notes[0][0] == "Your web search on yourself is ready."


def test_job_does_not_mark_done_when_delivery_keeps_failing(monkeypatch):
    """A dive that completes server-side but can't deliver the card/push after
    the bounded retry must land as `failed`, never a false `done` — and the
    spend (metered inside run) is charged exactly once (run never retried)."""
    _patch_finish_env(monkeypatch)
    runs = []

    async def _fake_run(name, *, uid, context, is_self, db=None, target_uid="",
                        force=False):
        runs.append(uid)
        return {**_DIGEST, "name": name, "is_self": True}

    monkeypatch.setattr(main.deep_dive, "run", _fake_run)

    def _always_boom(*a, **k):
        raise RuntimeError("card write down")

    monkeypatch.setattr(main.chat_history, "append", _always_boom)

    async def _notify(*a, **k):
        return None

    monkeypatch.setattr(main.notifications_triggers, "notify_skill_done", _notify)
    marked = []
    monkeypatch.setattr(
        main.deep_dive, "mark_run",
        lambda _db, uid, rid, status: marked.append(status),
    )

    _run(main._deep_dive_job("me", "Me", "", True, "", True))
    assert marked == [main.deep_dive.RUN_FAILED]  # NOT RUN_DONE
    assert len(runs) == 1  # run (and its metering) happened exactly once


def test_job_retries_delivery_then_marks_done(monkeypatch):
    """A transient card-write blip self-heals within the job's bounded retry:
    the card lands once (no duplicate) and the run ends `done`."""
    _patch_finish_env(monkeypatch)

    async def _fake_run(name, *, uid, context, is_self, db=None, target_uid="",
                        force=False):
        return {**_DIGEST, "name": name, "is_self": True}

    monkeypatch.setattr(main.deep_dive, "run", _fake_run)

    appended = []
    attempts = {"n": 0}

    def _flaky_append(_db, uid, role, text, **kw):
        attempts["n"] += 1
        if attempts["n"] == 1:
            raise RuntimeError("transient blip")
        appended.append((role, text))

    monkeypatch.setattr(main.chat_history, "append", _flaky_append)
    notes = []

    async def _notify(_db, uid, preview, deep_link):
        notes.append(preview)

    monkeypatch.setattr(main.notifications_triggers, "notify_skill_done", _notify)
    marked = []
    monkeypatch.setattr(
        main.deep_dive, "mark_run",
        lambda _db, uid, rid, status: marked.append(status),
    )

    _run(main._deep_dive_job("me", "Me", "", True, "", True))
    assert marked == [main.deep_dive.RUN_DONE]  # recovered
    assert len(appended) == 1  # card appended exactly once
    assert len(notes) == 1  # notified exactly once


def test_job_retry_after_notify_failure_does_not_duplicate_card_or_recharge(
    monkeypatch,
):
    """When the push fails after the card already landed, the retry re-sends
    ONLY the push — the card isn't re-appended and run() (where the spend is
    metered) is not re-invoked, so there's no duplicate card and no
    double-charge."""
    _patch_finish_env(monkeypatch)
    runs = []

    async def _fake_run(name, *, uid, context, is_self, db=None, target_uid="",
                        force=False):
        runs.append(uid)
        return {**_DIGEST, "name": name, "is_self": True}

    monkeypatch.setattr(main.deep_dive, "run", _fake_run)

    appended = []
    monkeypatch.setattr(
        main.chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append(text),
    )
    notify_attempts = {"n": 0}
    sent = []

    async def _flaky_notify(_db, uid, preview, deep_link):
        notify_attempts["n"] += 1
        if notify_attempts["n"] == 1:
            raise RuntimeError("push gateway blip")
        sent.append(preview)

    monkeypatch.setattr(
        main.notifications_triggers, "notify_skill_done", _flaky_notify
    )
    marked = []
    monkeypatch.setattr(
        main.deep_dive, "mark_run",
        lambda _db, uid, rid, status: marked.append(status),
    )

    _run(main._deep_dive_job("me", "Me", "", True, "", True))
    assert len(runs) == 1  # the only place the dive is metered — ran once
    assert len(appended) == 1  # card NOT re-appended on the push retry
    assert len(sent) == 1  # push eventually delivered once
    assert marked == [main.deep_dive.RUN_DONE]


def test_job_marks_done_when_only_the_push_fails_and_card_lands(monkeypatch):
    """Card = in-app delivery that gates `done`; push = best-effort nudge.

    A finish where the PUSH fails on EVERY attempt (the emulator case — no valid
    FCM token) but the CARD succeeds must still end `done`: the user sees the
    report in chat, so a dead push must not fail the run or hide the card. The
    card lands exactly once and run() (the one metering site) runs once — no
    duplicate card, no double-charge. (QA rev-00076 refresh: a persistent-push
    failure used to flip the whole run to `failed`.)"""
    _patch_finish_env(monkeypatch)
    runs = []

    async def _fake_run(name, *, uid, context, is_self, db=None, target_uid="",
                        force=False):
        runs.append(uid)
        return {**_DIGEST, "name": name, "is_self": True}

    monkeypatch.setattr(main.deep_dive, "run", _fake_run)

    appended = []
    monkeypatch.setattr(
        main.chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append(text),
    )
    notify_attempts = {"n": 0}

    async def _dead_push(_db, uid, preview, deep_link):
        notify_attempts["n"] += 1
        raise RuntimeError("no FCM token on this device")

    monkeypatch.setattr(
        main.notifications_triggers, "notify_skill_done", _dead_push
    )
    marked = []
    monkeypatch.setattr(
        main.deep_dive, "mark_run",
        lambda _db, uid, rid, status: marked.append(status),
    )

    _run(main._deep_dive_job("me", "Me", "", True, "", True))
    # Card present → run is delivered → `done`, despite the push never landing.
    assert marked == [main.deep_dive.RUN_DONE]
    assert len(appended) == 1  # card appended exactly once (never duplicated)
    assert len(runs) == 1  # metered exactly once — no double-charge
    # The push was genuinely retried the full bounded number of times…
    assert notify_attempts["n"] == main._DEEP_DIVE_DELIVERY_ATTEMPTS
    # …then given up on as best-effort, not escalated to a run failure.


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


def test_deep_dive_report_endpoint_reads_a_known_users_report_from_their_own_collection(
    monkeypatch,
):
    """A `uid_<subject>`-shaped id is self-describing: it must be read from
    the SUBJECT's own collection (``other``), not the requester's (``me``) —
    the crux of the persistent-report-per-subject fix."""
    calls = []

    def _fake_read(_db, owner, rid):
        calls.append((owner, rid))
        if owner == "other" and rid == "uid_other":
            return {
                "digest": {**_DIGEST, "name": "Dana Reyes"},
                "name": "Dana Reyes", "target_uid": "other",
                "created_at": None,
            }
        return None

    monkeypatch.setattr(main.deep_dive, "read_dive", _fake_read)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.story, "_photo_url_safe", lambda _p: "")

    r = _client.get("/deep-dive-report/uid_other", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json()["is_self"] is False
    assert ("other", "uid_other") in calls
    assert ("me", "uid_other") not in calls


def test_deep_dive_report_endpoint_prefers_the_subjects_live_self_dive(monkeypatch):
    """Opening a cross-user report id pulls the subject's OWN, possibly more
    recently corrected, self-dive over whatever was mirrored at search time
    (§ founder: include the corrections made by the user being searched)."""

    def _fake_read(_db, owner, rid):
        if (owner, rid) == ("other", "uid_other"):
            return {
                "digest": {**_DIGEST, "name": "Dana Reyes", "summary": "stale mirror"},
                "name": "Dana Reyes", "target_uid": "other", "created_at": None,
            }
        if (owner, rid) == ("other", "name_dana-reyes"):
            return {
                "digest": {**_DIGEST, "name": "Dana Reyes", "summary": "freshly corrected"},
                "name": "Dana Reyes", "target_uid": "", "created_at": None,
            }
        return None

    monkeypatch.setattr(main.deep_dive, "read_dive", _fake_read)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.story, "_photo_url_safe", lambda _p: "")

    r = _client.get("/deep-dive-report/uid_other", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json()["digest"]["summary"] == "freshly corrected"


def test_deep_dive_report_endpoint_falls_back_to_a_pre_fix_legacy_location(
    monkeypatch,
):
    """A dive on someone else minted before this fix was stored under the
    SEARCHER's own collection — an old `[deep_dive:<id>]` chat marker must
    still open."""

    def _fake_read(_db, owner, rid):
        # Only the requester's own ("me") legacy copy exists — the subject's
        # collection ("other") has nothing.
        if owner == "me" and rid == "uid_other":
            return {
                "digest": {**_DIGEST, "name": "Dana Reyes"},
                "name": "Dana Reyes", "target_uid": "other", "created_at": None,
            }
        return None

    monkeypatch.setattr(main.deep_dive, "read_dive", _fake_read)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda _u: "")
    monkeypatch.setattr(main.story, "_photo_url_safe", lambda _p: "")

    r = _client.get("/deep-dive-report/uid_other", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json()["name"] == "Dana Reyes"


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


def _seed_self_report_links(db, uid, name, links):
    key = deep_dive._cache_key("", name)
    db.seed(
        ("users", uid, "deep_dives", key),
        {
            "digest": {"name": name, "links": links},
            "target_uid": "",
            "name": name,
        },
    )
    return key


def test_dispute_link_removes_it_and_persists_the_correction():
    db = _FakeDb()
    links = [
        {"url": "https://x.com/a", "title": "Profile A"},
        {"url": "https://x.com/b", "title": "Profile B"},
    ]
    key = _seed_self_report_links(db, "u1", "Dana Reis", links)

    result = deep_dive.dispute_link(db, "u1", key, "https://x.com/a")
    assert result is not None
    assert [ln["url"] for ln in result["digest"]["links"]] == ["https://x.com/b"]
    assert result["disputed_links"][0]["url"] == "https://x.com/a"
    assert result["disputed_links"][0]["title"] == "Profile A"

    stored = db.data[("users", "u1", "deep_dives", key)]
    assert [ln["url"] for ln in stored["digest"]["links"]] == ["https://x.com/b"]
    assert stored["disputed_links"][0]["disputed_at"]


def test_dispute_link_rejects_a_report_about_someone_else():
    db = _FakeDb()
    links = [{"url": "https://x.com/a", "title": "Profile A"}]
    key = "uid_other"
    db.seed(
        ("users", "u1", "deep_dives", key),
        {"digest": {"name": "Jordan", "links": links}, "target_uid": "other"},
    )
    with pytest.raises(PermissionError):
        deep_dive.dispute_link(db, "u1", key, "https://x.com/a")
    assert db.data[("users", "u1", "deep_dives", key)]["digest"]["links"] == links


def test_dispute_link_404s_style_none_for_missing_report_or_link():
    db = _FakeDb()
    links = [{"url": "https://x.com/a", "title": "Profile A"}]
    key = _seed_self_report_links(db, "u1", "Dana Reis", links)

    assert deep_dive.dispute_link(db, "u1", "no-such-key", "https://x.com/a") is None
    assert deep_dive.dispute_link(db, "u1", key, "https://no-such.example/x") is None


def _seed_self_report_social(db, uid, name, social_handles):
    key = deep_dive._cache_key("", name)
    db.seed(
        ("users", uid, "deep_dives", key),
        {
            "digest": {"name": name, "social_handles": social_handles},
            "target_uid": "",
            "name": name,
        },
    )
    return key


def _seed_self_report_images(db, uid, name, web_images):
    key = deep_dive._cache_key("", name)
    db.seed(
        ("users", uid, "deep_dives", key),
        {
            "digest": {"name": name, "web_images": web_images},
            "target_uid": "",
            "name": name,
        },
    )
    return key


def test_dispute_social_link_removes_it_and_persists_the_correction():
    db = _FakeDb()
    handles = [
        {"platform": "instagram", "url": "https://instagram.com/dana", "handle": "dana"},
        {"platform": "twitter", "url": "https://twitter.com/dana2", "handle": "dana2"},
    ]
    key = _seed_self_report_social(db, "u1", "Dana Reis", handles)

    result = deep_dive.dispute_social_link(db, "u1", key, "https://instagram.com/dana")
    assert result is not None
    assert [s["url"] for s in result["digest"]["social_handles"]] == ["https://twitter.com/dana2"]
    assert result["disputed_social"][0]["url"] == "https://instagram.com/dana"
    assert result["disputed_social"][0]["platform"] == "instagram"

    stored = db.data[("users", "u1", "deep_dives", key)]
    assert [s["url"] for s in stored["digest"]["social_handles"]] == ["https://twitter.com/dana2"]
    assert stored["disputed_social"][0]["disputed_at"]


def test_dispute_social_link_rejects_a_report_about_someone_else():
    db = _FakeDb()
    handles = [{"platform": "instagram", "url": "https://instagram.com/dana"}]
    key = "uid_other"
    db.seed(
        ("users", "u1", "deep_dives", key),
        {"digest": {"name": "Jordan", "social_handles": handles}, "target_uid": "other"},
    )
    with pytest.raises(PermissionError):
        deep_dive.dispute_social_link(db, "u1", key, "https://instagram.com/dana")
    assert db.data[("users", "u1", "deep_dives", key)]["digest"]["social_handles"] == handles


def test_dispute_social_link_404s_style_none_for_missing_report_or_link():
    db = _FakeDb()
    handles = [{"platform": "instagram", "url": "https://instagram.com/dana"}]
    key = _seed_self_report_social(db, "u1", "Dana Reis", handles)

    assert deep_dive.dispute_social_link(db, "u1", "no-such-key", "https://instagram.com/dana") is None
    assert deep_dive.dispute_social_link(db, "u1", key, "https://no-such.example/x") is None


def test_dispute_web_image_removes_it_and_persists_the_correction():
    db = _FakeDb()
    images = [
        {"url": "https://example.com/a.jpg", "source_page": "https://example.com/page-a"},
        {"url": "https://example.com/b.jpg", "source_page": "https://example.com/page-b"},
    ]
    key = _seed_self_report_images(db, "u1", "Dana Reis", images)

    result = deep_dive.dispute_web_image(db, "u1", key, "https://example.com/a.jpg")
    assert result is not None
    assert [im["url"] for im in result["digest"]["web_images"]] == ["https://example.com/b.jpg"]
    assert result["disputed_photos"][0]["url"] == "https://example.com/a.jpg"
    assert result["disputed_photos"][0]["source_page"] == "https://example.com/page-a"

    stored = db.data[("users", "u1", "deep_dives", key)]
    assert [im["url"] for im in stored["digest"]["web_images"]] == ["https://example.com/b.jpg"]
    assert stored["disputed_photos"][0]["disputed_at"]


def test_dispute_web_image_rejects_a_report_about_someone_else():
    db = _FakeDb()
    images = [{"url": "https://example.com/a.jpg", "source_page": "https://example.com/page-a"}]
    key = "uid_other"
    db.seed(
        ("users", "u1", "deep_dives", key),
        {"digest": {"name": "Jordan", "web_images": images}, "target_uid": "other"},
    )
    with pytest.raises(PermissionError):
        deep_dive.dispute_web_image(db, "u1", key, "https://example.com/a.jpg")
    assert db.data[("users", "u1", "deep_dives", key)]["digest"]["web_images"] == images


def test_dispute_web_image_404s_style_none_for_missing_report_or_image():
    db = _FakeDb()
    images = [{"url": "https://example.com/a.jpg", "source_page": "https://example.com/page-a"}]
    key = _seed_self_report_images(db, "u1", "Dana Reis", images)

    assert deep_dive.dispute_web_image(db, "u1", "no-such-key", "https://example.com/a.jpg") is None
    assert deep_dive.dispute_web_image(db, "u1", key, "https://no-such.example/x.jpg") is None


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


# --- store_dive: a fresh re-run preserves disputes/corrections/photos ------


def test_store_dive_preserves_disputed_facts_across_a_fresh_run():
    db = _FakeDb()
    key = deep_dive._cache_key("", "Dana Reis")
    db.seed(
        ("users", "u1", "deep_dives", key),
        {
            "digest": {"name": "Dana Reis", "facts": []},
            "disputed_facts": [{"claim": "Went to MIT", "category": "education"}],
        },
    )
    deep_dive.store_dive(db, "u1", {"name": "Dana Reis", "facts": []}, name="Dana Reis")
    stored = db.data[("users", "u1", "deep_dives", key)]
    assert stored["disputed_facts"] == [
        {"claim": "Went to MIT", "category": "education"}
    ]


def test_store_dive_preserves_corrections_across_a_fresh_run():
    db = _FakeDb()
    key = deep_dive._cache_key("", "Dana Reis")
    db.seed(
        ("users", "u1", "deep_dives", key),
        {
            "digest": {"name": "Dana Reis", "facts": []},
            "corrections": [{"target": "summary", "feedback": "wrong city"}],
        },
    )
    deep_dive.store_dive(db, "u1", {"name": "Dana Reis", "facts": []}, name="Dana Reis")
    stored = db.data[("users", "u1", "deep_dives", key)]
    assert stored["corrections"] == [{"target": "summary", "feedback": "wrong city"}]


def test_store_dive_preserves_confirmed_photos_when_the_fresh_digest_has_none():
    db = _FakeDb()
    key = deep_dive._cache_key("", "Dana Reis")
    db.seed(
        ("users", "u1", "deep_dives", key),
        {
            "digest": {
                "name": "Dana Reis", "facts": [],
                "confirmed_photos": [{"image_url": "https://cdn.example/a.jpg"}],
            },
        },
    )
    deep_dive.store_dive(db, "u1", {"name": "Dana Reis", "facts": []}, name="Dana Reis")
    stored = db.data[("users", "u1", "deep_dives", key)]
    assert stored["digest"]["confirmed_photos"] == [
        {"image_url": "https://cdn.example/a.jpg"}
    ]


def test_store_dive_new_digest_confirmed_photos_win_over_prior():
    db = _FakeDb()
    key = deep_dive._cache_key("", "Dana Reis")
    db.seed(
        ("users", "u1", "deep_dives", key),
        {
            "digest": {
                "confirmed_photos": [{"image_url": "https://cdn.example/old.jpg"}],
            },
        },
    )
    deep_dive.store_dive(
        db, "u1",
        {"name": "Dana Reis", "facts": [],
         "confirmed_photos": [{"image_url": "https://cdn.example/new.jpg"}]},
        name="Dana Reis",
    )
    stored = db.data[("users", "u1", "deep_dives", key)]
    assert stored["digest"]["confirmed_photos"] == [
        {"image_url": "https://cdn.example/new.jpg"}
    ]


def test_store_dive_keeps_created_at_across_runs():
    db = _FakeDb()
    key = deep_dive._cache_key("", "Dana Reis")
    db.seed(("users", "u1", "deep_dives", key), {"created_at": "day-one"})
    deep_dive.store_dive(db, "u1", {"name": "Dana Reis", "facts": []}, name="Dana Reis")
    assert db.data[("users", "u1", "deep_dives", key)]["created_at"] == "day-one"


# --- merge_confirmed_photo ---------------------------------------------------


def test_merge_confirmed_photo_appends_and_dedupes():
    db = _FakeDb()
    key = _seed_self_report(db, "u1", "Dana Reis", [])
    photo = {"image_url": "https://cdn.example/a.jpg", "source_url": "https://x"}

    assert deep_dive.merge_confirmed_photo(db, "u1", key, photo) is True
    assert deep_dive.merge_confirmed_photo(db, "u1", key, photo) is True  # no dup

    stored = db.data[("users", "u1", "deep_dives", key)]
    assert stored["digest"]["confirmed_photos"] == [photo]


def test_merge_confirmed_photo_is_a_noop_without_a_report():
    db = _FakeDb()
    photo = {"image_url": "https://cdn.example/a.jpg"}
    assert deep_dive.merge_confirmed_photo(db, "u1", "no-such-key", photo) is False


# --- Part 3: free-text corrections (§ deep-dive corrections) ---------------


def _correction_result(action, **extra):
    return {"action": action, "reply": "Got it.", **extra}


def test_correct_finding_remove_drops_the_fact_and_records_a_dispute(monkeypatch):
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "Went to MIT", "category": "education"}]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)

    async def _json(contents, system_prompt, response_schema=None, **kw):
        assert "Went to MIT" in contents
        assert "not actually me" in contents
        return _correction_result("remove")

    monkeypatch.setattr(gemini, "generate_json", _json)
    result = _run(
        deep_dive.correct_finding(
            db, "u1", key, target="fact:aaa111", feedback="not actually me",
        )
    )
    assert result["action"] == "remove"
    assert result["digest"]["facts"] == []
    stored = db.data[("users", "u1", "deep_dives", key)]
    assert stored["disputed_facts"][0]["claim"] == "Went to MIT"
    assert stored["corrections"][0]["feedback"] == "not actually me"


def test_correct_finding_revise_rewrites_the_claim(monkeypatch):
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "Went to MIT", "category": "education"}]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return _correction_result("revise", revised_claim="Went to Caltech")

    monkeypatch.setattr(gemini, "generate_json", _json)
    result = _run(
        deep_dive.correct_finding(
            db, "u1", key, target="fact:aaa111",
            feedback="it was actually Caltech",
        )
    )
    assert result["digest"]["facts"][0]["claim"] == "Went to Caltech"
    assert result["digest"]["facts"][0]["id"] == "aaa111"  # id survives a revise


def test_correct_finding_caveat_appends_a_note_to_the_claim(monkeypatch):
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "Works at Acme", "category": "work"}]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return _correction_result("caveat", note="left last year")

    monkeypatch.setattr(gemini, "generate_json", _json)
    result = _run(
        deep_dive.correct_finding(
            db, "u1", key, target="fact:aaa111", feedback="I don't work there anymore",
        )
    )
    assert "left last year" in result["digest"]["facts"][0]["claim"]


def test_correct_finding_keep_leaves_the_fact_untouched(monkeypatch):
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "Works at Acme", "category": "work"}]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return _correction_result("keep")

    monkeypatch.setattr(gemini, "generate_json", _json)
    result = _run(
        deep_dive.correct_finding(
            db, "u1", key, target="fact:aaa111", feedback="nice!",
        )
    )
    assert result["digest"]["facts"] == facts


def test_correct_finding_targets_the_summary(monkeypatch):
    db = _FakeDb()
    key = deep_dive._cache_key("", "Dana Reis")
    db.seed(
        ("users", "u1", "deep_dives", key),
        {"digest": {"name": "Dana Reis", "facts": [],
                     "summary": "Lives in Denver."},
         "target_uid": ""},
    )

    async def _json(contents, system_prompt, response_schema=None, **kw):
        assert "Lives in Denver" in contents
        return _correction_result("revise", revised_claim="Lives in Boulder.")

    monkeypatch.setattr(gemini, "generate_json", _json)
    result = _run(
        deep_dive.correct_finding(
            db, "u1", key, target="summary", feedback="I moved to Boulder",
        )
    )
    assert result["digest"]["summary"] == "Lives in Boulder."


def test_correct_finding_rejects_a_report_about_someone_else():
    db = _FakeDb()
    key = "uid_other"
    db.seed(
        ("users", "u1", "deep_dives", key),
        {"digest": {"name": "Jordan", "facts": [
            {"id": "aaa111", "claim": "x", "category": "work"}
        ]}, "target_uid": "other"},
    )
    with pytest.raises(PermissionError):
        _run(
            deep_dive.correct_finding(
                db, "u1", key, target="fact:aaa111", feedback="wrong",
            )
        )


def test_correct_finding_404s_style_none_for_missing_report_or_fact(monkeypatch):
    db = _FakeDb()
    facts = [{"id": "aaa111", "claim": "x", "category": "work"}]
    key = _seed_self_report(db, "u1", "Dana Reis", facts)

    assert _run(
        deep_dive.correct_finding(
            db, "u1", "no-such-key", target="fact:aaa111", feedback="wrong",
        )
    ) is None
    assert _run(
        deep_dive.correct_finding(
            db, "u1", key, target="fact:ghost", feedback="wrong",
        )
    ) is None


def test_correct_finding_requires_target_and_feedback():
    db = _FakeDb()
    key = _seed_self_report(db, "u1", "Dana Reis", [])
    assert _run(
        deep_dive.correct_finding(db, "u1", key, target="", feedback="x")
    ) is None
    assert _run(
        deep_dive.correct_finding(db, "u1", key, target="summary", feedback="")
    ) is None


# --- POST /deep-dive/{report_id}/correct ------------------------------------


def test_correct_endpoint_applies_the_correction(monkeypatch):
    async def _correct(_db, uid, report_id, *, target, feedback):
        assert uid == "me" and report_id == "r1"
        assert target == "fact:aaa111" and feedback == "not me"
        return {
            "report_id": "r1",
            "digest": {"name": "Me", "facts": []},
            "reply": "Removed that.",
            "action": "remove",
        }

    monkeypatch.setattr(main.deep_dive, "correct_finding", _correct)
    r = _client.post(
        "/deep-dive/r1/correct", headers=_auth(monkeypatch),
        json={"target": "fact:aaa111", "feedback": "not me"},
    )
    assert r.status_code == 200
    assert r.json() == {
        "ok": True, "reply": "Removed that.", "action": "remove",
        "digest": {"name": "Me", "facts": []},
    }


def test_correct_endpoint_404s_when_not_found(monkeypatch):
    async def _correct(*a, **k):
        return None

    monkeypatch.setattr(main.deep_dive, "correct_finding", _correct)
    r = _client.post(
        "/deep-dive/r1/correct", headers=_auth(monkeypatch),
        json={"target": "fact:ghost", "feedback": "wrong"},
    )
    assert r.status_code == 404


def test_correct_endpoint_403s_for_someone_elses_report(monkeypatch):
    async def _boom(*a, **k):
        raise PermissionError("nope")

    monkeypatch.setattr(main.deep_dive, "correct_finding", _boom)
    r = _client.post(
        "/deep-dive/uid_other/correct", headers=_auth(monkeypatch),
        json={"target": "summary", "feedback": "wrong"},
    )
    assert r.status_code == 403


def test_correct_endpoint_returns_usage_capped_on_the_credit_cap(monkeypatch):
    async def _capped(*a, **k):
        raise token_ledger.TokenCapExceeded()

    monkeypatch.setattr(main.deep_dive, "correct_finding", _capped)
    r = _client.post(
        "/deep-dive/r1/correct", headers=_auth(monkeypatch),
        json={"target": "summary", "feedback": "wrong"},
    )
    assert r.status_code == 200
    assert r.json() == {"usage_capped": True}


# --- run status (§ web research "Searching the web…" banner) -----------------


def _run_db(status, started_minutes_ago):
    from datetime import datetime, timedelta, timezone

    from fake_firestore import FakeDb

    started = datetime.now(timezone.utc) - timedelta(minutes=started_minutes_ago)
    return FakeDb({
        ("users", "me", "deep_dive_runs", "name_me"): {
            "status": status, "started_at": started, "finished_at": None,
        },
    })


def test_run_status_reports_a_fresh_running_run_as_running():
    db = _run_db("running", 2)
    assert deep_dive.run_status(db, "me", "name_me") == "running"


def test_run_status_marks_a_stale_running_run_failed_and_persists_it():
    db = _run_db("running", deep_dive.RUN_STALE_MINUTES + 5)
    assert deep_dive.run_status(db, "me", "name_me") == "failed"
    doc = db.docs[("users", "me", "deep_dive_runs", "name_me")]
    assert doc["status"] == "failed" and doc["finished_at"] is not None


def test_run_status_passes_finished_states_through_and_is_empty_without_a_run():
    assert deep_dive.run_status(_run_db("done", 60), "me", "name_me") == "done"
    assert deep_dive.run_status(_run_db("failed", 60), "me", "name_me") == "failed"
    assert deep_dive.run_status(_run_db("done", 0), "me", "other") == ""


def test_mark_run_running_resets_the_finish_and_done_keeps_the_start():
    from fake_firestore import FakeDb

    db = FakeDb()
    deep_dive.mark_run(db, "me", "name_me", deep_dive.RUN_RUNNING)
    doc = db.docs[("users", "me", "deep_dive_runs", "name_me")]
    assert doc["status"] == "running" and doc["finished_at"] is None
    started = doc["started_at"]
    deep_dive.mark_run(db, "me", "name_me", deep_dive.RUN_DONE)
    doc = db.docs[("users", "me", "deep_dive_runs", "name_me")]
    assert doc["status"] == "done" and doc["started_at"] is started


def _record_runs(monkeypatch):
    marks = []
    monkeypatch.setattr(
        main.deep_dive, "mark_run",
        lambda _db, uid, rid, status: marks.append((uid, rid, status)),
    )
    return marks


def test_endpoint_opens_a_running_run_and_returns_its_report_id(monkeypatch):
    monkeypatch.setattr(main, "_profile_full_name", lambda _uid: "Suhail Pallath")
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)

    async def _no_job(*a, **k):
        return None

    monkeypatch.setattr(main, "_deep_dive_job", _no_job)
    marks = _record_runs(monkeypatch)

    r = _client.post("/deep-dive", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    assert r.json()["report_id"] == "name_suhail-pallath"
    assert marks == [("me", "name_suhail-pallath", "running")]


def test_job_marks_its_run_done_after_storing_the_dive(monkeypatch):
    marks = _record_runs(monkeypatch)

    async def _fake_run(*a, **k):
        return {**_DIGEST, "name": "Me"}

    # Done now requires the user-visible card to have been delivered, which
    # `_finish_deep_dive` reports via `delivered` (card gates done; push is
    # best-effort). A stored-but-undelivered dive stays `failed` — see
    # test_job_does_not_mark_done_when_delivery_keeps_failing.
    async def _finish(*a, **k):
        return {"delivered": True}

    monkeypatch.setattr(main.deep_dive, "run", _fake_run)
    monkeypatch.setattr(main, "_finish_deep_dive", _finish)
    _run(main._deep_dive_job("me", "Me", "", True, "", True))
    assert marks == [("me", "name_me", "done")]


@pytest.mark.parametrize(
    "error", [RuntimeError("boom"), token_ledger.TokenCapExceeded()]
)
def test_job_marks_its_run_failed_when_the_search_raises(monkeypatch, error):
    marks = _record_runs(monkeypatch)

    async def _fail(*a, **k):
        raise error

    monkeypatch.setattr(main.deep_dive, "run", _fail)
    _run(main._deep_dive_job("me", "Dana", "", False, "other", True))
    assert marks == [("me", "uid_other", "failed")]


def test_job_marks_its_run_failed_even_when_cancelled(monkeypatch):
    marks = _record_runs(monkeypatch)

    async def _cancelled(*a, **k):
        raise asyncio.CancelledError()

    monkeypatch.setattr(main.deep_dive, "run", _cancelled)
    with pytest.raises(asyncio.CancelledError):
        _run(main._deep_dive_job("me", "Me", "", True, "", True))
    assert marks == [("me", "name_me", "failed")]


def test_deep_dive_report_endpoint_returns_the_callers_run_status(monkeypatch):
    stored = {"digest": {**_DIGEST, "name": "Me"}, "name": "Me", "target_uid": ""}
    monkeypatch.setattr(main.deep_dive, "read_dive", lambda *a: stored)
    seen = []

    def _status(_db, uid, rid):
        seen.append((uid, rid))
        return "running"

    monkeypatch.setattr(main.deep_dive, "run_status", _status)
    r = _client.get("/deep-dive-report/name_me", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json()["run_status"] == "running"
    assert seen == [("me", "name_me")]


# SWEEP91-J1R [S2]: the self web-search completion notification deep-links to
# `deep_dive/<report_id>`, and that <report_id> must resolve to the SELF dive
# the auto run just stored (`deep_dive.run(is_self=True)` -> `store_dive` writes
# the name-keyed `name_{slug}` doc) so the unchanged client opens the rendered
# /deep-dive/<id> report instead of landing on an empty / "Something didn't
# load" screen. The pre-existing notification test only asserts the emitted
# string; this one closes the store <-> notify-id <-> open contract end to end.
def test_self_dive_notification_id_opens_the_stored_report():
    import report_hub

    db = _FakeDb()
    name = "Ana Reis"
    # Exactly what deep_dive.run(is_self=True) persists on completion:
    # subject_uid = target_uid or uid = uid; target_uid="" -> name-keyed doc.
    result = {
        "name": name, "is_self": True,
        "summary": "Ana is a robotics engineer in Austin.",
        "confidence": "medium",
        "facts": [{"id": "f1", "claim": "Works at Acme", "category": "career",
                   "confidence": "high"}],
        "links": [], "web_images": [], "social_handles": [], "caveats": "",
    }
    deep_dive.store_dive(db, "u1", result, target_uid="", name=name)

    # The id the notification deep_link carries (auto_analysis.analyse_web and
    # main._finish_deep_dive both emit `deep_dive/{dive_report_id(name=name)}`).
    report_id = deep_dive.dive_report_id(name=name)
    assert report_id == "name_ana-reis"

    # The unchanged client routes `deep_dive/<id>` -> GET /report/deep_dive/<id>.
    out = report_hub.get_report(db, "deep_dive", report_id, "u1")
    assert out["title"] == "Web search: Ana Reis"
    assert out["meta"]["owner_uid"] == "u1"
    # Real content rendered (not an empty / 404 -> "No web research yet").
    blocks = {b["block_id"]: b for s in out["sections"] for b in s["blocks"]}
    assert "fact:f1" in blocks
    assert blocks["confidence"]["value"] == "Medium"  # humanized, not raw enum
