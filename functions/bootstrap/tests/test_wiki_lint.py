import asyncio

import gemini
import trust_flags
import wiki_lint


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    def to_dict(self):
        return dict(self._data)


class _DocRef:
    def __init__(self, store, page_id):
        self._store = store
        self._page_id = page_id

    def set(self, payload, merge=False):
        self._store.writes.append((self._page_id, payload, merge))


class _Coll:
    def __init__(self, store):
        self._store = store

    def stream(self):
        return iter(
            _Snap(pid, data) for pid, data in self._store.pages.items()
        )

    def document(self, page_id):
        return _DocRef(self._store, page_id)


class FakeDb:
    def __init__(self, pages):
        self.pages = pages
        self.writes = []

    def collection(self, name):
        return self

    def document(self, name):
        return self

    # users/{uid}: no trust flags yet, so a clean run has nothing to clear.
    def get(self):
        return _Snap("u1", {})

    # resolves users/{uid}/wiki_pages -> a collection of the seeded pages
    def stream(self):
        return _Coll(self).stream()

    def _wiki(self):
        return _Coll(self)


def _db(pages):
    db = FakeDb(pages)
    # make .collection("wiki_pages") return the wiki collection helper
    real_collection = db.collection

    def collection(name):
        if name == "wiki_pages":
            return db._wiki()
        return db

    db.collection = collection
    return db


def _run(coro):
    return asyncio.run(coro)


def test_lint_flags_a_contradiction_on_the_right_page(monkeypatch):
    db = _db(
        {
            "career": {"page_type": "career", "ai_body": "Works as a nurse.",
                       "links": []},
            "identity": {"page_type": "identity",
                         "ai_body": "Has never worked in healthcare.",
                         "links": []},
        }
    )

    async def _fake_json(contents, system_prompt, response_schema=None, **kw):
        assert kw["uid"] == "u1" and kw["feature"] == "wiki"
        assert "nurse" in contents
        return {
            "flags": [
                {
                    "page_id": "career",
                    "type": "contradiction",
                    "detail": "career says nurse; identity says never in "
                    "healthcare.",
                },
                {"page_id": "does-not-exist", "type": "stale", "detail": "x"},
                {"page_id": "identity", "type": "bogus", "detail": "y"},
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    tf = []
    monkeypatch.setattr(trust_flags, "sync_self_contradictions",
                        lambda db, uid, details: tf.append((uid, details)))
    flagged = _run(wiki_lint.lint_user(db, "u1"))

    assert flagged == 1
    assert tf == [("u1",
                   ["career says nurse; identity says never in healthcare."])]
    by_page = {pid: payload for pid, payload, _ in db.writes}
    assert len(by_page["career"]["lint_flags"]) == 1
    assert by_page["career"]["lint_flags"][0]["type"] == "contradiction"
    # invalid page_id / unknown type dropped; identity cleared
    assert by_page["identity"]["lint_flags"] == []


def test_lint_clears_flags_when_clean(monkeypatch):
    db = _db(
        {
            "a": {"page_type": "misc", "ai_body": "Likes tea.", "links": ["b"]},
            "b": {"page_type": "misc", "ai_body": "Likes cake.", "links": ["a"]},
        }
    )

    async def _fake_json(*a, **k):
        return {"flags": []}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    flagged = _run(wiki_lint.lint_user(db, "u1"))
    assert flagged == 0
    assert all(payload["lint_flags"] == [] for _, payload, _ in db.writes)


def test_lint_skips_the_model_for_fewer_than_two_pages(monkeypatch):
    db = _db({"solo": {"page_type": "misc", "ai_body": "Only page.",
                       "links": []}})
    called = False

    async def _fake_json(*a, **k):
        nonlocal called
        called = True
        return {"flags": []}

    monkeypatch.setattr(gemini, "generate_json", _fake_json)
    _run(wiki_lint.lint_user(db, "u1"))
    assert called is False
    assert db.writes[0][1]["lint_flags"] == []
