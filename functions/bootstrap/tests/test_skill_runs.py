import asyncio
import datetime

import pytest

import appearance
import auto_analysis
import deep_dive
import photo_attrs
import physical_attributes
import skill_memory
import skill_reports
import skill_runs
import token_ledger


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# --- fake Firestore (nested tuple-keyed store, with .limit / .add) -------------


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
        cur = self._store.docs.get(self._key, {}) if merge else {}
        cur.update(payload)
        self._store.docs[self._key] = cur
        self._store.writes.append((self._key, dict(payload), merge))

    def collection(self, name):
        return _CollRef(self._store, self._key + (name,))


class _CollRef:
    def __init__(self, store, key, limit=None):
        self._store = store
        self._key = key
        self._limit = limit

    def document(self, name):
        return _DocRef(self._store, self._key + (name,))

    def limit(self, n):
        return _CollRef(self._store, self._key, n)

    def add(self, payload):
        self._store.counter += 1
        doc_id = f"auto{self._store.counter}"
        key = self._key + (doc_id,)
        self._store.docs[key] = dict(payload)
        return (None, _Snap(doc_id, self._store.docs[key]))

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
        self.writes = []
        self.counter = 0

    def collection(self, name):
        return _CollRef(self, (name,))


@pytest.fixture(autouse=True)
def _server_ts(monkeypatch):
    import firebase_admin.firestore as fs

    monkeypatch.setattr(fs, "SERVER_TIMESTAMP", "TS", raising=False)


def _ledger(db, uid, skill):
    return db.docs.get(("users", uid, "skill_runs", skill))


# --- record / get_all --------------------------------------------------------


def test_record_and_get_all_round_trip():
    db = FakeDb()
    skill_runs.record(
        db, "u1", skill_runs.DEEP_DIVE,
        status="ok", source="user", detail="self",
    )
    skill_runs.record(
        db, "u1", skill_runs.FACE_REPORT,
        status="skipped", source="auto", detail="no_photo",
    )

    got = skill_runs.get_all(db, "u1")
    assert set(got) == {"deep_dive", "face_report"}
    assert got["deep_dive"]["last_status"] == "ok"
    assert got["deep_dive"]["source"] == "user"
    assert got["deep_dive"]["last_run_at"] == "TS"
    assert got["face_report"]["detail"] == "no_photo"


def test_record_ignores_an_unknown_skill():
    db = FakeDb()
    skill_runs.record(db, "u1", "astrology", status="ok", source="user")
    assert skill_runs.get_all(db, "u1") == {}


def test_record_is_best_effort_and_never_raises():
    class Boom:
        def collection(self, *a, **k):
            raise RuntimeError("firestore down")

    skill_runs.record(Boom(), "u1", skill_runs.DEEP_DIVE, status="ok", source="user")


# --- missing ---------------------------------------------------------------


def test_missing_is_every_skill_for_a_blank_user():
    db = FakeDb()
    assert skill_runs.missing(db, "u1") == list(skill_runs.ALL)


def test_missing_respects_a_ledger_doc():
    db = FakeDb()
    skill_runs.record(
        db, "u1", skill_runs.APPEARANCE,
        status="ok", source="auto",
    )
    assert "appearance" not in skill_runs.missing(db, "u1")


def test_missing_treats_a_legacy_photo_artifact_as_satisfying_appearance():
    db = FakeDb()
    # Artifacts from the pre-merge per-skill runs — no skill_runs docs at all.
    db.docs[("users", "u1", "deep_dives", "name_jane-doe")] = {"digest": {}}
    db.docs[("users", "u1", "face_reports", "r1")] = {"report": {}}
    db.docs[("users", "u1", "physical_attributes", "current")] = {"fields": {}}

    # deep_dive is satisfied by deep_dives/*, appearance by the legacy photo
    # reports — nothing left to run.
    assert skill_runs.missing(db, "u1") == []


def test_missing_needs_appearance_when_no_photo_artifact_exists():
    db = FakeDb()
    db.docs[("users", "u1", "deep_dives", "name_jane-doe")] = {"digest": {}}
    assert skill_runs.missing(db, "u1") == ["appearance"]


def test_missing_accepts_a_skill_subset():
    db = FakeDb()
    out = skill_runs.missing(db, "u1", skills=(skill_runs.APPEARANCE,))
    assert out == ["appearance"]


# --- stale ---------------------------------------------------------------


def test_stale_flags_runs_older_than_the_window():
    db = FakeDb()
    old = datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)
    fresh = datetime.datetime.now(datetime.timezone.utc)
    db.docs[("users", "u1", "skill_runs", "deep_dive")] = {
        "last_run_at": old, "last_status": "ok", "source": "auto",
    }
    db.docs[("users", "u1", "skill_runs", "face_report")] = {
        "last_run_at": fresh, "last_status": "ok", "source": "user",
    }
    assert skill_runs.stale(db, "u1") == ["deep_dive"]


