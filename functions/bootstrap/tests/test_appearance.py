import asyncio

import pytest

import appearance
import skill_runs


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# --- fake Firestore (nested tuple-keyed, with .add / .delete / .limit / .stream) --


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


_DELETE = object()


class _DocRef:
    def __init__(self, store, key):
        self._store, self._key = store, key

    def get(self):
        return _Snap(self._key[-1], self._store.docs.get(self._key))

    def set(self, payload, merge=False):
        cur = self._store.docs.get(self._key, {}) if merge else {}
        cur = dict(cur or {})
        for k, v in payload.items():
            if v is _DELETE:
                cur.pop(k, None)
            else:
                cur[k] = v
        self._store.docs[self._key] = cur

    def delete(self):
        self._store.docs.pop(self._key, None)

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
            for k, v in list(self._store.docs.items())
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
    monkeypatch.setattr(fs, "DELETE_FIELD", _DELETE, raising=False)


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
_PA_FIELDS = {
    "eye_color": {"value": "brown", "source": "photo", "confidence": "medium",
                  "note": "from pics", "photo_ids": ["uploads/u1/g1.jpg"]},
}


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
    assert rep["id"] == "current"
    assert rep["score"] == {"value": 6.8, "basis": "face+body"}

    # exactly ONE doc, at the fixed id -- not a fresh auto-id per run.
    stored = [k for k in db.docs if k[:3] == ("users", "u1", "appearance_reports")]
    assert stored == [("users", "u1", "appearance_reports", "current")]
    ptr = db.docs.get(("users", "u1", "appearance", "current"))
    assert ptr and ptr["report_id"] == "current"

    # wiki sections written + promoted for a self run
    assert _mocks["save_face"] == 1 and _mocks["save_body"] == 1
    assert set(_mocks["promote"]) == {"face_analysis", "body_analysis"}

    # skill-run ledger
    led = db.docs.get(("users", "u1", "skill_runs", "appearance"))
    assert led and led["last_status"] == "ok"


def test_running_twice_never_creates_a_second_doc(_mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))
    _run(appearance.run_appearance(db, "u1"))
    stored = [k for k in db.docs if k[:3] == ("users", "u1", "appearance_reports")]
    assert stored == [("users", "u1", "appearance_reports", "current")]


def test_purges_a_leftover_pre_fix_auto_id_doc(_mocks):
    db = FakeDb()
    # A doc left over from the old "new doc per run" architecture.
    db.docs[("users", "u1", "appearance_reports", "auto7")] = {"stale": True}
    _run(appearance.run_appearance(db, "u1"))
    stored = {k for k in db.docs if k[:3] == ("users", "u1", "appearance_reports")}
    assert stored == {("users", "u1", "appearance_reports", "current")}


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
    assert rep["score"] == {"value": 6.4, "basis": "body"}


def test_body_report_produced_from_an_upper_body_only_photo(monkeypatch, _mocks):
    # § founder report / relaxed gate: an upper-body shot (no legs in frame)
    # is a real photo_attrs.usable_for_body candidate now — the physique
    # section must actually run from it, not just from a full_body shot.
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"g1", "mime": "image/jpeg", "path": "uploads/u1/g1.jpg",
             "attrs": {"usable_for_face": True, "usable_for_body": True,
                       "shot_type": "upper_body"}},
        ],
    )
    db = FakeDb()
    rep = _run(appearance.run_appearance(db, "u1"))
    assert rep["body"]["overall_score"] == 6.4
    assert _mocks["body"] == 1


def test_needs_body_photo_when_only_a_face_shot_is_usable(monkeypatch, _mocks):
    # A face-only crop (shot_type "face") never counts for body — the gate
    # should still hold there.
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"g1", "mime": "image/jpeg", "path": "uploads/u1/g1.jpg",
             "attrs": {"usable_for_face": True, "usable_for_body": False,
                       "shot_type": "face"}},
        ],
    )
    db = FakeDb()
    rep = _run(appearance.run_appearance(db, "u1"))
    assert rep["body"] == {"status": "needs_body_photo"}
    assert _mocks["body"] == 0


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
    assert rep["score"] == {"value": None, "basis": "none"}


