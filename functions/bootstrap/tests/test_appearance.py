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
            {"bytes": b"g1", "mime": "image/jpeg", "path": "uploads/u1/g1.jpg",
             "attrs": {"usable_for_face": True, "usable_for_body": True}},
        ],
    )

    async def _pa_refresh(db, uid, *, persist_report=False, **kw):
        seen["pa"] += 1
        return {
            "fields": _PA_FIELDS, "report_id": "pr1", "photo_count": 1,
            "photo_paths": ["uploads/u1/g1.jpg"],
        }

    monkeypatch.setattr(appearance.physical_attributes, "refresh", _pa_refresh)
    monkeypatch.setattr(
        appearance.physical_attributes, "summary",
        lambda fields: "Physical profile — eyes: brown.",
    )

    async def _face_run(b, m, *, uid=None, source_path=None):
        seen["face"] += 1
        return {**_FACE, "source_photos": [source_path] if source_path else []}

    async def _body_run(b, m, *, uid=None, source_path=None):
        seen["body"] += 1
        return {**_BODY, "source_photos": [source_path] if source_path else []}

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
    assert rep["attributes"]["source_photos"] == ["uploads/u1/g1.jpg"]
    assert rep["face"]["overall_score"] == 7.1
    assert rep["face"]["source_photos"] == ["uploads/u1/g1.jpg"]
    assert rep["body"]["overall_score"] == 6.4
    assert rep["body"]["source_photos"] == ["uploads/u1/g1.jpg"]
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
        appearance.run_appearance(
            db, "u1",
            extra_images=[(b"chatpic", "image/png", "uploads/u1/chat.jpg")],
        )
    )
    assert rep is not None
    assert rep["face"]["overall_score"] == 7.1
    assert rep["body"]["overall_score"] == 6.4
    assert rep["face"]["source_photos"] == ["uploads/u1/chat.jpg"]
    assert rep["body"]["source_photos"] == ["uploads/u1/chat.jpg"]


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


# --- record_background_result (§ appearance / auto_analysis) ----------------


def test_record_background_result_stamps_current_pointer(_mocks):
    db = FakeDb()
    db.docs[("users", "u1", "physical_attributes", "current")] = {
        "fields": _PA_FIELDS, "photo_count": 2,
    }
    rid = appearance.record_background_result(db, "u1", face=dict(_FACE))
    assert rid

    ptr = appearance.current(db, "u1")
    assert ptr and ptr["report_id"] == rid

    rep = appearance.get_report(db, "u1", "current")
    assert rep["face"]["overall_score"] == 7.1
    assert rep["body"] == appearance.NEEDS_BODY  # nothing to reuse yet
    assert rep["attributes"]["record"] == _PA_FIELDS
    assert rep["source"] == "auto"


def test_record_background_result_does_not_regress_the_untouched_part(_mocks):
    db = FakeDb()
    db.docs[("users", "u1", "physical_attributes", "current")] = {
        "fields": _PA_FIELDS, "photo_count": 1,
    }

    # First an auto face-only run ...
    appearance.record_background_result(db, "u1", face=dict(_FACE))
    # ... then a later auto body-only run must not wipe the face section back
    # to "needs_face_photo".
    rid2 = appearance.record_background_result(db, "u1", body=dict(_BODY))

    rep = appearance.get_report(db, "u1", "current")
    assert rep["id"] == rid2
    assert rep["face"]["overall_score"] == 7.1  # reused, not regressed
    assert rep["body"]["overall_score"] == 6.4


def test_record_background_result_is_a_noop_without_face_or_body(_mocks):
    db = FakeDb()
    assert appearance.record_background_result(db, "u1") == ""
    assert db.docs == {}


def test_record_background_result_never_raises_on_lookup_or_store_failure(
    monkeypatch, _mocks
):
    db = FakeDb()

    def _boom(*_a, **_k):
        raise RuntimeError("firestore down")

    monkeypatch.setattr(appearance.physical_attributes, "current", _boom)
    monkeypatch.setattr(appearance, "_store", _boom)

    # Must not raise, and must return "" since nothing could be stored.
    assert appearance.record_background_result(db, "u1", face=dict(_FACE)) == ""


# --- score --------------------------------------------------------------------


def test_compute_score_averages_face_and_body():
    score = appearance._compute_score(_FACE, _BODY)
    assert score["value"] == pytest.approx(round((7.1 + 6.4) / 2, 1))
    assert "face" in score["basis"] and "body" in score["basis"]