# --- reconcile -----------------------------------------------------------


@pytest.fixture
def _mock_engines(monkeypatch):
    """Every skill entrypoint stubbed + the credit check open."""
    calls = {"appearance": 0, "deep_dive": 0}

    async def _appearance(db, uid, *, want_face=True, want_body=True,
                          source="user", extra_images=None):
        calls["appearance"] += 1
        return {"id": "a9", "attributes": {}, "face": {}, "body": {},
                "photo_count": 2, "source": source}

    async def _dive(name, *, db=None, uid=None, context="", is_self=False, **kw):
        calls["deep_dive"] += 1
        return {"name": name, "summary": "x", "confidence": "high",
                "facts": [], "links": []}

    monkeypatch.setattr(appearance, "run_appearance", _appearance)
    monkeypatch.setattr(
        photo_attrs, "coverage",
        lambda db, uid: {"has_face_photo": True, "has_body_photo": True},
    )
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "Jane Doe")
    monkeypatch.setattr(deep_dive, "profile_dive_context", lambda db, uid: "")
    monkeypatch.setattr(deep_dive, "run", _dive)
    monkeypatch.setattr(skill_memory, "save_web_findings", lambda *a, **k: None)
    monkeypatch.setattr(skill_memory, "promote", lambda *a, **k: True)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    return calls


def test_reconcile_runs_every_missing_skill_and_records_ok(_mock_engines):
    db = FakeDb()
    res = _run(skill_runs.reconcile(db, "u1"))

    assert set(res["ran"]) == set(skill_runs.ALL)
    assert res["skipped"] == {} and res["errors"] == 0
    for skill in skill_runs.ALL:
        assert _ledger(db, "u1", skill)["last_status"] == "ok"
        assert _ledger(db, "u1", skill)["source"] == "auto"
    assert _mock_engines["appearance"] == 1
    assert _mock_engines["deep_dive"] == 1


def test_reconcile_user_limit_takes_the_lighter_one_only(_mock_engines):
    db = FakeDb()
    res = _run(skill_runs.reconcile(db, "u1", user_limit=1))

    assert list(res["ran"]) == ["deep_dive"]
    assert _ledger(db, "u1", "appearance") is None
    assert _mock_engines["appearance"] == 0


def test_reconcile_records_skipped_for_no_name(monkeypatch, _mock_engines):
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "")
    db = FakeDb()
    # only deep_dive is missing
    skill_runs.record(db, "u1", skill_runs.APPEARANCE, status="ok", source="user")

    res = _run(skill_runs.reconcile(db, "u1"))
    assert res["skipped"] == {"deep_dive": "no_name"}
    assert _ledger(db, "u1", "deep_dive")["last_status"] == "skipped"
    assert _ledger(db, "u1", "deep_dive")["detail"] == "no_name"


def test_reconcile_records_skipped_for_no_photo(monkeypatch, _mock_engines):
    async def _none(db, uid, *, want_face=True, want_body=True, source="user",
                    extra_images=None):
        return None

    monkeypatch.setattr(appearance, "run_appearance", _none)
    db = FakeDb()
    skill_runs.record(db, "u1", skill_runs.DEEP_DIVE, status="ok", source="user")

    res = _run(skill_runs.reconcile(db, "u1"))
    assert res["skipped"] == {"appearance": "no_photo"}


def test_reconcile_records_skipped_capped_when_out_of_credits(monkeypatch,
                                                             _mock_engines):
    def _boom(uid):
        raise token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(token_ledger, "check", _boom)
    db = FakeDb()
    res = _run(skill_runs.reconcile(db, "u1"))

    assert set(res["skipped"]) == set(skill_runs.ALL)
    assert all(v == "capped" for v in res["skipped"].values())
    assert _ledger(db, "u1", "deep_dive")["detail"] == "capped"
    assert _mock_engines["appearance"] == 0  # nothing actually ran


def test_reconcile_records_error_and_never_aborts_the_batch(monkeypatch,
                                                            _mock_engines):
    async def _explode(db, uid, *, want_face=True, want_body=True,
                       source="user", extra_images=None):
        raise RuntimeError("gemini 500")

    monkeypatch.setattr(appearance, "run_appearance", _explode)
    db = FakeDb()
    res = _run(skill_runs.reconcile(db, "u1"))

    assert res["errors"] == 1
    assert _ledger(db, "u1", "appearance")["last_status"] == "error"
    assert "gemini 500" in _ledger(db, "u1", "appearance")["detail"]
    # the rest of the batch still ran
    assert "deep_dive" in res["ran"]


def test_reconcile_is_a_noop_when_nothing_is_missing(_mock_engines):
    db = FakeDb()
    for s in skill_runs.ALL:
        skill_runs.record(db, "u1", s, status="ok", source="user")
    res = _run(skill_runs.reconcile(db, "u1"))
    assert res["ran"] == {} and res["skipped"] == {}