def test_category_status_ran_for_both_axes(_mocks):
    db = FakeDb()
    rep = _run(appearance.run_appearance(db, "u1"))
    assert rep["category_status"] == {"face": "ran", "body": "ran"}


def test_category_status_skipped_when_axis_gated_off(_mocks):
    db = FakeDb()
    rep = _run(appearance.run_appearance(db, "u1", want_body=False))
    assert rep["category_status"] == {"face": "ran", "body": "skipped"}
    # a skipped axis is "not available", never a 0-score read
    assert rep["body"] == {"status": "needs_body_photo"}
    assert _mocks["body"] == 0


def test_category_status_no_eligible_photo_when_wanted_but_none(monkeypatch, _mocks):
    # Only a face shot on the grid, but body is still wanted -> no_eligible,
    # and the body section is "not available" rather than a bogus low score.
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"g1", "mime": "image/jpeg", "path": "uploads/u1/g1.jpg",
             "media_id": "m1",
             "attrs": {"usable_for_face": True, "usable_for_body": False}},
        ],
    )
    db = FakeDb()
    rep = _run(appearance.run_appearance(db, "u1", want_body=True))
    assert rep["category_status"] == {"face": "ran", "body": "no_eligible_photo"}
    assert rep["body"] == {"status": "needs_body_photo"}
    assert "overall_score" not in rep["body"]
    assert rep["score"] == {"value": 7.1, "basis": "face"}  # body never scored
    assert _mocks["body"] == 0


def test_explicit_selection_restricts_each_axis_to_chosen_grid_photos(monkeypatch, _mocks):
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"face", "mime": "image/jpeg", "path": "uploads/u1/f.jpg",
             "media_id": "mface",
             "attrs": {"usable_for_face": True, "usable_for_body": False}},
            {"bytes": b"body", "mime": "image/jpeg", "path": "uploads/u1/b.jpg",
             "media_id": "mbody",
             "attrs": {"usable_for_face": False, "usable_for_body": True}},
        ],
    )
    db = FakeDb()
    rep = _run(appearance.run_appearance(
        db, "u1", face_media_ids=["mface"], body_media_ids=["mbody"],
    ))
    assert rep["face"]["source_photos"] == ["uploads/u1/f.jpg"]
    assert rep["body"]["source_photos"] == ["uploads/u1/b.jpg"]
    assert rep["category_status"] == {"face": "ran", "body": "ran"}


def test_explicit_selection_of_an_ineligible_photo_yields_no_eligible(monkeypatch, _mocks):
    # The user "selected" a face-only photo for the body axis (stale/mis-specified
    # id). It must not feed body_report -> body is not-available, no bogus score.
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"face", "mime": "image/jpeg", "path": "uploads/u1/f.jpg",
             "media_id": "mface",
             "attrs": {"usable_for_face": True, "usable_for_body": False}},
        ],
    )
    db = FakeDb()
    rep = _run(appearance.run_appearance(
        db, "u1", face_media_ids=["mface"], body_media_ids=["mface"],
    ))
    assert rep["body"] == {"status": "needs_body_photo"}
    assert rep["category_status"]["body"] == "no_eligible_photo"
    assert _mocks["body"] == 0


def test_explicit_selection_never_falls_back_to_a_chat_attachment(monkeypatch, _mocks):
    # With a named body selection that matches nothing eligible, the extra
    # (chat) image must NOT be substituted in — explicit selection is grid-only.
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"face", "mime": "image/jpeg", "path": "uploads/u1/f.jpg",
             "media_id": "mface",
             "attrs": {"usable_for_face": True, "usable_for_body": False}},
        ],
    )
    db = FakeDb()
    rep = _run(appearance.run_appearance(
        db, "u1",
        body_media_ids=["mface"],
        extra_images=[(b"chat", "image/png", "uploads/u1/chat.jpg")],
    ))
    assert rep["body"] == {"status": "needs_body_photo"}
    assert _mocks["body"] == 0


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
    assert by_id["id"] == "current" and by_id["face"]["overall_score"] == 7.1
    cur = appearance.get_report(db, "u1", "current")
    assert cur["id"] == "current"
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
    db.docs[("users", "u1", "appearance", "current")] = {"report_id": "current"}
    assert "appearance" not in skill_runs.missing(db, "u1")


