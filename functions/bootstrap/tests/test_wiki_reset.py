import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


class _SnapRef:
    def __init__(self, sink, coll, doc_id):
        self._sink = sink
        self._coll = coll
        self._id = doc_id

    @property
    def reference(self):
        return self

    def delete(self):
        self._sink.append((self._coll, self._id))


class _Coll:
    def __init__(self, sink, name, docs):
        self._sink = sink
        self._name = name
        self._docs = docs

    def stream(self):
        return [_SnapRef(self._sink, self._name, d) for d in self._docs]


class _User:
    def __init__(self, sink, contents):
        self._sink = sink
        self._contents = contents

    def collection(self, name):
        return _Coll(self._sink, name, self._contents.get(name, []))


class _Db:
    def __init__(self, sink, contents):
        self._sink = sink
        self._contents = contents

    def collection(self, name):
        assert name == "users"
        db = self

        class _Users:
            def document(self_, uid):
                return _User(db._sink, db._contents)

        return _Users()


def test_wiki_reset_clears_learned_collections_only(monkeypatch):
    deleted = []
    contents = {
        "wiki_pages": ["career", "values"],
        "raw_turns": ["s1", "s2", "s3"],
        "pending_questions": ["q1"],
    }
    monkeypatch.setattr(main, "get_db", lambda: _Db(deleted, contents))

    resp = client.post("/wiki/reset", headers=_auth(monkeypatch, uid="me"))
    assert resp.status_code == 200
    body = resp.json()
    assert body["deleted"] == {
        "wiki_pages": 2, "raw_turns": 3, "pending_questions": 1
    }
    # only those three collections were touched
    assert {c for c, _ in deleted} == {
        "wiki_pages", "raw_turns", "pending_questions"
    }
    assert len(deleted) == 6


def test_wiki_reset_requires_auth():
    assert client.post("/wiki/reset").status_code in (401, 403)
