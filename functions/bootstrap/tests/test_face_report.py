import asyncio

import face_report
import gemini
import media_embed
import pytest
import token_ledger
from skills import make_session_tool_fns, session_tool_declarations
from skills import face_report as face_skill


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


_RAW = {
    "usable": True,
    "overall_score": 6.9,
    "verdict": "Above average",
    "verdict_note": "Strong eyes, let down by skin texture and under-eye shadow.",
    "features": [
        {"name": "symmetry", "score": 7.0, "note": "Minor jaw asymmetry, left fuller."},
        {"name": "skin_quality", "score": 5.5, "note": "Visible texture on the cheeks."},
        {"name": "eyes", "score": 8.0, "note": "Well spaced, good lid exposure."},
    ],
    "quick_facts": {
        "face_shape": "oval",
        "age_estimate": "27-32",
        "facial_hair_density": "medium",
        "hair_thickness": "thick",
        "skin_undertone": "warm",
        "best_feature": "eyes",
        "worst_feature": "skin texture",
    },
    "strengths": ["Expressive, well-proportioned eyes", "Full head of hair"],
    "improvements": ["Even out skin texture", "Address under-eye shadowing"],
    "recommendations": [
        {"category": "skincare", "text": "Nightly retinoid for texture."},
        {"category": "under_eye", "text": "Caffeine eye cream + more sleep."},
    ],
}


@pytest.fixture
def _patch_json(monkeypatch):
    async def _json(contents, system_prompt, response_schema=None, image=None, **kw):
        assert image is not None and image[0] == b"jpegbytes"
        assert kw.get("feature") == token_ledger.FEATURE_FACE_REPORT
        return dict(_RAW)

    monkeypatch.setattr(gemini, "generate_json", _json)


def test_run_returns_the_structured_shape(_patch_json):
    r = _run(face_report.run(b"jpegbytes", "image/jpeg", uid="u1"))
    assert r["usable"] is True
    assert r["overall_score"] == 6.9
    assert r["verdict"] == "Above average"
    assert [f["name"] for f in r["features"]] == ["symmetry", "skin_quality", "eyes"]
    assert r["quick_facts"]["face_shape"] == "oval"
    assert r["strengths"][0].startswith("Expressive")
    assert r["recommendations"][0]["category"] == "skincare"


def test_run_rejects_empty_bytes():
    with pytest.raises(ValueError):
        _run(face_report.run(b"", "image/jpeg", uid="u1"))


def test_run_echoes_the_source_photo(_patch_json):
    r = _run(
        face_report.run(
            b"jpegbytes", "image/jpeg", uid="u1", source_path="uploads/u1/a.jpg"
        )
    )
    assert r["source_photos"] == ["uploads/u1/a.jpg"]


def test_run_without_a_source_path_has_no_source_photos(_patch_json):
    r = _run(face_report.run(b"jpegbytes", "image/jpeg", uid="u1"))
    assert r["source_photos"] == []


def test_render_summarises_the_read():
    text = face_report.render({**_RAW})
    assert "6.9/10" in text
    assert "Above average" in text
    assert "Expressive, well-proportioned eyes" in text
    assert "Even out skin texture" in text
    # The card renders the "open full report" affordance now, not the text.
    assert "Open the full report" not in text


def test_render_handles_an_unusable_photo():
    text = face_report.render({"usable": False})
    assert "front-facing" in text
    assert "/10" not in text


# --- skill ---------------------------------------------------------------


class _FakeDoc:
    def __init__(self, data):
        self._data = data

    def to_dict(self):
        return self._data


class _FakeReports:
    def __init__(self):
        self.added = []

    def add(self, payload):
        self.added.append(payload)
        return ("WRITE_TS", type("R", (), {"id": "report123"})())


class _FakeChatMessages:
    def __init__(self, rows):
        self._rows = rows

    def order_by(self, *a, **k):
        return self

    def limit(self, *a, **k):
        return self

    def stream(self):
        return iter(self._rows)


class _FakeUserRef:
    def __init__(self, rows, reports):
        self._rows = rows
        self._reports = reports

    def collection(self, name):
        if name == "chat_messages":
            return _FakeChatMessages(self._rows)
        if name == "face_reports":
            return self._reports
        raise AssertionError(name)


class _FakeDb:
    def __init__(self, rows, reports):
        self._ref = _FakeUserRef(rows, reports)

    def collection(self, name):
        assert name == "users"
        return self

    def document(self, uid):
        return self._ref


def test_skill_is_registered_with_no_params():
    decl = next(
        d for d in session_tool_declarations() if d["name"] == "face_report"
    )
    assert decl["parameters"]["properties"] == {}


def test_skill_grabs_the_latest_chat_image_and_runs_the_engine(monkeypatch):
    rows = [
        _FakeDoc({"image_path": "", "created_at": 3}),
        _FakeDoc({"image_path": "uploads/u9/photo.jpg", "created_at": 2}),
        _FakeDoc({"image_path": "uploads/u9/old.jpg", "created_at": 1}),
    ]
    reports = _FakeReports()

    monkeypatch.setattr(
        media_embed, "download_bytes", lambda p: (b"jpegbytes", "image/jpeg")
    )

    seen = {}

    async def _fake_run(image_bytes, mime, *, uid, source_path=None):
        seen.update(
            image_bytes=image_bytes, mime=mime, uid=uid, source_path=source_path
        )
        return dict(_RAW)

    monkeypatch.setattr(face_skill.engine, "run", _fake_run)

    fn = make_session_tool_fns(_FakeDb(rows, reports), "u9")["face_report"]
    out = _run(fn())

    assert seen == {
        "image_bytes": b"jpegbytes", "mime": "image/jpeg", "uid": "u9",
        "source_path": "uploads/u9/photo.jpg",
    }
    assert reports.added and reports.added[0]["image_path"] == "uploads/u9/photo.jpg"
    assert "6.9/10" in out
    assert out.strip().endswith("[face_report:report123]")


