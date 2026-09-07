import asyncio

import skills
import wiki_ingest
from skills import remember
from transcript import ROLE_USER, Turn


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


class _Snap:
    def __init__(self, data):
        self._data = data
        self.exists = data is not None

    def to_dict(self):
        return dict(self._data or {})


class _Doc:
    """Chainable stand-in for every collection()/document() hop; the terminal
    sessions doc reads/writes the shared ``store``."""

    def __init__(self, store):
        self.store = store

    def collection(self, _n):
        return self

    def document(self, _n):
        return self

    def get(self):
        return _Snap(self.store["data"])

    def set(self, patch, merge=False):  # noqa: ARG002
        self.store["data"] = {**(self.store["data"] or {}), **patch}


def _db_with_session(initial=None):
    store = {"data": initial}
    db = _Doc(store)
    return db


def test_registry_exposes_remember():
    assert "remember" in {s.name for s in skills.all_skills()}
    assert "remember" in {
        d["name"] for d in skills.session_tool_declarations()
    }


def test_runs_ingest_when_turn_gap_is_wide(monkeypatch):
    calls = []

    async def _fake_ingest(db, uid, sid, turns):  # noqa: ARG001
        calls.append((uid, sid, len(turns)))
        return 2

    monkeypatch.setattr(wiki_ingest, "ingest", _fake_ingest)

    db = _db_with_session()
    fn = remember._bind(
        db,
        "u1",
        session_id="s1",
        turn_index=12,
        turns=[Turn(ROLE_USER, "I want kids in the next few years")],
    )
    out = _run(fn("wants kids soon"))
    assert "updated your story" in out
    assert calls == [("u1", "s1", 1)]
    # cursor advanced so the next call inside the window is deferred
    assert db.store["data"]["wiki_last_ingest_turn"] == 12


def test_defers_when_called_again_within_the_gap(monkeypatch):
    calls = []

    async def _fake_ingest(*a, **k):  # noqa: ARG001
        calls.append(a)
        return 1

    monkeypatch.setattr(wiki_ingest, "ingest", _fake_ingest)

    db = _db_with_session({"wiki_last_ingest_turn": 10})
    fn = remember._bind(
        db, "u1", session_id="s1", turn_index=13,
        turns=[Turn(ROLE_USER, "hi")],
    )
    out = _run(fn("something"))
    assert "fold that into your story when we wrap up" in out
    assert calls == []  # no ingest call


def test_bare_highlight_is_enough_when_no_window(monkeypatch):
    seen = {}

    async def _fake_ingest(db, uid, sid, turns):  # noqa: ARG001
        seen["turns"] = turns
        return 1

    monkeypatch.setattr(wiki_ingest, "ingest", _fake_ingest)

    db = _db_with_session()
    fn = remember._bind(db, "u1", session_id="s1", turn_index=99, turns=None)
    out = _run(fn("plays competitive chess"))
    assert out == "updated your story (1 section(s))"
    assert "plays competitive chess" in seen["turns"][0].text