# --- finding_history: a real change is recorded, a reuse/no-op isn't -------


def test_finding_history_records_an_attribute_change(monkeypatch, _mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))  # eye_color: brown (photo)

    changed_fields = dict(_PA_FIELDS)
    changed_fields["eye_color"] = {
        "value": "blue", "source": "photo", "confidence": "medium",
        "note": "from pics", "photo_ids": ["uploads/u1/g2.jpg"],
    }

    async def _pa_refresh2(db, uid, *, persist_report=False, **kw):
        return {
            "fields": changed_fields, "report_id": "pr2", "photo_count": 2,
            "photo_paths": ["uploads/u1/g1.jpg", "uploads/u1/g2.jpg"],
        }

    monkeypatch.setattr(appearance.physical_attributes, "refresh", _pa_refresh2)
    # A real second photo actually landed in the grid too (not just in the
    # attributes stub above) -- otherwise the unchanged-photo-set dedup would
    # correctly (and unhelpfully, for this test) skip the second run entirely.
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"g1", "mime": "image/jpeg", "path": "uploads/u1/g1.jpg",
             "attrs": {"usable_for_face": True, "usable_for_body": True}},
            {"bytes": b"g2", "mime": "image/jpeg", "path": "uploads/u1/g2.jpg",
             "attrs": {}},
        ],
    )
    rep = _run(appearance.run_appearance(db, "u1"))

    assert rep["attributes"]["record"]["eye_color"]["value"] == "blue"
    hist = rep.get("finding_history") or db.docs[
        ("users", "u1", "appearance_reports", "current")
    ]["finding_history"]
    assert "eye_color" in hist
    entry = hist["eye_color"][-1]
    assert entry["value"] == "brown"
    assert entry["photo_ids"] == ["uploads/u1/g1.jpg"]
    assert entry["reason"] == "new photo evidence"


def test_finding_history_stays_empty_when_nothing_changes(_mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))
    _run(appearance.run_appearance(db, "u1"))  # same stubbed values again
    stored = db.docs[("users", "u1", "appearance_reports", "current")]
    assert stored["finding_history"] == {}


# --- unchanged-photo-set dedup: "rerun without new photos -> share the last
# aggregated one" (no Gemini calls) -------------------------------------------


def test_rerun_with_unchanged_photo_set_skips_gemini_and_reuses_report(_mocks):
    db = FakeDb()
    rep1 = _run(appearance.run_appearance(db, "u1"))
    assert (_mocks["pa"], _mocks["face"], _mocks["body"]) == (1, 1, 1)

    rep2 = _run(appearance.run_appearance(db, "u1"))
    # zero additional Gemini calls -- physical_attributes.refresh / face_report
    # .run / body_report.run were never invoked a second time.
    assert (_mocks["pa"], _mocks["face"], _mocks["body"]) == (1, 1, 1)
    # the exact same persisted report is handed back, unchanged.
    assert rep2["id"] == "current"
    assert rep2["attributes"] == rep1["attributes"]
    assert rep2["face"] == rep1["face"]
    assert rep2["body"] == rep1["body"]
    assert rep2["score"] == rep1["score"]

    led = db.docs.get(("users", "u1", "skill_runs", "appearance"))
    assert led["last_status"] == "skipped" and led["detail"] == "unchanged_photos"


def test_rerun_after_a_photo_is_added_runs_analysis_again(monkeypatch, _mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))
    assert (_mocks["pa"], _mocks["face"], _mocks["body"]) == (1, 1, 1)

    # a new photo landed in the grid -- the set no longer matches.
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"g1", "mime": "image/jpeg", "path": "uploads/u1/g1.jpg",
             "attrs": {"usable_for_face": True, "usable_for_body": True}},
            {"bytes": b"g2", "mime": "image/jpeg", "path": "uploads/u1/g2.jpg",
             "attrs": {}},
        ],
    )
    _run(appearance.run_appearance(db, "u1"))
    assert (_mocks["pa"], _mocks["face"], _mocks["body"]) == (2, 2, 2)


