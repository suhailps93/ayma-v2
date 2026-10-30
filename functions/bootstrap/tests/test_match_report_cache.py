"""Cache-aware match report (bugs F + H).

A COMPLETE stored ``matches/{id}`` doc is served instantly and never recomputed
(bug F); a stale "lite" doc (score only, no dimension breakdown) is treated as a
cache MISS and recomputed via the full scorer (bug H).
"""

import main
from fastapi.testclient import TestClient
from pair_key import sorted_pair_key

client = TestClient(main.app)


# --- _match_doc_is_complete --------------------------------------------------


def test_match_doc_is_complete_distinguishes_lite_from_full():
    assert main._match_doc_is_complete(None) is False
    assert main._match_doc_is_complete({}) is False
    # a doc with no score at all is not a usable report
    assert main._match_doc_is_complete({"structured_score": 70.0, "method": "m"}) is False
    # a demo-seed "lite" doc: a score but no breakdown
    lite = {
        "score": 0.8,
        "ai_explanation": "x",
        "user_explanation": {},
        "dimensions": [],
    }
    assert main._match_doc_is_complete(lite) is False
    # a full doc written by the real scorer
    full = {
        "score": 0.8,
        "structured_score": 72.0,
        "method": "This score blends ...",
        "dimensions": [{"key": "values"}],
    }
    assert main._match_doc_is_complete(full) is True
    # a 0% hard-dealbreaker report is still a COMPLETE report (score 0.0,
    # structured_score 0.0, method set)
    zero = {"score": 0.0, "structured_score": 0.0, "method": "m", "dimensions": []}
    assert main._match_doc_is_complete(zero) is True


# --- endpoint: fake db + dependency override ---------------------------------


class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _Doc:
    def __init__(self, data):
        self._data = data

    def get(self):
        return _Snap(self._data)


class _Coll:
    def __init__(self, docs):
        self._docs = docs

    def document(self, doc_id):
        return _Doc(self._docs.get(doc_id))


class _FakeDb:
    def __init__(self, matches):
        self._matches = matches

    def collection(self, name):
        assert name == main.MATCHES_COLLECTION
        return _Coll(self._matches)


def _override_uid(uid):
    main.app.dependency_overrides[main.require_adult_uid] = lambda: uid


def _clear_override():
    main.app.dependency_overrides.pop(main.require_adult_uid, None)


def test_check_compatibility_recomputes_a_lite_doc(monkeypatch):
    uid, other = "u1", "u2"
    mid = sorted_pair_key(uid, other)
    db = _FakeDb({mid: {"score": 0.8, "dimensions": [], "ai_explanation": "x"}})
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    called = {}

    async def _fake_job(a, b, *, notify=True):
        called["job"] = (a, b, notify)

    monkeypatch.setattr(main, "_match_job", _fake_job)

    _override_uid(uid)
    try:
        resp = client.post("/check-compatibility", json={"other_uid": other})
    finally:
        _clear_override()

    assert resp.status_code == 200
    body = resp.json()
    # A lite doc is NOT served as a cache hit -> a fresh full score is queued.
    assert body["queued"] is True
    assert called["job"] == (uid, other, True)


def test_check_compatibility_serves_a_complete_doc_from_cache(monkeypatch):
    uid, other = "u1", "u2"
    mid = sorted_pair_key(uid, other)
    db = _FakeDb(
        {
            mid: {
                "score": 0.8,
                "structured_score": 70.0,
                "method": "blended",
                "dimensions": [{"key": "values"}],
                "shared": ["loves hiking"],
                "tensions": [],
                "user_explanation": {uid: "you two line up"},
            }
        }
    )
    monkeypatch.setattr(main, "get_db", lambda: db)
    called = {}

    async def _fake_job(a, b, *, notify=True):
        called["job"] = True

    monkeypatch.setattr(main, "_match_job", _fake_job)

    _override_uid(uid)
    try:
        resp = client.post("/check-compatibility", json={"other_uid": other})
    finally:
        _clear_override()

    assert resp.status_code == 200
    body = resp.json()
    # Complete -> served from cache, nothing recomputed.
    assert body["queued"] is False
    assert body["score"] == 0.8
    assert body["shared"] == ["loves hiking"]
    assert "job" not in called


from datetime import datetime, timezone, timedelta


class _StaleSnap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _QDoc:
    def __init__(self, data):
        self._data = data

    def to_dict(self):
        return dict(self._data)


