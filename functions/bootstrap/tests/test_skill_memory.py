import datetime

import pytest
import skill_memory


# --- fake Firestore (nested tuple-keyed store) ---------------------------------


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
        self._store.writes.append((self._key, payload, merge))

    def collection(self, name):
        return _CollRef(self._store, self._key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self._store = store
        self._key = key

    def document(self, name):
        return _DocRef(self._store, self._key + (name,))

    def stream(self):
        depth = len(self._key)
        for key, data in self._store.docs.items():
            if len(key) == depth + 1 and key[:depth] == self._key:
                yield _Snap(key[-1], data)


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.writes = []

    def collection(self, name):
        return _CollRef(self, (name,))


def _page(db, uid, page_id):
    return db.docs.get(("users", uid, "wiki_pages", page_id))


_DIGEST = {
    "name": "Dana Reis",
    "summary": "Marine biologist in Lisbon.",
    "confidence": "high",
    "facts": [
        {
            "claim": "Works at the Lisbon Oceanarium",
            "category": "work",
            "source_url": "https://oceanario.pt/team",
            "confidence": "high",
        }
    ],
    "links": [
        {
            "url": "https://oceanario.pt/team",
            "title": "Team — Oceanário",
            "is_them": "likely",
        }
    ],
    "caveats": "Two people share the name.",
}

_FACE = {
    "usable": True,
    "overall_score": 6.9,
    "verdict": "Above average",
    "verdict_note": "Strong eyes, weak skin texture.",
    "features": [{"name": "eyes", "score": 8.0, "note": "Well spaced."}],
    "quick_facts": {"face_shape": "oval", "best_feature": "eyes"},
    "strengths": ["Expressive eyes"],
    "improvements": ["Even out skin texture"],
    "recommendations": [{"category": "skincare", "text": "Nightly retinoid."}],
}

_BODY = {
    "usable": True,
    "overall_score": 6.4,
    "verdict": "Solid base",
    "features": [{"name": "posture", "score": 6.0, "note": "Slight forward head."}],
    "quick_facts": {"body_type": "mesomorph"},
    "strengths": ["Good shoulder width"],
    "improvements": ["Build calves"],
    "recommendations": [{"category": "training", "text": "Add calf volume."}],
}


# --- save_* ------------------------------------------------------------------


def test_save_web_findings_upserts_a_private_page():
    db = FakeDb()
    skill_memory.save_web_findings(db, "u1", _DIGEST)

    page = _page(db, "u1", "web-findings")
    assert page is not None
    assert page["page_type"] == "web_findings"
    assert page["visibility"] == "private"
    assert "Lisbon Oceanarium" in page["ai_body"]
    assert "oceanario.pt/team" in page["ai_body"]
    assert "created_at" in page and "updated_at" in page


def test_save_face_analysis_upserts_a_private_page():
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", _FACE)

    page = _page(db, "u1", "face-analysis")
    assert page["page_type"] == "face_analysis"
    assert page["visibility"] == "private"
    assert "6.9/10" in page["ai_body"]
    assert "Expressive eyes" in page["ai_body"]


def test_save_body_analysis_upserts_a_private_page():
    db = FakeDb()
    skill_memory.save_body_analysis(db, "u1", _BODY)

    page = _page(db, "u1", "body-analysis")
    assert page["page_type"] == "body_analysis"
    assert page["visibility"] == "private"
    assert "6.4/10" in page["ai_body"]


def test_save_physical_profile_upserts_a_private_page():
    db = FakeDb()
    skill_memory.save_physical_profile(db, "u1", "Tall, athletic build.")

    page = _page(db, "u1", "physical-profile")
    assert page["page_type"] == "physical_profile"
    assert page["visibility"] == "private"
    assert page["ai_body"] == "Tall, athletic build."


def test_save_skips_an_unusable_report():
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", {"usable": False})
    assert _page(db, "u1", "face-analysis") is None


def test_save_keeps_an_explicit_visibility_the_user_chose():
    db = FakeDb()
    db.docs[("users", "u1", "wiki_pages", "web-findings")] = {
        "ai_body": "old",
        "page_type": "web_findings",
        "visibility": "public",  # the user made it public
        "created_at": "ORIG",
    }
    skill_memory.save_web_findings(db, "u1", _DIGEST)

    page = _page(db, "u1", "web-findings")
    assert page["visibility"] == "public"  # not forced back to the default
    assert "Lisbon Oceanarium" in page["ai_body"]  # body still refreshed
    assert page["created_at"] == "ORIG"  # created_at preserved


def test_save_bumps_a_legacy_ai_only_page_up_to_private():
    db = FakeDb()
    db.docs[("users", "u1", "wiki_pages", "web-findings")] = {
        "ai_body": "old",
        "page_type": "web_findings",
        "visibility": "ai_only",  # pre-existing legacy page, not yet backfilled
        "created_at": "ORIG",
    }
    skill_memory.save_web_findings(db, "u1", _DIGEST)

    page = _page(db, "u1", "web-findings")
    assert page["visibility"] == "private"


def test_save_is_best_effort_and_never_raises():
    class Boom:
        def collection(self, *a, **k):
            raise RuntimeError("firestore down")

    skill_memory.save_web_findings(Boom(), "u1", _DIGEST)  # no exception


# --- merge_* (auto-analysis accumulation) ---------------------------------


def test_merge_face_analysis_keeps_a_latest_block_and_a_dated_history():
    db = FakeDb()
    skill_memory.merge_face_analysis(db, "u1", _FACE)

    page = _page(db, "u1", "face-analysis")
    assert page["page_type"] == "face_analysis"
    assert page["visibility"] == "private"
    assert "Overall: 6.9/10 (median across 1 read)" in page["ai_body"]
    assert "Latest read:" in page["ai_body"]
    assert "6.9/10" in page["ai_body"]
    assert len(page["reads"]) == 1
    assert "created_at" in page and "updated_at" in page


def test_merge_accumulates_rather_than_overwrites():
    db = FakeDb()
    skill_memory.merge_body_analysis(db, "u1", _BODY)
    second = dict(_BODY, overall_score=7.7, verdict="Improved")
    skill_memory.merge_body_analysis(db, "u1", second)

    page = _page(db, "u1", "body-analysis")
    assert len(page["reads"]) == 2
    assert "7.7/10" in page["ai_body"]  # latest block refreshed
    assert "Earlier reads from other photos" in page["ai_body"]
    assert "6.4/10" in page["ai_body"]  # first read still in the history


def test_merge_caps_the_accumulated_body_dropping_oldest_first():
    db = FakeDb()
    long_reads = [
        f"- 2026-01-{i:02d}: {i}/10 — " + "x" * 200 for i in range(1, 30)
    ]
    db.docs[("users", "u1", "wiki_pages", "body-analysis")] = {
        "reads": list(long_reads),
        "page_type": "body_analysis",
        "visibility": "ai_only",
        "created_at": "ORIG",
    }
    skill_memory.merge_body_analysis(db, "u1", _BODY)

    page = _page(db, "u1", "body-analysis")
    assert len(page["ai_body"]) <= 4000
    assert len(page["reads"]) < len(long_reads) + 1  # oldest lines dropped
    # newest read kept, as the new {"text", "photo"} shape; the legacy plain
    # strings that survived the cap are untouched.
    assert "Solid base" in skill_memory._entry_text(page["reads"][-1])
    assert page["created_at"] == "ORIG"


def test_merge_skips_an_unusable_report():
    db = FakeDb()
    skill_memory.merge_face_analysis(db, "u1", {"usable": False})
    assert _page(db, "u1", "face-analysis") is None


def test_merge_keeps_an_explicit_visibility():
    db = FakeDb()
    db.docs[("users", "u1", "wiki_pages", "face-analysis")] = {
        "ai_body": "old",
        "reads": [],
        "page_type": "face_analysis",
        "visibility": "public",  # the user made it public
        "created_at": "ORIG",
    }
    skill_memory.merge_face_analysis(db, "u1", _FACE)

    page = _page(db, "u1", "face-analysis")
    assert page["visibility"] == "public"
    assert page["created_at"] == "ORIG"
    assert "6.9/10" in page["ai_body"]


def test_merge_shows_a_running_median_not_just_the_latest_score():
    db = FakeDb()
    skill_memory.merge_body_analysis(db, "u1", dict(_BODY, overall_score=6.0))
    skill_memory.merge_body_analysis(db, "u1", dict(_BODY, overall_score=8.0))

    page = _page(db, "u1", "body-analysis")
    # median(6.0, 8.0) == 7.0
    assert "Overall: 7/10 (median across 2 reads)" in page["ai_body"]
    assert page["ai_body"].index("Overall: 7/10") < page["ai_body"].index(
        "Latest read:"
    )


def test_merge_median_of_a_single_read_is_that_read():
    db = FakeDb()
    skill_memory.merge_face_analysis(db, "u1", dict(_FACE, overall_score=6.9))
    page = _page(db, "u1", "face-analysis")
    assert "Overall: 6.9/10 (median across 1 read)" in page["ai_body"]


def test_merge_median_of_three_is_the_middle_value():
    db = FakeDb()
    for score in (5.0, 9.0, 7.0):
        skill_memory.merge_body_analysis(
            db, "u1", dict(_BODY, overall_score=score)
        )
    page = _page(db, "u1", "body-analysis")
    assert "Overall: 7/10 (median across 3 reads)" in page["ai_body"]


def test_median_helper_handles_even_and_odd_counts():
    assert skill_memory._median([1.0, 3.0]) == 2.0
    assert skill_memory._median([1.0, 2.0, 9.0]) == 2.0
    assert skill_memory._median([5.0]) == 5.0


def test_save_face_analysis_one_shot_path_has_no_median_line():
    # The manually-triggered, non-accumulating path (`_upsert`) must not get
    # a fake "median of one" — only the auto-analysis accumulating path does.
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", _FACE)
    page = _page(db, "u1", "face-analysis")
    assert "median" not in page["ai_body"]


def test_merge_records_which_photo_produced_each_read():
    db = FakeDb()
    skill_memory.merge_face_analysis(
        db, "u1", {**_FACE, "source_photos": ["uploads/u1/a.jpg"]}
    )
    skill_memory.merge_face_analysis(
        db, "u1", {**_FACE, "source_photos": ["uploads/u1/b.jpg"]}
    )
    page = _page(db, "u1", "face-analysis")
    assert [r["photo"] for r in page["reads"]] == [
        "uploads/u1/a.jpg", "uploads/u1/b.jpg",
    ]


def test_merge_with_no_source_photo_records_an_empty_photo_ref():
    db = FakeDb()
    skill_memory.merge_face_analysis(db, "u1", _FACE)  # no source_photos key
    page = _page(db, "u1", "face-analysis")
    assert page["reads"] == [
        {"text": page["reads"][0]["text"], "photo": ""}
    ]


def test_merge_reads_a_legacy_plain_string_history_without_crashing():
    # A page saved before photo references existed — every entry a bare
    # string. Merging a new (photo-carrying) read must not choke on it.
    db = FakeDb()
    db.docs[("users", "u1", "wiki_pages", "face-analysis")] = {
        "reads": ["- 2026-01-01: 5.0/10 — Average"],
        "page_type": "face_analysis",
        "visibility": "private",
        "created_at": "ORIG",
    }
    skill_memory.merge_face_analysis(
        db, "u1", {**_FACE, "source_photos": ["uploads/u1/new.jpg"]}
    )
    page = _page(db, "u1", "face-analysis")
    assert len(page["reads"]) == 2
    assert page["reads"][0] == "- 2026-01-01: 5.0/10 — Average"  # untouched
    assert page["reads"][1]["photo"] == "uploads/u1/new.jpg"
    assert "Overall: " in page["ai_body"]  # median parse didn't choke either


def test_merge_is_best_effort_and_never_raises():
    class Boom:
        def collection(self, *a, **k):
            raise RuntimeError("firestore down")

    skill_memory.merge_body_analysis(Boom(), "u1", _BODY)  # no exception


# --- promote ---------------------------------------------------------------


def test_promote_flips_a_legacy_ai_only_page_to_private():
    # New pages already default to `private` — `promote` still matters for a
    # pre-existing page that hasn't been touched (backfilled) since the
    # `ai_only` default was retired.
    db = FakeDb()
    db.docs[("users", "u1", "wiki_pages", "face-analysis")] = {
        "ai_body": "legacy body",
        "page_type": "face_analysis",
        "visibility": "ai_only",
        "created_at": "ORIG",
    }

    assert skill_memory.promote(db, "u1", "face_analysis") is True
    assert _page(db, "u1", "face-analysis")["visibility"] == "private"


def test_promote_is_a_noop_for_a_missing_page():
    db = FakeDb()
    assert skill_memory.promote(db, "u1", "web_findings") is False
    assert _page(db, "u1", "web-findings") is None


def test_promote_rejects_an_unknown_page_type():
    db = FakeDb()
    assert skill_memory.promote(db, "u1", "career") is False


def test_promote_is_idempotent_once_visible():
    db = FakeDb()
    skill_memory.save_body_analysis(db, "u1", _BODY)
    skill_memory.promote(db, "u1", "body_analysis")
    assert skill_memory.promote(db, "u1", "body_analysis") is True
    assert _page(db, "u1", "body-analysis")["visibility"] == "private"


# --- note_interaction ----------------------------------------------------------


def test_note_interaction_creates_an_ai_only_interactions_page():
    db = FakeDb()
    skill_memory.note_interaction(db, "u1", "ran a deep dive on Jordan", stamp="2026-09-10")
    page = _page(db, "u1", "interactions")
    assert page is not None
    assert page["page_type"] == "interactions"
    assert page["visibility"] == "ai_only"
    assert "- 2026-09-10 — ran a deep dive on Jordan" in page["ai_body"]
    assert "created_at" in page


def test_note_interaction_prepends_newest_first_and_caps_at_15():
    db = FakeDb()
    for i in range(20):
        skill_memory.note_interaction(
            db, "u1", f"event {i}", stamp=f"2026-09-{i + 1:02d}"
        )
    body = _page(db, "u1", "interactions")["ai_body"]
    lines = [ln for ln in body.splitlines() if ln.startswith("- ")]
    assert len(lines) == 15
    assert lines[0].endswith("event 19")  # newest on top
    assert lines[-1].endswith("event 5")  # oldest 5 dropped


def test_note_interaction_overrides_any_explicit_visibility_back_to_ai_only():
    # Unlike the skill-report pages in this module, `interactions` never
    # honours a prior explicit visibility — it is always forced to `ai_only`.
    db = FakeDb()
    skill_memory.note_interaction(db, "u1", "first", stamp="2026-09-01")
    db.docs[("users", "u1", "wiki_pages", "interactions")]["visibility"] = "public"
    skill_memory.note_interaction(db, "u1", "second", stamp="2026-09-02")
    assert _page(db, "u1", "interactions")["visibility"] == "ai_only"


def test_note_interaction_ignores_blank_text_and_never_raises():
    db = FakeDb()
    skill_memory.note_interaction(db, "u1", "   ")
    assert _page(db, "u1", "interactions") is None
    skill_memory.note_interaction(None, "u1", "x")  # no db — swallowed


# --- endpoints -------------------------------------------------------------

from fastapi.testclient import TestClient  # noqa: E402
from firebase_admin import auth as firebase_auth  # noqa: E402

import main  # noqa: E402

_client = TestClient(main.app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "me"}
    )
    return {"Authorization": "Bearer valid"}