def test_rerun_after_a_photo_is_removed_runs_analysis_again(monkeypatch, _mocks):
    db = FakeDb()
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"g1", "mime": "image/jpeg", "path": "uploads/u1/g1.jpg",
             "attrs": {"usable_for_face": True, "usable_for_body": True}},
            {"bytes": b"g2", "mime": "image/jpeg", "path": "uploads/u1/g2.jpg",
             "attrs": {}},
        ],
    )

    async def _pa_refresh_two(db, uid, *, persist_report=False, **kw):
        _mocks["pa"] += 1
        return {
            "fields": _PA_FIELDS, "report_id": "pr1", "photo_count": 2,
            "photo_paths": ["uploads/u1/g1.jpg", "uploads/u1/g2.jpg"],
        }

    monkeypatch.setattr(appearance.physical_attributes, "refresh", _pa_refresh_two)
    _run(appearance.run_appearance(db, "u1"))
    assert (_mocks["pa"], _mocks["face"], _mocks["body"]) == (1, 1, 1)

    # g2 removed -- back down to one photo, the set no longer matches.
    monkeypatch.setattr(
        appearance, "_grid_photos",
        lambda db, uid: [
            {"bytes": b"g1", "mime": "image/jpeg", "path": "uploads/u1/g1.jpg",
             "attrs": {"usable_for_face": True, "usable_for_body": True}},
        ],
    )
    _run(appearance.run_appearance(db, "u1"))
    assert (_mocks["pa"], _mocks["face"], _mocks["body"]) == (2, 2, 2)


def test_unidentifiable_extra_image_never_falsely_dedups(_mocks):
    db = FakeDb()
    # No real storage path for this chat attachment -> can't be reliably
    # identified, so the dedup comparison must never be attempted for it.
    extra = [(b"chatpic", "image/png", "")]
    _run(appearance.run_appearance(db, "u1", extra_images=extra))
    assert (_mocks["pa"], _mocks["face"], _mocks["body"]) == (1, 1, 1)

    _run(appearance.run_appearance(db, "u1", extra_images=extra))
    # same unidentifiable extra + same grid every time -- still always reruns.
    assert (_mocks["pa"], _mocks["face"], _mocks["body"]) == (2, 2, 2)


# --- record_background_result (§ appearance / auto_analysis) ----------------


def test_record_background_result_stamps_current_pointer(_mocks):
    db = FakeDb()
    db.docs[("users", "u1", "physical_attributes", "current")] = {
        "fields": _PA_FIELDS, "photo_count": 2,
    }
    rid = appearance.record_background_result(db, "u1", face=dict(_FACE))
    assert rid == "current"

    ptr = appearance.current(db, "u1")
    assert ptr and ptr["report_id"] == "current"

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
    assert rep["id"] == "current"
    assert rid2 == "current"
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
    monkeypatch.setattr(appearance, "_persist_report", _boom)

    # Must not raise, and must return "" since nothing could be stored.
    assert appearance.record_background_result(db, "u1", face=dict(_FACE)) == ""


# --- run_batch_photos (§ appearance batching) -------------------------------


def test_run_batch_photos_analyses_each_new_photo_once_then_refreshes_attrs(
    monkeypatch,
):
    db = FakeDb()
    calls = []

    async def _analyse(db, uid, sp, *, embedding=None, attributes=None):
        calls.append(sp)

    refreshed = []

    async def _refresh(db, uid, **kw):
        refreshed.append(uid)

    import auto_analysis

    monkeypatch.setattr(auto_analysis, "analyse_photo", _analyse)
    monkeypatch.setattr(appearance.physical_attributes, "refresh", _refresh)

    _run(
        appearance.run_batch_photos(
            db, "u1",
            [("a.jpg", None, None), ("b.jpg", [0.1], {"shot_type": "face"})],
        )
    )
    assert calls == ["a.jpg", "b.jpg"]
    assert refreshed == ["u1"]