# --- sweep -------------------------------------------------------------


def test_sweep_reconciles_every_user(_mock_engines):
    db = FakeDb()
    db.docs[("users", "u1")] = {}
    db.docs[("users", "u2")] = {}
    db.docs[("users", "u3")] = {}

    res = _run(skill_runs.sweep(db, user_limit=2))
    assert res["users"] == 2
    assert res["ran"]["deep_dive"] == 2
    assert res["ran"]["appearance"] == 2


# --- run_report (headless face/body) ---------------------------------------


def test_run_report_writes_the_report_doc_and_wiki_section(monkeypatch):
    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {
        "photos": [{"media_id": "m1", "order": 0}],
    }
    db.docs[("users", "u1", "user_media", "m1")] = {"storage_path": "s/1.jpg"}

    monkeypatch.setattr(
        skill_reports.media_embed, "download_bytes",
        lambda path: (b"jpegbytes", "image/jpeg"),
    )

    _FACE = {
        "usable": True, "overall_score": 7.1, "verdict": "Above average",
        "verdict_note": "", "features": [], "quick_facts": {},
        "strengths": ["Good jaw"], "improvements": [], "recommendations": [],
    }

    async def _engine_run(image_bytes, mime, *, uid=None):
        assert image_bytes == b"jpegbytes"
        return dict(_FACE)

    monkeypatch.setattr(skill_reports.face_report, "run", _engine_run)

    res = _run(skill_reports.run_report(db, "u1", "face"))
    assert res["usable"] is True and res["report_id"]

    # the {kind}_reports doc
    stored = [k for k in db.docs if k[:3] == ("users", "u1", "face_reports")]
    assert len(stored) == 1
    assert db.docs[stored[0]]["source"] == "auto"

    # the private wiki section, promoted (no-op — already private) for a self run
    page = db.docs.get(("users", "u1", "wiki_pages", "face-analysis"))
    assert page is not None
    assert "7.1/10" in page["ai_body"]
    assert page["visibility"] == "private"  # default, and promoted keeps it so


def test_run_report_returns_none_without_a_profile_photo():
    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {"photos": []}
    assert _run(skill_reports.run_report(db, "u1", "body")) is None


def test_run_report_rejects_a_bad_kind():
    db = FakeDb()
    with pytest.raises(ValueError):
        _run(skill_reports.run_report(db, "u1", "hair"))


# --- record() wired into the skill completion paths -----------------------


def test_physical_attributes_refresh_records_ok(monkeypatch):
    db = FakeDb()
    db.docs[("users", "u1", "profile", "main")] = {
        "photos": [{"media_id": "m1", "order": 0}],
    }

    monkeypatch.setattr(
        physical_attributes, "gather_profile_images",
        lambda db, uid: [(b"x", "image/jpeg")],
    )

    async def _extract(images, *, uid=None):
        return {f: {"value": physical_attributes._blank_value(f),
                    "confidence": "low"} for f in physical_attributes.fields()}

    monkeypatch.setattr(physical_attributes, "extract_from_photos", _extract)
    monkeypatch.setattr(physical_attributes, "resolve_stated", lambda db, uid: {})

    _run(physical_attributes.refresh(db, "u1", persist_report=False))
    rec = _ledger(db, "u1", "physical_attributes")
    assert rec["last_status"] == "ok"
    assert rec["source"] == "auto"


def test_physical_attributes_refresh_records_skipped_without_photos(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(
        physical_attributes, "gather_profile_images", lambda db, uid: []
    )
    _run(physical_attributes.refresh(db, "u1", persist_report=True))
    rec = _ledger(db, "u1", "physical_attributes")
    assert rec["last_status"] == "skipped"
    assert rec["detail"] == "no_photos"
    assert rec["source"] == "user"


def test_auto_analysis_web_dive_records_deep_dive(monkeypatch):
    db = FakeDb()

    async def _dive(name, **kw):
        return {"name": name, "summary": "s", "confidence": "high",
                "facts": [], "links": []}

    monkeypatch.setattr(auto_analysis.deep_dive, "profile_full_name",
                        lambda db, uid: "Jane Doe")
    monkeypatch.setattr(auto_analysis.deep_dive, "profile_dive_context",
                        lambda db, uid: "")
    monkeypatch.setattr(auto_analysis.deep_dive, "run", _dive)
    monkeypatch.setattr(auto_analysis.skill_memory, "save_web_findings",
                        lambda *a, **k: None)

    _run(auto_analysis.analyse_web(db, "u1"))
    rec = _ledger(db, "u1", "deep_dive")
    assert rec["last_status"] == "ok"
    assert rec["source"] == "auto"
    assert rec["detail"] == "auto_analysis"