def test_wiki_promote_endpoint_flips_a_legacy_ai_only_page(monkeypatch):
    db = FakeDb()
    db.docs[("users", "me", "wiki_pages", "web-findings")] = {
        "ai_body": "legacy body",
        "page_type": "web_findings",
        "visibility": "ai_only",
    }
    monkeypatch.setattr(main, "get_db", lambda: db)

    r = _client.post(
        "/wiki/promote", headers=_auth(monkeypatch),
        json={"page_type": "web_findings"},
    )
    assert r.status_code == 200
    assert r.json() == {"promoted": True}
    assert _page(db, "me", "web-findings")["visibility"] == "private"


def test_wiki_promote_endpoint_false_when_no_page(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = _client.post(
        "/wiki/promote", headers=_auth(monkeypatch),
        json={"page_type": "face_analysis"},
    )
    assert r.status_code == 200
    assert r.json() == {"promoted": False}


def test_wiki_promote_endpoint_400_for_a_non_promotable_type(monkeypatch):
    r = _client.post(
        "/wiki/promote", headers=_auth(monkeypatch),
        json={"page_type": "career"},
    )
    assert r.status_code == 400


def test_skills_report_endpoint_returns_a_stored_report(monkeypatch):
    db = FakeDb()
    db.docs[("users", "me", "face_reports", "r1")] = {
        "report": dict(_FACE),
        "created_at": datetime.datetime(2026, 1, 2, 3, 4, 5),
    }
    monkeypatch.setattr(main, "get_db", lambda: db)

    r = _client.get("/skills/report/face/r1", headers=_auth(monkeypatch))
    assert r.status_code == 200
    body = r.json()
    assert body["report"]["overall_score"] == 6.9
    assert body["created_at"] == "2026-01-02T03:04:05"


def test_skills_report_endpoint_404_for_an_unknown_id(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = _client.get("/skills/report/body/nope", headers=_auth(monkeypatch))
    assert r.status_code == 404


def test_skills_report_endpoint_400_for_a_bad_kind(monkeypatch):
    r = _client.get("/skills/report/hair/r1", headers=_auth(monkeypatch))
    assert r.status_code == 400


def test_skills_reports_list_endpoint_returns_usable_rows_only(monkeypatch):
    db = FakeDb()
    db.docs[("users", "me", "face_reports", "r1")] = {
        "report": dict(_FACE),
        "image_path": "uploads/me/a.jpg",
        "created_at": datetime.datetime(2026, 1, 2),
    }
    db.docs[("users", "me", "face_reports", "r2")] = {
        "report": {"usable": False},
        "created_at": datetime.datetime(2026, 1, 3),
    }
    monkeypatch.setattr(main, "get_db", lambda: db)

    r = _client.get("/skills/reports/face", headers=_auth(monkeypatch))
    assert r.status_code == 200
    rows = r.json()["reports"]
    assert [row["id"] for row in rows] == ["r1"]
    assert rows[0]["overall_score"] == 6.9
    assert rows[0]["verdict"] == "Above average"
    assert rows[0]["image_path"] == "uploads/me/a.jpg"


def test_skills_reports_list_endpoint_400_for_a_bad_kind(monkeypatch):
    r = _client.get("/skills/reports/hair", headers=_auth(monkeypatch))
    assert r.status_code == 400