def test_run_batch_photos_dedupes_and_skips_blank_paths(monkeypatch):
    db = FakeDb()
    calls = []

    async def _analyse(db, uid, sp, *, embedding=None, attributes=None):
        calls.append(sp)

    async def _refresh(db, uid, **kw):
        pass

    import auto_analysis

    monkeypatch.setattr(auto_analysis, "analyse_photo", _analyse)
    monkeypatch.setattr(appearance.physical_attributes, "refresh", _refresh)

    _run(
        appearance.run_batch_photos(
            db, "u1", [("a.jpg", None, None), ("a.jpg", None, None), ("", None, None)],
        )
    )
    assert calls == ["a.jpg"]


def test_run_batch_photos_one_bad_photo_does_not_block_the_rest(monkeypatch):
    db = FakeDb()
    calls = []

    async def _analyse(db, uid, sp, *, embedding=None, attributes=None):
        calls.append(sp)
        if sp == "bad.jpg":
            raise RuntimeError("boom")

    async def _refresh(db, uid, **kw):
        calls.append("refreshed")

    import auto_analysis

    monkeypatch.setattr(auto_analysis, "analyse_photo", _analyse)
    monkeypatch.setattr(appearance.physical_attributes, "refresh", _refresh)

    _run(
        appearance.run_batch_photos(
            db, "u1", [("bad.jpg", None, None), ("good.jpg", None, None)],
        )
    )
    assert calls == ["bad.jpg", "good.jpg", "refreshed"]


# --- correct_finding (§ appearance corrections) ------------------------------


def test_correct_finding_attribute_writes_stated_and_resyncs_report(
    monkeypatch, _mocks,
):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))  # eye_color: brown (photo)

    async def _gemini(contents, *, system_prompt, response_schema, images, uid, feature):
        return {"reply": "Got it, blue it is.", "value": "blue"}

    monkeypatch.setattr(appearance.gemini, "generate_json", _gemini)
    monkeypatch.setattr(
        appearance.media_embed, "download_bytes", lambda p: (b"x", "image/jpeg")
    )

    # A smarter stub than `_mocks`'s dumb static one: reflects whatever was
    # just written to profile/main, like the real merge()/resolve_stated()
    # precedence would — so this test can check correct_finding actually
    # re-syncs the appearance report off refresh()'s result.
    async def _pa_refresh_reflecting_stated(db, uid, *, persist_report=False, **kw):
        prof = db.docs.get(("users", "u1", "profile", "main")) or {}
        fields = dict(_PA_FIELDS)
        if prof.get("eye_color"):
            fields["eye_color"] = {
                "value": prof["eye_color"], "source": "stated",
                "confidence": "high", "note": "from your answers", "photo_ids": [],
            }
        return {
            "fields": fields, "report_id": "pr2", "photo_count": 1,
            "photo_paths": ["uploads/u1/g1.jpg"],
        }

    monkeypatch.setattr(
        appearance.physical_attributes, "refresh", _pa_refresh_reflecting_stated
    )

    out = _run(appearance.correct_finding(db, "u1", "eye_color", "my eyes are blue"))
    assert out["ok"] is True
    assert out["value"] == "blue"

    prof = db.docs.get(("users", "u1", "profile", "main"))
    assert prof and prof["eye_color"] == "blue"

    rep = appearance.get_report(db, "u1", "current")
    assert rep["attributes"]["record"]["eye_color"]["value"] == "blue"
    assert rep["attributes"]["record"]["eye_color"]["source"] == "stated"
    hist = rep["finding_history"].get("eye_color") or []
    assert hist and hist[-1]["value"] == "brown"


def test_correct_finding_rejects_an_invalid_value(monkeypatch, _mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))

    async def _gemini(*a, **k):
        return {"reply": "hmm", "value": "not-a-real-color"}

    monkeypatch.setattr(appearance.gemini, "generate_json", _gemini)
    monkeypatch.setattr(
        appearance.media_embed, "download_bytes", lambda p: (b"x", "image/jpeg")
    )

    out = _run(appearance.correct_finding(db, "u1", "eye_color", "it's not brown"))
    assert out["ok"] is False
    assert db.docs.get(("users", "u1", "profile", "main")) is None


