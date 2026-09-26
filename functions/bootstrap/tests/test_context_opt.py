"""Tests for the token-cost context-optimization switchboard (context_opt.py,
cost program 2026-09-26): flag parsing, Phase 0 measurement, the level-2 wiki
page-type routing, and the rolling summary machinery."""

import asyncio

import pytest

import context_opt
from transcript import Turn


# --- a tiny in-memory Firestore stub (just what context_opt touches) ---------


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _Col:
    def __init__(self):
        self.added = []

    def add(self, doc):
        self.added.append(doc)

    def order_by(self, *a, **k):  # pruning path — return an empty query
        return self

    def offset(self, *_a):
        return self

    def limit(self, *_a):
        return self

    def stream(self):
        return []


class _UserDoc:
    def __init__(self, db, uid):
        self._db = db
        self._uid = uid

    def get(self):
        return _Snap(self._db.users.get(self._uid))

    def set(self, payload, merge=False):
        cur = self._db.users.setdefault(self._uid, {})
        cur.update(payload)

    def collection(self, name):
        return self._db.subcols.setdefault((self._uid, name), _Col())


class _Users:
    def __init__(self, db):
        self._db = db

    def document(self, uid):
        return _UserDoc(self._db, uid)


class _Db:
    def __init__(self):
        self.users = {}
        self.subcols = {}

    def collection(self, name):
        assert name == "users"
        return _Users(self)


@pytest.fixture
def db():
    return _Db()


@pytest.fixture(autouse=True)
def _fake_server_ts(monkeypatch):
    import firebase_admin.firestore as fs

    monkeypatch.setattr(fs, "SERVER_TIMESTAMP", "ts", raising=False)


# --- flags -------------------------------------------------------------------


def test_level_defaults_to_zero_everything_off(monkeypatch):
    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    assert context_opt.level() == 0
    assert not context_opt.voice_compression_enabled()
    assert not context_opt.stable_prefix_enabled()
    assert not context_opt.summary_enabled()
    assert not context_opt.voice_seed_diet_enabled()
    assert not context_opt.wiki_trim_enabled()
    assert not context_opt.recall_enabled()


def test_level_gates_stack_cumulatively(monkeypatch):
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "1")
    assert context_opt.voice_compression_enabled()
    assert context_opt.stable_prefix_enabled()
    assert not context_opt.summary_enabled()

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")
    assert context_opt.voice_compression_enabled()
    assert context_opt.summary_enabled()
    assert context_opt.voice_seed_diet_enabled()
    assert context_opt.wiki_trim_enabled()
    assert not context_opt.recall_enabled()

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "3")
    assert context_opt.recall_enabled()


def test_level_is_read_at_call_time_not_import_time(monkeypatch):
    # Rollback is a config flip: the same process must see a changed env.
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "3")
    assert context_opt.level() == 3
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "0")
    assert context_opt.level() == 0


def test_level_clamps_garbage_and_out_of_range(monkeypatch):
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "banana")
    assert context_opt.level() == 0
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "99")
    assert context_opt.level() == 3
    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "-4")
    assert context_opt.level() == 0


def test_measure_flag_is_independent_of_level(monkeypatch):
    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    monkeypatch.setenv("CONTEXT_OPT_MEASURE", "true")
    assert context_opt.measure_enabled()
    assert context_opt.level() == 0
    monkeypatch.setenv("CONTEXT_OPT_MEASURE", "false")
    assert not context_opt.measure_enabled()


# --- Phase 0 measurement -------------------------------------------------------


def test_record_breakdown_persists_when_measure_on(monkeypatch, db):
    monkeypatch.setenv("CONTEXT_OPT_MEASURE", "true")
    context_opt.record_breakdown(
        db, "u1", "chat",
        {"system": 4000, "wiki": 8000, "history": 2000, "message": 40},
        session_id="s1",
    )
    col = db.subcols[("u1", context_opt.TOKEN_TURNS_COLLECTION)]
    assert len(col.added) == 1
    doc = col.added[0]
    assert doc["surface"] == "chat"
    assert doc["session_id"] == "s1"
    assert doc["components_chars"]["wiki"] == 8000
    assert doc["components_tokens"]["wiki"] == 2000  # chars/4
    assert doc["total_chars"] == 14040
    assert doc["est_tokens"] == 14040 // 4


def test_record_breakdown_only_logs_when_measure_off(monkeypatch, db, caplog):
    monkeypatch.setenv("CONTEXT_OPT_MEASURE", "false")
    with caplog.at_level("INFO", logger="ayma.context_opt"):
        context_opt.record_breakdown(
            db, "u1", "chat", {"system": 400, "message": 40}, session_id="s1"
        )
    assert ("u1", context_opt.TOKEN_TURNS_COLLECTION) not in db.subcols
    assert any("context-breakdown" in r.message for r in caplog.records)


def test_record_breakdown_never_raises(monkeypatch):
    monkeypatch.setenv("CONTEXT_OPT_MEASURE", "true")

    class _Boom:
        def collection(self, *_a):
            raise RuntimeError("firestore down")

    context_opt.record_breakdown(_Boom(), "u1", "chat", {"system": 1})
