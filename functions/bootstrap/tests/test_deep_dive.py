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

    async def _fake_run(name, *, uid, context, is_self):
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

    async def _fake_run(name, *, uid, context, is_self):
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
