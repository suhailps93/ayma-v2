import asyncio

import pytest

import appearance
import skill_runs


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# --- fake Firestore (nested tuple-keyed, with .add / .limit / .stream) --------


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _DocRef:
    def __init__(self, store, key):
        self._store, self._key = store, key

    def get(self):
        return _Snap(self._key[-1], self._store.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = self._store.docs.get(self._key, {}) if merge else {}
        cur.update(payload)
        self._store.docs[self._key] = cur

    def collection(self, name):
        return _CollRef(self._store, self._key + (name,))


class _CollRef:
    def __init__(self, store, key, limit=None):
        self._store, self._key, self._limit = store, key, limit

    def document(self, name):
        return _DocRef(self._store, self._key + (name,))

    def limit(self, n):
        return _CollRef(self._store, self._key, n)

    def add(self, payload):
        self._store.counter += 1
        doc_id = f"auto{self._store.counter}"
        self._store.docs[self._key + (doc_id,)] = dict(payload)
        return (None, _Snap(doc_id, self._store.docs[self._key + (doc_id,)]))

    def stream(self):
        depth = len(self._key)
        hits = [
            _Snap(k[-1], v)
            for k, v in self._store.docs.items()
            if len(k) == depth + 1 and k[:depth] == self._key and v is not None
        ]
        return hits[: self._limit] if self._limit else hits


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.counter = 0

    def collection(self, name):
        return _CollRef(self, (name,))


@pytest.fixture(autouse=True)
def _server_ts(monkeypatch):
    import firebase_admin.firestore as fs

    monkeypatch.setattr(fs, "SERVER_TIMESTAMP", "TS", raising=False)


_FACE = {
    "usable": True, "overall_score": 7.1, "verdict": "Above average",
    "verdict_note": "", "features": [], "quick_facts": {},
    "strengths": ["Good eyes"], "improvements": [], "recommendations": [],
}
_BODY = {
    "usable": True, "overall_score": 6.4, "verdict": "Average",
    "verdict_note": "", "features": [], "quick_facts": {},
    "strengths": [], "improvements": ["Posture"], "recommendations": [],
}
_PA_FIELDS = {"eye_color": {"value": "brown", "source": "photo",
                            "confidence": "medium", "note": "from pics"}}


@pytest.fixture
def _mocks(monkeypatch):
    seen = {"face": 0, "body": 0, "pa": 0,
            "save_face": 0, "save_body": 0, "promote": []}

    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"g1", "mime": "image/jpeg",
             "attrs": {"usable_for_face": True, "usable_for_body": True}},
        ],
    )

    async def _pa_refresh(db, uid, *, persist_report=False, **kw):
        seen["pa"] += 1
        return {"fields": _PA_FIELDS, "report_id": "pr1", "photo_count": 1}

    monkeypatch.setattr(appearance.physical_attributes, "refresh", _pa_refresh)
    monkeypatch.setattr(
        appearance.physical_attributes, "summary",
        lambda fields: "Physical profile — eyes: brown.",
    )

    async def _face_run(b, m, *, uid=None):
        seen["face"] += 1
        return dict(_FACE)

    async def _body_run(b, m, *, uid=None):
        seen["body"] += 1
        return dict(_BODY)

    monkeypatch.setattr(appearance.face_report, "run", _face_run)
    monkeypatch.setattr(appearance.body_report, "run", _body_run)
    monkeypatch.setattr(
        appearance.skill_memory, "save_face_analysis",
        lambda *a, **k: seen.__setitem__("save_face", seen["save_face"] + 1),
    )
    monkeypatch.setattr(
        appearance.skill_memory, "save_body_analysis",
        lambda *a, **k: seen.__setitem__("save_body", seen["save_body"] + 1),
    )
    monkeypatch.setattr(
        appearance.skill_memory, "promote",
        lambda db, uid, pt: seen["promote"].append(pt),
    )
    return seen


