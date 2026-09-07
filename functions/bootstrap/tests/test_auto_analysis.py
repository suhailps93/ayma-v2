"""Auto-analysis (§ auto analysis): face/body on every own photo, one web dive."""

import asyncio

import auto_analysis
import body_report
import deep_dive
import face_report
import media_embed
import skill_memory
import token_ledger


def _run(coro):
    # A dedicated loop per call — never touches the process-wide current loop
    # that other test modules' `asyncio.get_event_loop()` helpers rely on.
    return asyncio.new_event_loop().run_until_complete(coro)


# --- fake Firestore (nested tuple-keyed store) ------------------------------


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data or {})


class _DocRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def get(self):
        return _Snap(self._key[-1], self._store.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._store.docs.get(self._key, {})) if merge else {}
        cur.update(payload)
        self._store.docs[self._key] = cur

    def collection(self, name):
        return _CollRef(self._store, self._key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def document(self, name):
        return _DocRef(self._store, self._key + (name,))


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


_FACE = {
    "usable": True,
    "overall_score": 6.9,
    "verdict": "Above average",
    "verdict_note": "Strong eyes.",
    "features": [{"name": "eyes", "score": 8.0, "note": "Well spaced."}],
    "strengths": ["Expressive eyes"],
    "improvements": ["Even skin"],
    "recommendations": [],
}

_BODY = {
    "usable": True,
    "overall_score": 6.4,
    "verdict": "Solid base",
    "features": [{"name": "posture", "score": 6.0, "note": "Forward head."}],
    "strengths": ["Shoulder width"],
    "improvements": ["Calves"],
    "recommendations": [],
}

_DIGEST = {
    "summary": "Runs a bakery in Porto.",
    "confidence": "medium",
    "facts": [],
    "links": [],
}


def _stub_engines(monkeypatch, face=_FACE, body=_BODY):
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda _sp: (b"imgbytes", "image/jpeg")
    )

    async def _face_run(_b, _m, *, uid=None):
        return dict(face)

    async def _body_run(_b, _m, *, uid=None):
        return dict(body)

    monkeypatch.setattr(face_report, "run", _face_run)
    monkeypatch.setattr(body_report, "run", _body_run)


# --- analyse_photo --------------------------------------------------------


def test_analyse_photo_merges_usable_reads_into_ai_only_pages(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)

    _run(auto_analysis.analyse_photo(db, "u1", "uploads/u1/a.jpg"))

    face = db.docs[("users", "u1", "wiki_pages", "face-analysis")]
    body = db.docs[("users", "u1", "wiki_pages", "body-analysis")]
    assert face["visibility"] == "ai_only"
    assert face["page_type"] == "face_analysis"
    assert face["ai_body"].startswith("Latest read:")
    assert "6.9/10" in face["ai_body"]
    assert len(face["reads"]) == 1
    assert body["visibility"] == "ai_only"
    assert "6.4/10" in body["ai_body"]


def test_analyse_photo_skips_the_unusable_engine(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch, face={"usable": False})

    _run(auto_analysis.analyse_photo(db, "u1", "uploads/u1/a.jpg"))

    assert ("users", "u1", "wiki_pages", "face-analysis") not in db.docs
    assert ("users", "u1", "wiki_pages", "body-analysis") in db.docs


def test_analyse_photo_accumulates_across_photos(monkeypatch):
    db = FakeDb()
    _stub_engines(monkeypatch)

    _run(auto_analysis.analyse_photo(db, "u1", "a.jpg"))
    _run(auto_analysis.analyse_photo(db, "u1", "b.jpg"))

    face = db.docs[("users", "u1", "wiki_pages", "face-analysis")]
    assert len(face["reads"]) == 2
    assert "Earlier reads from other photos" in face["ai_body"]


def test_analyse_photo_never_raises_on_engine_failure(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda _sp: (b"x", "image/jpeg")
    )

    async def _boom(*_a, **_k):
        raise RuntimeError("gemini down")

    monkeypatch.setattr(face_report, "run", _boom)
    monkeypatch.setattr(body_report, "run", _boom)

    _run(auto_analysis.analyse_photo(db, "u1", "a.jpg"))  # no raise
    assert db.docs == {}


def test_analyse_photo_skips_quietly_on_the_credit_cap(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda _sp: (b"x", "image/jpeg")
    )

    async def _capped(*_a, **_k):
        raise token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(face_report, "run", _capped)
    monkeypatch.setattr(body_report, "run", _capped)

    _run(auto_analysis.analyse_photo(db, "u1", "a.jpg"))  # no raise
    assert db.docs == {}


def test_analyse_photo_is_a_noop_without_a_path():
    db = FakeDb()
    _run(auto_analysis.analyse_photo(db, "u1", ""))
    assert db.docs == {}


# --- analyse_web -------------------------------------------------------------


def test_analyse_web_runs_once_sets_the_flag_and_is_a_noop_after(monkeypatch):
    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {
        "first_name": "Ana", "last_name": "Reis",
    }
    monkeypatch.setattr(auto_analysis.firestore, "SERVER_TIMESTAMP", "TS")

    calls = []

    async def _dive(name, *, uid=None, context="", is_self=False):
        calls.append((name, uid, is_self))
        return dict(_DIGEST)

    monkeypatch.setattr(deep_dive, "run", _dive)

    _run(auto_analysis.analyse_web(db, "u1"))

    assert calls == [("Ana Reis", "u1", True)]
    assert db.docs[("users", "u1")]["auto_dive_done"] is True
    assert db.docs[("users", "u1")]["auto_dive_at"] == "TS"
    assert ("users", "u1", "wiki_pages", "web-findings") in db.docs

    calls.clear()
    _run(auto_analysis.analyse_web(db, "u1"))
    assert calls == []


def test_analyse_web_leaves_the_flag_unset_when_there_is_no_name(monkeypatch):
    db = FakeDb()  # no profile doc -> no name

    called = []

    async def _dive(*_a, **_k):
        called.append(1)
        return {}

    monkeypatch.setattr(deep_dive, "run", _dive)

    _run(auto_analysis.analyse_web(db, "u1"))

    assert called == []
    assert ("users", "u1") not in db.docs


def test_analyse_web_never_raises_when_the_dive_fails(monkeypatch):
    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {"name": "Sam Okafor"}

    async def _boom(*_a, **_k):
        raise RuntimeError("research upstream 500")

    monkeypatch.setattr(deep_dive, "run", _boom)

    _run(auto_analysis.analyse_web(db, "u1"))  # no raise
    assert ("users", "u1") not in db.docs  # flag not set -> retries later
