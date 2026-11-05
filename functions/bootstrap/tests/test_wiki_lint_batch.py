"""``wiki_lint.lint_all`` — DISABLED (founder rule 2026-11-04): the sweep
reports ``disabled`` and clears stale pending-batch state instead of
submitting a Vertex batch. ``lint_user`` (synchronous, gateway-routed) still
works.

Uses a small self-contained in-memory Firestore fake (documents keyed by a
tuple path) rather than a shared fixture, so this file has no dependency on
anything outside the test suite.
"""

import asyncio

import gemini
import trust_flags
import wiki_lint


def _run(coro):
    return asyncio.run(coro)


class _Snap:
    def __init__(self, key, data):
        self.id = key[-1]
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, db, key):
        self._db = db
        self.key = key

    def get(self):
        return _Snap(self.key, self._db.docs.get(self.key))

    def set(self, data, merge=False):
        cur = dict(self._db.docs.get(self.key) or {}) if merge else {}
        cur.update(data)
        self._db.docs[self.key] = cur

    def delete(self):
        self._db.docs.pop(self.key, None)

    def collection(self, name):
        return _CollRef(self._db, self.key + (name,))


class _Query:
    def __init__(self, coll, limit_n=None):
        self._coll = coll
        self._limit = limit_n

    def limit(self, n):
        return _Query(self._coll, n)

    def stream(self):
        depth = len(self._coll.key)
        out = [
            _Snap(key, data)
            for key, data in self._coll._db.docs.items()
            if len(key) == depth + 1 and key[:depth] == self._coll.key
        ]
        if self._limit is not None:
            out = out[: self._limit]
        return iter(out)


class _CollRef:
    def __init__(self, db, key):
        self._db = db
        self.key = key

    def document(self, doc_id):
        return _DocRef(self._db, self.key + (doc_id,))

    def limit(self, n):
        return _Query(self, n)

    def stream(self):
        return _Query(self).stream()


class FakeDb:
    def __init__(self, docs: dict[tuple, dict] | None = None):
        self.docs: dict[tuple, dict] = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


def _seed(users_pages: dict[str, dict[str, dict]]) -> FakeDb:
    seed = {}
    for uid, pages in users_pages.items():
        seed[("users", uid)] = {}
        for pid, data in pages.items():
            seed[("users", uid, "wiki_pages", pid)] = data
    return FakeDb(seed)


def _state(db):
    return db.collection("system").document("wiki_lint_batch")


def test_lint_all_reports_disabled_with_no_pending_state():
    db = _seed(
        {
            "u1": {
                "career": {"page_type": "career", "ai_body": "Nurse.", "links": []},
                "identity": {
                    "page_type": "identity", "ai_body": "Likes tea.", "links": [],
                },
            },
        }
    )

    result = _run(wiki_lint.lint_all(db))

    assert result["status"] == "disabled"
    assert result["reason"] == "batch_disabled_direct_google_killed"
    assert not _state(db).get().exists  # nothing submitted, nothing parked


def test_lint_all_clears_stale_pending_state_and_reports_disabled():
    db = FakeDb(
        {
            ("system", "wiki_lint_batch"): {
                "job_name": "batches/abc",
                "dest_prefix": "gemini_batches/wiki_lint/x/dest",
                "uids": ["u1"],
                "count": 1,
            }
        }
    )

    result = _run(wiki_lint.lint_all(db))

    assert result["status"] == "disabled"
    assert result["job_name"] == "batches/abc"
    assert not _state(db).get().exists  # stale state cleared, never polled


def test_lint_user_still_works_through_the_gateway(monkeypatch):
    db = _seed(
        {
            "u1": {
                "career": {"page_type": "career", "ai_body": "Nurse.", "links": []},
                "identity": {
                    "page_type": "identity",
                    "ai_body": "Never worked in healthcare.",
                    "links": [],
                },
            },
        }
    )

    async def _fake_json(*a, **k):
        return {
            "flags": [
                {
                    "page_id": "career", "type": "contradiction",
                    "detail": "career says nurse; identity disagrees.",
                }
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    tf = []
    monkeypatch.setattr(
        trust_flags, "sync_self_contradictions",
        lambda db, uid, details: tf.append((uid, details)),
    )

    assert _run(wiki_lint.lint_user(db, "u1")) == 1

    career = (
        db.collection("users").document("u1").collection("wiki_pages")
        .document("career").get().to_dict()
    )
    assert career["lint_flags"][0]["type"] == "contradiction"
    identity = (
        db.collection("users").document("u1").collection("wiki_pages")
        .document("identity").get().to_dict()
    )
    assert identity["lint_flags"] == []
    assert tf == [("u1", ["career says nurse; identity disagrees."])]


def test_lint_user_clears_flags_when_there_is_nothing_to_cross_check(monkeypatch):
    db = _seed({"u1": {"solo": {"page_type": "misc", "ai_body": "x", "links": []}}})
    monkeypatch.setattr(
        trust_flags, "sync_self_contradictions", lambda *a: None
    )

    assert _run(wiki_lint.lint_user(db, "u1")) == 0
    solo = (
        db.collection("users").document("u1").collection("wiki_pages")
        .document("solo").get().to_dict()
    )
    assert solo["lint_flags"] == []