def test_run_produces_all_three_sections(_mocks):
    db = FakeDb()
    rep = _run(appearance.run_appearance(db, "u1"))

    assert rep["attributes"]["record"] == _PA_FIELDS
    assert rep["attributes"]["summary"].startswith("Physical profile")
    assert rep["face"]["overall_score"] == 7.1
    assert rep["body"]["overall_score"] == 6.4
    assert rep["photo_count"] == 1
    assert rep["id"]

    # report doc + current pointer
    stored = [k for k in db.docs if k[:3] == ("users", "u1", "appearance_reports")]
    assert len(stored) == 1
    ptr = db.docs.get(("users", "u1", "appearance", "current"))
    assert ptr and ptr["report_id"] == rep["id"]

    # wiki sections written + promoted for a self run
    assert _mocks["save_face"] == 1 and _mocks["save_body"] == 1
    assert set(_mocks["promote"]) == {"face_analysis", "body_analysis"}

    # skill-run ledger
    led = db.docs.get(("users", "u1", "skill_runs", "appearance"))
    assert led and led["last_status"] == "ok"


def test_needs_face_photo_when_no_usable_face_shot(monkeypatch, _mocks):
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"g1", "mime": "image/jpeg",
             "attrs": {"usable_for_face": False, "usable_for_body": True}},
        ],
    )
    db = FakeDb()
    rep = _run(appearance.run_appearance(db, "u1"))
    assert rep["face"] == {"status": "needs_face_photo"}
    assert rep["body"]["overall_score"] == 6.4
    assert _mocks["face"] == 0
    assert _mocks["save_face"] == 0  # no wiki write for a section not produced
    assert _mocks["promote"] == ["body_analysis"]


def test_want_flags_gate_the_passes(_mocks):
    db = FakeDb()
    rep = _run(
        appearance.run_appearance(db, "u1", want_face=False, want_body=False)
    )
    assert rep["face"] == {"status": "needs_face_photo"}
    assert rep["body"] == {"status": "needs_body_photo"}
    assert _mocks["face"] == 0 and _mocks["body"] == 0
    # attributes still produced
    assert rep["attributes"]["record"] == _PA_FIELDS


def test_returns_none_and_records_skipped_without_photos(monkeypatch, _mocks):
    monkeypatch.setattr(appearance, "_grid_photos", lambda db, uid: [])
    db = FakeDb()
    assert _run(appearance.run_appearance(db, "u1")) is None
    led = db.docs.get(("users", "u1", "skill_runs", "appearance"))
    assert led and led["last_status"] == "skipped" and led["detail"] == "no_photo"


def test_extra_images_are_face_body_fallback(monkeypatch, _mocks):
    monkeypatch.setattr(appearance, "_grid_photos", lambda db, uid: [])
    db = FakeDb()
    rep = _run(
        appearance.run_appearance(db, "u1", extra_images=[(b"chatpic", "image/png")])
    )
    assert rep is not None
    assert rep["face"]["overall_score"] == 7.1
    assert rep["body"]["overall_score"] == 6.4


def test_get_report_current_and_by_id(_mocks):
    db = FakeDb()
    rep = _run(appearance.run_appearance(db, "u1"))
    by_id = appearance.get_report(db, "u1", rep["id"])
    assert by_id["id"] == rep["id"] and by_id["face"]["overall_score"] == 7.1
    cur = appearance.get_report(db, "u1", "current")
    assert cur["id"] == rep["id"]
    assert appearance.get_report(db, "u1", "nope") is None


def test_history_merges_legacy_collections(_mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))
    db.docs[("users", "u1", "face_reports", "f1")] = {
        "report": {"usable": True, "overall_score": 5.0, "verdict": "Average"},
        "created_at": "2000-01-01",
    }
    db.docs[("users", "u1", "physical_reports", "p1")] = {
        "summary": "Physical profile — old.", "created_at": "1999-01-01",
    }
    rows = appearance.history(db, "u1")
    kinds = [r["kind"] for r in rows]
    assert "appearance" in kinds and "face" in kinds and "physical" in kinds
    legacy = [r for r in rows if r["legacy"]]
    assert {r["kind"] for r in legacy} == {"face", "physical"}
    # newest first — the fresh appearance run (TS) sorts above the dated legacy
    assert rows[0]["kind"] == "appearance"


def test_missing_treats_appearance_current_as_satisfying():
    db = FakeDb()
    db.docs[("users", "u1", "appearance", "current")] = {"report_id": "a1"}
    assert "appearance" not in skill_runs.missing(db, "u1")
