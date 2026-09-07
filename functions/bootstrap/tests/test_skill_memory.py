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


def test_save_web_findings_upserts_an_ai_only_page():
    db = FakeDb()
    skill_memory.save_web_findings(db, "u1", _DIGEST)

    page = _page(db, "u1", "web-findings")
    assert page is not None
    assert page["page_type"] == "web_findings"
    assert page["visibility"] == "ai_only"
    assert "Lisbon Oceanarium" in page["ai_body"]
    assert "oceanario.pt/team" in page["ai_body"]
    assert "created_at" in page and "updated_at" in page


def test_save_face_analysis_upserts_an_ai_only_page():
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", _FACE)

    page = _page(db, "u1", "face-analysis")
    assert page["page_type"] == "face_analysis"
    assert page["visibility"] == "ai_only"
    assert "6.9/10" in page["ai_body"]
    assert "Expressive eyes" in page["ai_body"]


def test_save_body_analysis_upserts_an_ai_only_page():
    db = FakeDb()
    skill_memory.save_body_analysis(db, "u1", _BODY)

    page = _page(db, "u1", "body-analysis")
    assert page["page_type"] == "body_analysis"
    assert page["visibility"] == "ai_only"
    assert "6.4/10" in page["ai_body"]


def test_save_skips_an_unusable_report():
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", {"usable": False})
    assert _page(db, "u1", "face-analysis") is None


def test_save_keeps_a_non_ai_only_visibility_the_user_chose():
    db = FakeDb()
    db.docs[("users", "u1", "wiki_pages", "web-findings")] = {
        "ai_body": "old",
        "page_type": "web_findings",
        "visibility": "private",  # the user promoted it
        "created_at": "ORIG",
    }
    skill_memory.save_web_findings(db, "u1", _DIGEST)

    page = _page(db, "u1", "web-findings")
    assert page["visibility"] == "private"  # not forced back to ai_only
    assert "Lisbon Oceanarium" in page["ai_body"]  # body still refreshed
    assert page["created_at"] == "ORIG"  # created_at preserved


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
    assert page["visibility"] == "ai_only"
    assert page["ai_body"].startswith("Latest read:")
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
    assert "Solid base" in page["reads"][-1]  # newest read kept
    assert page["created_at"] == "ORIG"


def test_merge_skips_an_unusable_report():
    db = FakeDb()
    skill_memory.merge_face_analysis(db, "u1", {"usable": False})
    assert _page(db, "u1", "face-analysis") is None


def test_merge_keeps_a_promoted_visibility():
    db = FakeDb()
    db.docs[("users", "u1", "wiki_pages", "face-analysis")] = {
        "ai_body": "old",
        "reads": [],
        "page_type": "face_analysis",
        "visibility": "private",  # the user promoted it
        "created_at": "ORIG",
    }
    skill_memory.merge_face_analysis(db, "u1", _FACE)

    page = _page(db, "u1", "face-analysis")
    assert page["visibility"] == "private"
    assert page["created_at"] == "ORIG"
    assert "6.9/10" in page["ai_body"]


def test_merge_is_best_effort_and_never_raises():
    class Boom:
        def collection(self, *a, **k):
            raise RuntimeError("firestore down")

    skill_memory.merge_body_analysis(Boom(), "u1", _BODY)  # no exception


# --- promote ---------------------------------------------------------------


def test_promote_flips_ai_only_to_private():
    db = FakeDb()
    skill_memory.save_face_analysis(db, "u1", _FACE)
    assert _page(db, "u1", "face-analysis")["visibility"] == "ai_only"

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


def test_wiki_promote_endpoint_flips_the_page(monkeypatch):
    db = FakeDb()
    skill_memory.save_web_findings(db, "me", _DIGEST)
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