class _UsersDb:
    """Fake supporting users/{uid}/profile/main .get() and users/{uid}/questionnaire .stream(), plus matches."""

    def __init__(self, profiles, questionnaires, matches=None):
        # profiles: {uid: {...}} ; questionnaires: {uid: [ {...}, ... ]}
        self._profiles = profiles
        self._questionnaires = questionnaires
        self._matches = matches or {}

    def collection(self, name):
        if name == main.MATCHES_COLLECTION:
            return _MatchColl(self._matches)
        assert name == "users"
        return _UserColl(self)


class _MatchColl:
    def __init__(self, matches):
        self._matches = matches

    def document(self, mid):
        return _MatchDoc(self._matches.get(mid))


class _MatchDoc:
    def __init__(self, data):
        self._data = data

    def get(self):
        return _StaleSnap(self._data)


class _UserColl:
    def __init__(self, db):
        self._db = db

    def document(self, uid):
        return _UserDoc(self._db, uid)


class _UserDoc:
    def __init__(self, db, uid):
        self._db = db
        self._uid = uid

    def collection(self, name):
        if name == "profile":
            return _ProfileColl(self._db, self._uid)
        if name == "questionnaire":
            return _QColl(self._db, self._uid)
        raise AssertionError(name)


class _ProfileColl:
    def __init__(self, db, uid):
        self._db = db
        self._uid = uid

    def document(self, doc_id):
        assert doc_id == "main"
        return _MatchDoc(self._db._profiles.get(self._uid))


class _QColl:
    def __init__(self, db, uid):
        self._db = db
        self._uid = uid

    def stream(self):
        return [_QDoc(q) for q in self._db._questionnaires.get(self._uid, [])]


def test_latest_ts_ignores_non_datetimes():
    t = datetime(2026, 1, 1, tzinfo=timezone.utc)
    assert main._latest_ts(None, "x", t, 5) == t
    assert main._latest_ts(None, "x") is None


def test_match_inputs_mtime_takes_newest_of_profile_and_questionnaire():
    old = datetime(2026, 1, 1, tzinfo=timezone.utc)
    new = datetime(2026, 2, 1, tzinfo=timezone.utc)
    db = _UsersDb(
        profiles={"u1": {"updated_at": old}},
        questionnaires={"u1": [{"updated_at": new}, {"updated_at": old}]},
    )
    assert main._match_inputs_mtime(db, "u1") == new


def test_match_doc_is_stale_true_when_inputs_newer_than_scored():
    scored = datetime(2026, 1, 1, tzinfo=timezone.utc)
    newer = scored + timedelta(days=1)
    db = _UsersDb(profiles={"a": {"updated_at": newer}, "b": {}}, questionnaires={})
    assert main._match_doc_is_stale(db, {"updated_at": scored}, "a", "b") is True


def test_match_doc_is_stale_false_when_fresh():
    scored = datetime(2026, 2, 1, tzinfo=timezone.utc)
    older = datetime(2026, 1, 1, tzinfo=timezone.utc)
    db = _UsersDb(
        profiles={"a": {"updated_at": older}, "b": {"updated_at": older}},
        questionnaires={},
    )
    assert main._match_doc_is_stale(db, {"updated_at": scored}, "a", "b") is False


def test_match_doc_is_stale_false_when_no_timestamps():
    db = _UsersDb(profiles={"a": {}, "b": {}}, questionnaires={})
    assert main._match_doc_is_stale(db, {"score": 0.5}, "a", "b") is False


def test_check_compatibility_recomputes_a_stale_complete_doc(monkeypatch):
    uid, other = "u1", "u2"
    mid = sorted_pair_key(uid, other)
    scored = datetime(2026, 1, 1, tzinfo=timezone.utc)
    newer = scored + timedelta(days=2)
    complete_stale = {
        "score": 0.65,
        "structured_score": 65.0,
        "method": "blended",
        "dimensions": [{"key": "values"}],
        "updated_at": scored,
    }
    db = _UsersDb(
        profiles={uid: {"updated_at": newer}, other: {}},
        questionnaires={},
        matches={mid: complete_stale},
    )
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    called = {}

    async def _fake_job(a, b, *, notify=True):
        called["job"] = (a, b, notify)

    monkeypatch.setattr(main, "_match_job", _fake_job)
    _override_uid(uid)
    try:
        resp = client.post("/check-compatibility", json={"other_uid": other})
    finally:
        _clear_override()
    assert resp.status_code == 200
    assert resp.json()["queued"] is True
    assert called["job"] == (uid, other, True)
