import asyncio

import dm_assist
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    monkeypatch.setattr(main, "_enforce_age", _noop_age)
    return {"Authorization": "Bearer valid"}


async def _noop_age(*_a, **_k):
    return None


def _run(coro):
    return asyncio.run(coro)


class _MatchDb:
    """Minimal Firestore stand-in that returns one ``matches`` doc (or none)."""

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


class _FakeProvider:
    """Stands in for the ``dm_coach`` LLM provider."""

    def __init__(self, result=None, boom=False):
        self._result = result
        self._boom = boom
        self.calls = []

    async def generate_json(self, contents, **kwargs):
        self.calls.append((contents, kwargs))
        if self._boom:
            raise RuntimeError("model down")
        return self._result


def _patch_provider(monkeypatch, provider):
    monkeypatch.setattr(
        dm_assist.llm_provider, "get_llm_provider", lambda surface: provider
    )
    return provider


# --- opener mode --------------------------------------------------------- #


def test_opener_returns_empty_without_a_match_doc(monkeypatch):
    provider = _patch_provider(monkeypatch, _FakeProvider(boom=True))
    out = _run(dm_assist.assist(_MatchDb(None), "aaa", "bbb", []))
    assert out == {"mode": "opener", "chips": [], "tip": None}
    assert provider.calls == []  # never even called the model


def test_opener_generates_chips_from_the_analysis(monkeypatch):
    doc = {
        "ai_explanation": "Both are into trail running and long-form podcasts.",
        "user_explanation": {"aaa": "You both love the outdoors."},
    }
    provider = _patch_provider(
        monkeypatch,
        _FakeProvider({"chips": ["  What's your favourite trail?  ", "", 5]}),
    )
    out = _run(dm_assist.assist(_MatchDb(doc), "aaa", "bbb", []))
    assert out["mode"] == "opener"
    assert out["chips"] == ["What's your favourite trail?"]
    assert out["tip"] is None
    assert "MODE: opener" in provider.calls[0][0]
    assert "trail running" in provider.calls[0][0]


# --- coach mode ---------------------------------------------------------- #


def test_coach_returns_chips_and_tip(monkeypatch):
    doc = {
        "ai_explanation": "Both love the outdoors.",
        "user_explanation": {"aaa": "You both love hiking."},
    }
    provider = _patch_provider(
        monkeypatch,
        _FakeProvider(
            {
                "chips": ["So what got you into climbing?", "I tried bouldering once"],
                "tip": "You're asking a lot — share something about yourself too.",
            }
        ),
    )
    messages = [
        {"from": "me", "text": "hey!"},
        {"from": "them", "text": "hey, I just got back from climbing"},
    ]
    out = _run(dm_assist.assist(_MatchDb(doc), "aaa", "bbb", messages))
    assert out["mode"] == "coach"
    assert out["chips"] == [
        "So what got you into climbing?",
        "I tried bouldering once",
    ]
    assert out["tip"] == "You're asking a lot — share something about yourself too."
    # Coach prompt carries both the analysis and the recent messages.
    sent = provider.calls[0][0]
    assert "MODE: coach" in sent
    assert "Them: hey, I just got back from climbing" in sent
    assert "Me: hey!" in sent


def test_assist_is_exempt_from_the_credit_cap(monkeypatch):
    """Root cause of the "no chips in a real thread" bug: DM assist is a nicety
    that must never block, so it calls the model with ``enforce_cap=False`` (the
    cap check is skipped, exactly like the Practice coach). A zero-credit user
    therefore still gets coaching instead of a silently-empty bar."""
    provider = _patch_provider(
        monkeypatch, _FakeProvider({"chips": ["tell me more"], "tip": "nice"})
    )
    _run(
        dm_assist.assist(
            _MatchDb(None), "aaa", "bbb", [{"from": "them", "text": "hi"}]
        )
    )
    assert provider.calls[0][1]["enforce_cap"] is False


def test_coach_survives_a_zero_credit_user(monkeypatch):
    """A provider that would raise ``TokenCapExceeded`` under the cap still
    yields coaching, because DM assist disables the cap check."""
    import token_ledger

    class _CappedProvider:
        async def generate_json(self, contents, **kwargs):
            # Mirror the real providers: only check the cap when asked to.
            if kwargs.get("enforce_cap", True):
                raise token_ledger.TokenCapExceeded("out of credits")
            return {"chips": ["so where to from here?"], "tip": "keep going"}

    _patch_provider(monkeypatch, _CappedProvider())
    out = _run(
        dm_assist.assist(
            _MatchDb(None), "aaa", "bbb", [{"from": "them", "text": "hey"}]
        )
    )
    assert out == {
        "mode": "coach",
        "chips": ["so where to from here?"],
        "tip": "keep going",
    }


def test_coach_works_without_a_match_doc(monkeypatch):
    provider = _patch_provider(
        monkeypatch, _FakeProvider({"chips": ["tell me more"], "tip": ""})
    )
    out = _run(
        dm_assist.assist(
            _MatchDb(None), "aaa", "bbb", [{"from": "them", "text": "hi there"}]
        )
    )
    assert out["mode"] == "coach"
    assert out["chips"] == ["tell me more"]
    assert out["tip"] is None  # empty string normalises to null


def test_assist_swallows_generation_errors(monkeypatch):
    doc = {"ai_explanation": "x", "user_explanation": {}}
    _patch_provider(monkeypatch, _FakeProvider(boom=True))
    out = _run(
        dm_assist.assist(
            _MatchDb(doc), "aaa", "bbb", [{"from": "me", "text": "hello"}]
        )
    )
    assert out == {"mode": "coach", "chips": [], "tip": None}


def test_dm_coach_surface_defaults_to_meta():
    from config import CONFIG

    assert CONFIG.llm_provider_dm_coach == "meta"


# --- endpoint ------------------------------------------------------------ #


def test_endpoint_rejects_self_as_other(monkeypatch):
    resp = client.post(
        "/dm/assist", json={"other": "aaa", "messages": []},
        headers=_auth(monkeypatch, uid="aaa"),
    )
    assert resp.status_code == 400


def test_endpoint_opener(monkeypatch):
    async def _fake_assist(db, uid, other, messages):
        assert (uid, other) == ("aaa", "bbb")
        assert messages == []
        return {"mode": "opener", "chips": ["chip one", "chip two"], "tip": None}

    monkeypatch.setattr(main.dm_assist, "assist", _fake_assist)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/dm/assist", json={"other": "bbb", "messages": []},
        headers=_auth(monkeypatch, uid="aaa"),
    )
    assert resp.status_code == 200
    assert resp.json() == {
        "mode": "opener", "chips": ["chip one", "chip two"], "tip": None,
    }


def test_endpoint_coach_passes_messages(monkeypatch):
    async def _fake_assist(db, uid, other, messages):
        assert messages == [
            {"from": "me", "text": "hi"},
            {"from": "them", "text": "hey you"},
        ]
        return {"mode": "coach", "chips": ["nice"], "tip": "keep going"}

    monkeypatch.setattr(main.dm_assist, "assist", _fake_assist)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/dm/assist",
        json={
            "other": "bbb",
            "messages": [
                {"from": "me", "text": "hi"},
                {"from": "them", "text": "hey you"},
            ],
        },
        headers=_auth(monkeypatch, uid="aaa"),
    )
    assert resp.status_code == 200
    assert resp.json() == {"mode": "coach", "chips": ["nice"], "tip": "keep going"}
