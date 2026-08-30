import asyncio
from datetime import datetime, timedelta, timezone

import pytest
import reengagement as re
from config import CONFIG


def _run(coro):
    return asyncio.run(coro)


NOW = datetime(2026, 8, 30, tzinfo=timezone.utc)


def _user(days_idle=None, last_sent=None, backoff=0, next_days=None):
    u = {}
    if days_idle is not None:
        u["last_active_at"] = NOW - timedelta(days=days_idle)
    if last_sent is not None:
        u["reengagement"] = {
            "last_sent_at": NOW - timedelta(days=last_sent),
            "backoff_days": backoff,
            "next_eligible_at": NOW + timedelta(days=next_days)
            if next_days is not None
            else None,
        }
    return u


def test_due_requires_inactivity_threshold():
    assert re._due(_user(days_idle=5), NOW) is True
    assert re._due(_user(days_idle=1), NOW) is False
    assert re._due(_user(days_idle=None), NOW) is False


def test_due_respects_backoff_window_while_still_away():
    # last active 10d ago, nudged 5d ago, next eligible 2d from now -> not due
    u = _user(days_idle=10, last_sent=5, backoff=7, next_days=2)
    assert re._due(u, NOW) is False
    # same but the backoff window has passed -> due again
    u2 = _user(days_idle=10, last_sent=5, backoff=7, next_days=-1)
    assert re._due(u2, NOW) is True


def test_next_backoff_starts_then_doubles_then_resets_on_return():
    assert re._next_backoff(_user(days_idle=5), NOW) == \
        CONFIG.reengage_backoff_start_days
    # nudged 3d ago, still away (idle 10d), prev backoff 7 -> doubles
    still_away = _user(days_idle=10, last_sent=3, backoff=7)
    assert re._next_backoff(still_away, NOW) == 14
    # came back: active 1d ago, last nudge 8d ago -> reset to start
    returned = _user(days_idle=1, last_sent=8, backoff=14)
    assert re._next_backoff(returned, NOW) == CONFIG.reengage_backoff_start_days


class _MatchDoc:
    def __init__(self, data):
        self._d = data

    def to_dict(self):
        return self._d


class _MatchDb:
    def __init__(self, matches):
        self._matches = matches

    def collection(self, name):
        assert name == "matches"
        return self

    def where(self, *_a, **_k):
        return self

    def stream(self):
        return [_MatchDoc(m) for m in self._matches]


def test_best_unacted_match_prefers_mutual_then_score():
    db = _MatchDb([
        {"uids": ["me", "a"], "status": "scored", "score": 0.72},
        {"uids": ["me", "b"], "status": "scored", "score": 0.9},
        {"uids": ["me", "c"], "status": "mutual_interest", "score": 0.4},
        {"uids": ["me", "d"], "status": "scored", "score": 0.95,
         "accepted_by": ["me"]},  # already acted on
    ])
    other, score, status = re._best_unacted_match(db, "me")
    assert (other, status) == ("c", "mutual_interest")


def test_best_unacted_match_none_below_threshold():
    db = _MatchDb([{"uids": ["me", "a"], "status": "scored", "score": 0.5}])
    assert re._best_unacted_match(db, "me") is None


class _FakeDb:
    def __init__(self, users, matches=None):
        self._users = users
        self._matches = matches or []
        self.writes = {}

    # users collection scan + doc writes; matches read
    def collection(self, name):
        return _FakeCol(self, name)


class _FakeCol:
    def __init__(self, db, name):
        self._db = db
        self._name = name

    def limit(self, _n):
        return self

    def where(self, *_a, **_k):
        return self

    def stream(self):
        if self._name == "users":
            return [
                _FakeSnap(uid, data) for uid, data in self._db._users.items()
            ]
        return [_MatchDoc(m) for m in self._db._matches]

    def document(self, doc_id):
        return _FakeDoc(self._db, self._name, doc_id)


class _FakeSnap:
    def __init__(self, uid, data):
        self.id = uid
        self._data = data

    def to_dict(self):
        return self._data


class _FakeDoc:
    def __init__(self, db, name, doc_id):
        self._db = db
        self._name = name
        self._id = doc_id

    def collection(self, name):
        return _FakeCol(self._db, f"{self._name}/{self._id}/{name}")

    def get(self):
        return _FakeSnap(self._id, {})

    def set(self, payload, merge=False):
        self._db.writes.setdefault((self._name, self._id), {}).update(payload)


@pytest.fixture
def _no_gemini(monkeypatch):
    async def _json(*_a, **_k):
        return {"message": "Still thinking about that trip you were planning?"}

    monkeypatch.setattr(re.gemini, "generate_json", _json)
    monkeypatch.setattr(re, "read_wiki_context", lambda db, uid: "likes trains")
    monkeypatch.setattr(re, "persist_raw_turns",
                        lambda db, uid, sid, turns: _persisted.append(
                            (uid, sid, turns[0].role, turns[0].text)))


_persisted = []


def test_run_sends_a_checkin_and_sets_backoff(monkeypatch, _no_gemini):
    _persisted.clear()
    pushes = []

    async def _notify(db, uid, text, deep_link="chat"):
        pushes.append((uid, text, deep_link))

    monkeypatch.setattr(re, "notify_checkin", _notify)
    monkeypatch.setattr(re.firestore, "SERVER_TIMESTAMP", "TS")

    db = _FakeDb({"idle-1": _user(days_idle=9)})
    result = _run(re.run(db))

    assert result == {"users_scanned": 1, "messages_sent": 1}
    assert _persisted and _persisted[0][0] == "idle-1"
    assert _persisted[0][2] == "ayma"
    assert pushes[0][0] == "idle-1"
    stored = db.writes[("users", "idle-1")]["reengagement"]
    assert stored["backoff_days"] == CONFIG.reengage_backoff_start_days


def test_run_skips_active_users(monkeypatch, _no_gemini):
    _persisted.clear()
    monkeypatch.setattr(re, "notify_checkin",
                        lambda *a, **k: asyncio.sleep(0))
    db = _FakeDb({"active": _user(days_idle=0)})
    result = _run(re.run(db))
    assert result == {"users_scanned": 1, "messages_sent": 0}
    assert _persisted == []
