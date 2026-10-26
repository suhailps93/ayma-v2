import asyncio

import backfill_ops
import token_ledger
import wiki_ingest


def _run(coro):
    # A fresh loop per call so these tests don't inherit a global event loop
    # another test has already closed (which otherwise fails both async cases
    # in the full-suite run while they pass in isolation).
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


class _Doc:
    def __init__(self, doc_id, data, parent):
        self.id = doc_id
        self._data = data
        self.reference = self
        self.parent = parent

    def to_dict(self):
        return dict(self._data)

    def set(self, payload, merge=False):
        for k, v in payload.items():
            if v == "DEL":
                self._data.pop(k, None)
            else:
                self._data[k] = v


class _Query:
    def __init__(self, docs):
        self._docs = docs

    def where(self, field, op, val):
        assert (field, op, val) == ("ingest_pending", "==", True)
        return _Query([d for d in self._docs if d._data.get("ingest_pending")])

    def order_by(self, _f):
        return self

    def limit(self, n):
        return _Query(self._docs[:n])

    def stream(self):
        return list(self._docs)


class _RawTurns(_Query):
    def document(self, doc_id):
        for d in self._docs:
            if d.id == doc_id:
                return d
        d = _Doc(doc_id, {}, self)
        self._docs.append(d)
        return d


class _Db:
    def __init__(self, docs):
        self._rt = _RawTurns(docs)

    def collection(self, _):
        return self

    def document(self, _):
        return self

    # users/{uid}/raw_turns  -> the raw-turns query
    def __getattr__(self, name):
        raise AttributeError(name)

    def _raw_turns(self):
        return self._rt


def _db(docs):
    db = _Db(docs)
    # collection().document().collection() chain all return db until raw_turns
    db.collection = lambda _n: db  # type: ignore
    db.document = lambda _n: db  # type: ignore
    orig = db.collection

    class _C:
        def __init__(self, rt):
            self._rt = rt

        def document(self, _):
            return self

        def collection(self, name):
            return self._rt if name == "raw_turns" else self

    holder = _C(db._rt)
    db.collection = lambda _n: holder  # type: ignore
    return db, holder


def test_mark_pending_sets_the_flag(monkeypatch):
    docs = []
    _, holder = _db(docs)

    class _DB2:
        def collection(self, _):
            return holder

    import firebase_admin.firestore as fs
    monkeypatch.setattr(fs, "SERVER_TIMESTAMP", "TS")

    backfill_ops.mark_pending(_DB2(), "u1", "sess-1")
    d = holder._rt.document("sess-1")
    assert d._data["ingest_pending"] is True


def test_drain_reingests_pending_docs_and_clears_the_flag(monkeypatch):
    calls = []

    async def _fake_ingest(db, uid, sid, turns, **kw):
        calls.append((uid, sid, [t.text for t in turns]))
        return 1

    monkeypatch.setattr(wiki_ingest, "ingest", _fake_ingest)

    import firebase_admin.firestore as fs
    monkeypatch.setattr(fs, "DELETE_FIELD", "DEL", raising=False)

    docs = [
        _Doc("s1", {"ingest_pending": True, "ingest_pending_at": 1,
                    "turns": [{"role": "user", "text": "a"}]}, None),
        _Doc("s2", {"ingest_pending": True, "ingest_pending_at": 2,
                    "turns": [{"role": "user", "text": "b"}]}, None),
        _Doc("s3", {"turns": [{"role": "user", "text": "c"}]}, None),  # not pending
    ]
    _, holder = _db(docs)

    class _DB2:
        def collection(self, _):
            return holder

    n = _run(backfill_ops.drain(_DB2(), "u1"))
    assert n == 2
    assert [c[1] for c in calls] == ["s1", "s2"]
    assert "ingest_pending" not in docs[0]._data
    assert "ingest_pending" not in docs[1]._data


def test_drain_stops_when_credits_run_out_again(monkeypatch):
    async def _boom(db, uid, sid, turns, **kw):
        raise token_ledger.TokenCapExceeded("still broke")

    monkeypatch.setattr(wiki_ingest, "ingest", _boom)
    import firebase_admin.firestore as fs
    monkeypatch.setattr(fs, "DELETE_FIELD", "DEL", raising=False)

    docs = [
        _Doc("s1", {"ingest_pending": True, "ingest_pending_at": 1,
                    "turns": [{"role": "user", "text": "a"}]}, None),
    ]
    _, holder = _db(docs)

    class _DB2:
        def collection(self, _):
            return holder

    n = _run(backfill_ops.drain(_DB2(), "u1"))
    assert n == 0
    assert docs[0]._data["ingest_pending"] is True  # left pending