def test_skill_asks_for_a_photo_when_there_is_none(monkeypatch):
    reports = _FakeReports()
    fn = make_session_tool_fns(_FakeDb([], reports), "u9")["face_report"]
    out = _run(fn())
    assert "share a clear photo" in out
    assert not reports.added


def test_skill_does_not_store_or_mark_an_unusable_read(monkeypatch):
    rows = [_FakeDoc({"image_path": "uploads/u9/p.jpg", "created_at": 1})]
    reports = _FakeReports()
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda p: (b"jpegbytes", "image/jpeg")
    )

    async def _unusable(*a, **k):
        return {"usable": False}

    monkeypatch.setattr(face_skill.engine, "run", _unusable)
    fn = make_session_tool_fns(_FakeDb(rows, reports), "u9")["face_report"]
    out = _run(fn())

    assert "[face_report:" not in out
    assert not reports.added


def test_skill_reports_when_out_of_credits(monkeypatch):
    rows = [_FakeDoc({"image_path": "uploads/u9/p.jpg", "created_at": 1})]
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda p: (b"jpegbytes", "image/jpeg")
    )

    async def _capped(*a, **k):
        raise token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(face_skill.engine, "run", _capped)
    fn = make_session_tool_fns(_FakeDb(rows, _FakeReports()), "u9")["face_report"]
    out = _run(fn())
    assert "out of credits" in out


# --- POST /face-report -------------------------------------------------------

from fastapi.testclient import TestClient  # noqa: E402
from firebase_admin import auth as firebase_auth  # noqa: E402

import main  # noqa: E402

_client = TestClient(main.app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "me"}
    )
    return {"Authorization": "Bearer valid"}


class _EndpointDb:
    """Just enough to catch the face_reports write."""

    def __init__(self):
        self.added = []

    def collection(self, name):
        return self

    def document(self, _id):
        return self

    def add(self, payload):
        self.added.append(payload)
        return ("TS", type("R", (), {"id": "rep777"})())


def test_endpoint_runs_the_report_and_drops_a_pointer_into_chat(monkeypatch):
    monkeypatch.setattr(
        main, "_primary_profile_photo_path", lambda uid: "uploads/me/main.jpg"
    )
    monkeypatch.setattr(
        main.media_embed, "download_bytes", lambda p: (b"jpegbytes", "image/jpeg")
    )

    async def _fake_run(image_bytes, mime, *, uid, source_path=None):
        assert image_bytes == b"jpegbytes" and uid == "me"
        assert source_path == "uploads/me/main.jpg"
        return dict(_RAW)

    monkeypatch.setattr(main.face_report, "run", _fake_run)
    fake_db = _EndpointDb()
    monkeypatch.setattr(main, "get_db", lambda: fake_db)
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")

    appended = []
    monkeypatch.setattr(
        main.chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append((role, text)),
    )

    r = _client.post("/face-report", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    body = r.json()
    assert body["report"]["overall_score"] == 6.9
    assert body["report_id"] == "rep777"
    assert fake_db.added and fake_db.added[0]["report"]["verdict"] == "Above average"
    assert appended and appended[0][0] == "ayma"
    assert "6.9/10" in appended[0][1]


def test_endpoint_promotes_the_page_after_a_successful_self_run(monkeypatch):
    monkeypatch.setattr(
        main, "_primary_profile_photo_path", lambda uid: "uploads/me/main.jpg"
    )
    monkeypatch.setattr(
        main.media_embed, "download_bytes", lambda p: (b"jpegbytes", "image/jpeg")
    )

    async def _fake_run(image_bytes, mime, *, uid, source_path=None):
        return dict(_RAW)

    monkeypatch.setattr(main.face_report, "run", _fake_run)
    monkeypatch.setattr(main, "get_db", lambda: _EndpointDb())
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")
    monkeypatch.setattr(
        main.chat_history, "append", lambda *a, **k: None
    )

    saved, promoted = [], []
    monkeypatch.setattr(
        main.skill_memory, "save_face_analysis",
        lambda _db, uid, _rep: saved.append(uid),
    )
    monkeypatch.setattr(
        main.skill_memory, "promote",
        lambda _db, uid, pt: promoted.append((uid, pt)) or True,
    )

    r = _client.post("/face-report", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    assert saved == ["me"]
    assert promoted == [("me", "face_analysis")]


def test_endpoint_400_when_there_is_no_photo(monkeypatch):
    monkeypatch.setattr(
        main, "_primary_profile_photo_path", lambda uid: ""
    )
    r = _client.post("/face-report", headers=_auth(monkeypatch), json={})
    assert r.status_code == 400


def test_endpoint_403_for_someone_elses_attachment(monkeypatch):
    r = _client.post(
        "/face-report",
        headers=_auth(monkeypatch),
        json={"attachment_path": "uploads/other/x.jpg"},
    )
    assert r.status_code == 403
