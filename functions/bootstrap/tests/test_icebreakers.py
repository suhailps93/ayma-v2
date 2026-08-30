import asyncio

import icebreakers
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def _run(coro):
    return asyncio.run(coro)


class _MatchDb:
    def __init__(self, doc):
        self._doc = doc

    def collection(self, name):
        assert name == "matches"
        return self

    def document(self, mid):
        self._mid = mid
        return self

    def get(self):
        doc = self._doc

        class _S:
            exists = doc is not None

            def to_dict(self):
                return doc

        return _S()


def test_suggest_returns_empty_without_a_match_doc(monkeypatch):
    called = []
    monkeypatch.setattr(
        icebreakers.gemini, "generate_json",
        lambda *a, **k: called.append(1),
    )
    out = _run(icebreakers.suggest(_MatchDb(None), "aaa", "bbb"))
    assert out == []
    assert called == []


def test_suggest_generates_chips_from_the_analysis(monkeypatch):
    doc = {
        "ai_explanation": "Both are into trail running and long-form podcasts.",
        "user_explanation": {"aaa": "You both love the outdoors."},
    }

    async def _fake_json(contents, system_prompt, response_schema, **_kw):
        assert "trail running" in contents
        return {"icebreakers": ["  What's your favourite trail?  ", "", 5]}

    monkeypatch.setattr(icebreakers.gemini, "generate_json", _fake_json)
    out = _run(icebreakers.suggest(_MatchDb(doc), "aaa", "bbb"))
    assert out == ["What's your favourite trail?"]


def test_suggest_swallows_generation_errors(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {}}

    async def _boom(*a, **k):
        raise RuntimeError("model down")

    monkeypatch.setattr(icebreakers.gemini, "generate_json", _boom)
    assert _run(icebreakers.suggest(_MatchDb(doc), "aaa", "bbb")) == []


def test_endpoint_rejects_non_participant(monkeypatch):
    resp = client.get(
        "/dm/aaa__bbb/icebreakers", headers=_auth(monkeypatch, uid="zzz")
    )
    assert resp.status_code == 403


def test_endpoint_returns_chips(monkeypatch):
    async def _fake_suggest(db, uid, other):
        assert (uid, other) == ("aaa", "bbb")
        return ["chip one", "chip two"]

    monkeypatch.setattr(main.icebreakers, "suggest", _fake_suggest)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.get(
        "/dm/aaa__bbb/icebreakers", headers=_auth(monkeypatch, uid="aaa")
    )
    assert resp.status_code == 200
    assert resp.json() == {"icebreakers": ["chip one", "chip two"]}
