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