def test_compute_score_uses_whichever_side_is_available():
    score = appearance._compute_score(_FACE, {"status": "needs_body_photo"})
    assert score["value"] == 7.1


def test_compute_score_none_without_any_read():
    score = appearance._compute_score(
        {"status": "needs_face_photo"}, {"status": "needs_body_photo"}
    )
    assert score["value"] is None and score["basis"]


def test_run_appearance_includes_score(_mocks):
    db = FakeDb()
    rep = _run(appearance.run_appearance(db, "u1"))
    assert rep["score"]["value"] == pytest.approx(round((7.1 + 6.4) / 2, 1))


def test_shape_computes_score_for_a_legacy_report_missing_it():
    # A report stored before `score` existed still gets one on read.
    rep = appearance._shape("a1", {"face": _FACE, "body": _BODY})
    assert rep["score"]["value"] == pytest.approx(round((7.1 + 6.4) / 2, 1))
    assert rep["finding_history"] == {}


# --- correct_finding (§ appearance corrections) ------------------------------
#
# `FakeDb`/`_DocRef.set` above only does a *shallow* dict.update on `merge`,
# but `correct_finding` relies on real Firestore's nested field-path merge
# (e.g. writing `attributes.record.<field>` without clobbering
# `attributes.summary`). A small deep-merging variant models that accurately
# for these tests without touching the shared shallow fake every other test
# in this file already depends on.


def _deep_merge(base: dict, patch: dict) -> dict:
    out = dict(base)
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


class _MergeDocRef(_DocRef):
    def set(self, payload, merge=False):
        cur = self._store.docs.get(self._key, {}) if merge else {}
        self._store.docs[self._key] = (
            _deep_merge(cur, payload) if merge else dict(payload)
        )

    def collection(self, name):
        return _MergeCollRef(self._store, self._key + (name,))


class _MergeCollRef(_CollRef):
    def document(self, name):
        return _MergeDocRef(self._store, self._key + (name,))


class MergeFakeDb(FakeDb):
    def collection(self, name):
        return _MergeCollRef(self, (name,))


def _seed_current_report(db, uid, report_id, doc):
    db.docs[("users", uid, "appearance", "current")] = {"report_id": report_id}
    db.docs[("users", uid, "appearance_reports", report_id)] = doc


def test_correct_finding_attribute_updates_value_everywhere(monkeypatch):
    db = MergeFakeDb()
    _seed_current_report(db, "u1", "r1", {
        "attributes": {
            "summary": "Physical profile — eyes: brown.",
            "record": {
                "eye_color": {"value": "brown", "source": "photo",
                              "confidence": "medium", "note": "from pics"},
            },
            "source_photos": ["uploads/u1/a.jpg"],
        },
        "face": {"status": "needs_face_photo"},
        "body": {"status": "needs_body_photo"},
    })
    db.docs[("users", "u1", "physical_attributes", "current")] = {
        "fields": {"eye_color": {"value": "brown", "source": "photo",
                                  "confidence": "medium"}},
    }

    async def _json(contents, system_prompt, response_schema=None, **kw):
        assert "eyes" in contents.lower()
        return {"value": "blue", "reply": "Updated your eyes to blue."}

    monkeypatch.setattr(appearance.gemini, "generate_json", _json)

    result = _run(appearance.correct_finding(db, "u1", "eye_color", "they're blue"))
    assert result == {
        "finding_id": "eye_color", "value": "blue",
        "reply": "Updated your eyes to blue.",
    }

    # profile/main stated field always wins future re-runs
    assert db.docs[("users", "u1", "profile", "main")]["eye_color"] == "blue"
    # physical_attributes/current field record updated
    pa = db.docs[("users", "u1", "physical_attributes", "current")]
    assert pa["fields"]["eye_color"]["value"] == "blue"
    assert pa["fields"]["eye_color"]["source"] == "stated"
    # the SAME report doc updated in place, sibling data untouched
    rep = db.docs[("users", "u1", "appearance_reports", "r1")]
    assert rep["attributes"]["record"]["eye_color"]["value"] == "blue"
    assert rep["attributes"]["record"]["eye_color"]["source"] == "stated"
    assert rep["attributes"]["summary"] == "Physical profile — eyes: brown."
    # finding_history recorded
    hist = rep["finding_history"]["eye_color"]
    assert len(hist) == 1 and hist[0]["value"] == "blue"
    assert hist[0]["photo_ids"] == ["uploads/u1/a.jpg"]
    assert hist[0]["changed_at_ms"]


