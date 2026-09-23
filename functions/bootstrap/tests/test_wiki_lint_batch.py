"""``wiki_lint.lint_all``'s two-phase Gemini Batch sweep — submit when
nothing is pending, finalize (or report "pending") when something is.

Uses a small self-contained in-memory Firestore fake (documents keyed by a
tuple path) rather than a shared fixture, so this file has no dependency on
anything outside the test suite.
"""

import asyncio

import gemini_batch
import trust_flags
import wiki_lint
from google.genai import types as genai_types


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


class _Out:
    def __init__(self, dest):
        self.gcs_output_directory = dest


class _Job:
    def __init__(self, state, dest=None, error=None):
        self.state = state
        self.error = error
        self.output_info = _Out(dest) if dest else None


def _seed(users_pages: dict[str, dict[str, dict]]) -> FakeDb:
    seed = {}
    for uid, pages in users_pages.items():
        seed[("users", uid)] = {}
        for pid, data in pages.items():
            seed[("users", uid, "wiki_pages", pid)] = data
    return FakeDb(seed)


def _state(db):
    return db.collection("system").document("wiki_lint_batch")


def test_submits_a_batch_for_users_with_two_plus_pages_and_clears_solo_users(
    monkeypatch,
):
    db = _seed(
        {
            "u1": {
                "career": {"page_type": "career", "ai_body": "Nurse.", "links": []},
                "identity": {
                    "page_type": "identity", "ai_body": "Likes tea.", "links": [],
                },
            },
            "u2": {
                "solo": {"page_type": "misc", "ai_body": "Only page.", "links": []}
            },
        }
    )

    calls = {}

    def _fake_submit(items, system_prompt, schema, *, job_tag, **kw):
        calls["items"] = items
        calls["job_tag"] = job_tag
        return gemini_batch.BatchSubmission(
            job_name="batches/abc", dest_prefix="gemini_batches/wiki_lint/x/dest",
            count=len(items),
        )

    monkeypatch.setattr(gemini_batch, "submit_json_batch", _fake_submit)

    result = _run(wiki_lint.lint_all(db))

    assert result["status"] == "submitted"
    assert result["job_name"] == "batches/abc"
    assert result["batched"] == 1
    assert result["users_checked"] == 1  # u2, cleared without a model call
    assert calls["job_tag"] == "wiki_lint"
    assert len(calls["items"]) == 1

    state = _state(db).get().to_dict()
    assert state["uids"] == ["u1"]
    assert state["job_name"] == "batches/abc"

    u2_flags = (
        db.collection("users").document("u2").collection("wiki_pages")
        .document("solo").get().to_dict()
    )
    assert u2_flags["lint_flags"] == []


def test_returns_done_directly_when_nobody_needs_the_model(monkeypatch):
    db = _seed({"u1": {"solo": {"page_type": "misc", "ai_body": "x", "links": []}}})
    called = False

    def _fake_submit(*a, **k):
        nonlocal called
        called = True

    monkeypatch.setattr(gemini_batch, "submit_json_batch", _fake_submit)

    result = _run(wiki_lint.lint_all(db))
    assert result == {
        "status": "done", "users_checked": 1, "pages_flagged": 0, "batched": 0,
    }
    assert called is False
    assert not _state(db).get().exists


def test_reports_pending_while_the_batch_job_is_still_running(monkeypatch):
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
    monkeypatch.setattr(
        gemini_batch, "poll_json_batch",
        lambda name: _Job(genai_types.JobState.JOB_STATE_RUNNING),
    )

    result = _run(wiki_lint.lint_all(db))
    assert result == {"status": "pending", "job_name": "batches/abc"}
    assert _state(db).get().exists  # left alone for the next tick


def test_finalizes_a_succeeded_batch_and_applies_flags(monkeypatch):
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
    db.docs[("system", "wiki_lint_batch")] = {
        "job_name": "batches/abc",
        "dest_prefix": "gemini_batches/wiki_lint/x/dest",
        "uids": ["u1"],
        "count": 1,
    }

    monkeypatch.setattr(
        gemini_batch, "poll_json_batch",
        lambda name: _Job(
            genai_types.JobState.JOB_STATE_SUCCEEDED,
            dest="gemini_batches/wiki_lint/x/actual_dest",
        ),
    )

    def _fake_fetch(dest, *, expected_count):
        assert dest == "gemini_batches/wiki_lint/x/actual_dest"
        assert expected_count == 1
        return [
            {
                "flags": [
                    {
                        "page_id": "career", "type": "contradiction",
                        "detail": "career says nurse; identity disagrees.",
                    }
                ]
            }
        ]

    monkeypatch.setattr(gemini_batch, "fetch_json_batch_results", _fake_fetch)

    tf = []
    monkeypatch.setattr(
        trust_flags, "add_trust_flag",
        lambda db, uid, t, d: tf.append((uid, t, d)),
    )

    result = _run(wiki_lint.lint_all(db))
    assert result == {"status": "done", "users_checked": 1, "pages_flagged": 1}
    assert not _state(db).get().exists

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
    assert tf == [
        ("u1", "self_contradiction", "career says nurse; identity disagrees.")
    ]


def test_finalize_reports_failed_and_clears_state_on_a_terminal_job_state(
    monkeypatch,
):
    db = FakeDb(
        {
            ("system", "wiki_lint_batch"): {
                "job_name": "batches/abc", "dest_prefix": "d",
                "uids": ["u1"], "count": 1,
            }
        }
    )
    monkeypatch.setattr(
        gemini_batch, "poll_json_batch",
        lambda name: _Job(genai_types.JobState.JOB_STATE_FAILED, error="boom"),
    )

    result = _run(wiki_lint.lint_all(db))
    assert result["status"] == "failed"
    assert result["job_name"] == "batches/abc"
    assert not _state(db).get().exists


def test_finalize_reports_failed_when_results_cannot_be_read(monkeypatch):
    db = _seed(
        {
            "u1": {
                "a": {"page_type": "misc", "ai_body": "x", "links": []},
                "b": {"page_type": "misc", "ai_body": "y", "links": []},
            },
        }
    )
    db.docs[("system", "wiki_lint_batch")] = {
        "job_name": "batches/abc", "dest_prefix": "d", "uids": ["u1"], "count": 1,
    }
    monkeypatch.setattr(
        gemini_batch, "poll_json_batch",
        lambda name: _Job(genai_types.JobState.JOB_STATE_SUCCEEDED, dest="d"),
    )

    def _boom(dest, *, expected_count):
        raise RuntimeError("count mismatch")

    monkeypatch.setattr(gemini_batch, "fetch_json_batch_results", _boom)

    result = _run(wiki_lint.lint_all(db))
    assert result["status"] == "failed"
    assert not _state(db).get().exists