def test_correct_finding_face_axis_folds_note_and_pushes_history(monkeypatch, _mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))

    async def _gemini(*a, **k):
        return {"reply": "Noted!", "value": "Actually has a beard."}

    monkeypatch.setattr(appearance.gemini, "generate_json", _gemini)
    monkeypatch.setattr(
        appearance.media_embed, "download_bytes", lambda p: (b"x", "image/jpeg")
    )

    out = _run(appearance.correct_finding(db, "u1", "face", "I actually have a beard now"))
    assert out["ok"] is True
    assert "Actually has a beard." in out["value"]["verdict_note"]

    rep = appearance.get_report(db, "u1", "current")
    assert "Actually has a beard." in rep["face"]["verdict_note"]
    assert rep["finding_history"]["face"]


def test_correct_finding_unknown_finding_raises_keyerror(_mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))
    with pytest.raises(KeyError):
        _run(appearance.correct_finding(db, "u1", "shoe_size", "size 10"))


def test_correct_finding_blank_message_raises_valueerror(_mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))
    with pytest.raises(ValueError):
        _run(appearance.correct_finding(db, "u1", "eye_color", "   "))


def test_correct_finding_no_report_yet_raises_keyerror():
    db = FakeDb()
    with pytest.raises(KeyError):
        _run(appearance.correct_finding(db, "u1", "eye_color", "it's blue"))


def test_correct_finding_usage_capped(monkeypatch, _mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))

    async def _capped(*a, **k):
        raise appearance.token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(appearance.gemini, "generate_json", _capped)
    out = _run(appearance.correct_finding(db, "u1", "eye_color", "it's blue"))
    assert out == {"usage_capped": True}


# --- clear_finding (§ appearance corrections: clear a stated override) -------


def test_clear_finding_deletes_the_stated_override_and_resyncs(monkeypatch, _mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))  # eye_color: brown (photo)
    # Simulate a prior stated override, like correct_finding would have left.
    db.docs[("users", "u1", "profile", "main")] = {"eye_color": "blue"}

    async def _pa_refresh_reflecting_stated(db, uid, *, persist_report=False, **kw):
        prof = db.docs.get(("users", "u1", "profile", "main")) or {}
        fields = dict(_PA_FIELDS)
        if prof.get("eye_color"):
            fields["eye_color"] = {
                "value": prof["eye_color"], "source": "stated",
                "confidence": "high", "note": "from your answers", "photo_ids": [],
            }
        return {
            "fields": fields, "report_id": "pr2", "photo_count": 1,
            "photo_paths": ["uploads/u1/g1.jpg"],
        }

    monkeypatch.setattr(
        appearance.physical_attributes, "refresh", _pa_refresh_reflecting_stated
    )

    out = _run(appearance.clear_finding(db, "u1", "eye_color"))
    assert out == {"ok": True, "finding_id": "eye_color"}

    prof = db.docs.get(("users", "u1", "profile", "main")) or {}
    assert "eye_color" not in prof

    rep = appearance.get_report(db, "u1", "current")
    assert rep["attributes"]["record"]["eye_color"]["value"] == "brown"
    assert rep["attributes"]["record"]["eye_color"]["source"] == "photo"


def test_clear_finding_rejects_face_and_body(_mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))
    with pytest.raises(KeyError):
        _run(appearance.clear_finding(db, "u1", "face"))
    with pytest.raises(KeyError):
        _run(appearance.clear_finding(db, "u1", "body"))


def test_clear_finding_rejects_unknown_field(_mocks):
    db = FakeDb()
    _run(appearance.run_appearance(db, "u1"))
    with pytest.raises(KeyError):
        _run(appearance.clear_finding(db, "u1", "shoe_size"))


def test_clear_finding_no_report_yet_raises_keyerror():
    db = FakeDb()
    with pytest.raises(KeyError):
        _run(appearance.clear_finding(db, "u1", "eye_color"))