def test_correct_finding_attribute_no_change_writes_nothing(monkeypatch):
    db = MergeFakeDb()
    _seed_current_report(db, "u1", "r1", {
        "attributes": {"record": {
            "eye_color": {"value": "brown", "source": "photo", "confidence": "medium"},
        }},
        "face": {"status": "needs_face_photo"},
        "body": {"status": "needs_body_photo"},
    })

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return {"value": "no_change", "reply": "Not sure what to change that to."}

    monkeypatch.setattr(appearance.gemini, "generate_json", _json)

    result = _run(appearance.correct_finding(db, "u1", "eye_color", "hmm what?"))
    assert result["value"] == "brown"
    assert ("users", "u1", "profile", "main") not in db.docs


def test_correct_finding_face_revises_verdict_note(monkeypatch):
    db = MergeFakeDb()
    _seed_current_report(db, "u1", "r1", {
        "attributes": {"record": {}},
        "face": {**_FACE, "verdict_note": "Strong jawline.",
                 "source_photos": ["uploads/u1/face.jpg"]},
        "body": {"status": "needs_body_photo"},
    })

    async def _json(contents, system_prompt, response_schema=None, **kw):
        assert "face" in system_prompt
        return {"changed": True, "verdict_note": "Warm smile.",
                "reply": "Noted — updated the note."}

    monkeypatch.setattr(appearance.gemini, "generate_json", _json)

    result = _run(appearance.correct_finding(db, "u1", "face", "I have a warm smile"))
    assert result == {
        "finding_id": "face", "value": "Warm smile.",
        "reply": "Noted — updated the note.",
    }
    rep = db.docs[("users", "u1", "appearance_reports", "r1")]
    assert rep["face"]["verdict_note"] == "Warm smile."
    assert rep["face"]["overall_score"] == 7.1  # untouched
    assert rep["finding_history"]["face"][0]["photo_ids"] == ["uploads/u1/face.jpg"]


def test_correct_finding_caps_history_at_eight(monkeypatch):
    db = MergeFakeDb()
    old_history = [
        {"value": f"v{i}", "changed_at_ms": i} for i in range(8)
    ]
    _seed_current_report(db, "u1", "r1", {
        "attributes": {"record": {
            "eye_color": {"value": "v7", "source": "stated", "confidence": "high"},
        }},
        "finding_history": {"eye_color": old_history},
        "face": {"status": "needs_face_photo"},
        "body": {"status": "needs_body_photo"},
    })

    async def _json(contents, system_prompt, response_schema=None, **kw):
        return {"value": "green", "reply": "Updated."}

    monkeypatch.setattr(appearance.gemini, "generate_json", _json)
    _run(appearance.correct_finding(db, "u1", "eye_color", "green now"))

    rep = db.docs[("users", "u1", "appearance_reports", "r1")]
    hist = rep["finding_history"]["eye_color"]
    assert len(hist) == 8
    assert hist[-1]["value"] == "green"
    assert hist[0]["value"] == "v1"  # oldest (v0) dropped


def test_correct_finding_unknown_id_raises_value_error():
    db = MergeFakeDb()
    with pytest.raises(ValueError):
        _run(appearance.correct_finding(db, "u1", "not_a_field", "hi"))


def test_correct_finding_blank_message_raises_value_error():
    db = MergeFakeDb()
    with pytest.raises(ValueError):
        _run(appearance.correct_finding(db, "u1", "eye_color", "   "))


def test_correct_finding_no_current_report_returns_none():
    db = MergeFakeDb()
    assert _run(appearance.correct_finding(db, "u1", "eye_color", "blue")) is None


def test_correct_finding_propagates_token_cap(monkeypatch):
    import token_ledger

    db = MergeFakeDb()
    _seed_current_report(db, "u1", "r1", {
        "attributes": {"record": {}},
        "face": {"status": "needs_face_photo"},
        "body": {"status": "needs_body_photo"},
    })

    async def _boom(*a, **k):
        raise token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(appearance.gemini, "generate_json", _boom)
    with pytest.raises(token_ledger.TokenCapExceeded):
        _run(appearance.correct_finding(db, "u1", "eye_color", "blue"))
