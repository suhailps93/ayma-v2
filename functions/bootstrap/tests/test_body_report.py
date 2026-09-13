import asyncio

import body_report
import gemini
import media_embed
import pytest
import token_ledger
from skills import make_session_tool_fns, session_tool_declarations
from skills import body_report as body_skill


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


_RAW = {
    "usable": True,
    "overall_score": 6.4,
    "verdict": "Solid base",
    "verdict_note": "Good frame, needs more back width and lower body fat.",
    "features": [
        {"name": "frame", "score": 7.5, "note": "Broad clavicles, good structure."},
        {"name": "leanness", "score": 5.0, "note": "Soft midsection, ~18% body fat."},
        {"name": "v_taper", "score": 6.0, "note": "Waist a touch wide for the shoulders."},
    ],
    "quick_facts": {
        "body_type": "mesomorph",
        "est_height_impression": "tall",
        "build": "athletic",
        "estimated_body_fat_range": "16-19%",
        "dominant_strength": "shoulder frame",
        "weakest_area": "midsection",
        "frame_size": "large",
    },
    "strengths": ["Naturally wide shoulder frame", "Upright, confident posture"],
    "improvements": ["Drop body fat to sharpen the waist", "Build back width"],
    "recommendations": [
        {"category": "training", "text": "Add horizontal rows and lat pulldowns."},
        {"category": "nutrition", "text": "Mild deficit, ~200 kcal, high protein."},
    ],
}


@pytest.fixture
def _patch_json(monkeypatch):
    async def _json(contents, system_prompt, response_schema=None, image=None, **kw):
        assert image is not None and image[0] == b"jpegbytes"
        assert kw.get("feature") == token_ledger.FEATURE_BODY_REPORT
        return dict(_RAW)

    monkeypatch.setattr(gemini, "generate_json", _json)


def test_run_returns_the_structured_shape(_patch_json):
    r = _run(body_report.run(b"jpegbytes", "image/jpeg", uid="u1"))
    assert r["usable"] is True
    assert r["overall_score"] == 6.4
    assert r["verdict"] == "Solid base"
    assert [f["name"] for f in r["features"]] == ["frame", "leanness", "v_taper"]
    assert r["quick_facts"]["body_type"] == "mesomorph"
    assert r["strengths"][0].startswith("Naturally wide")
    assert r["recommendations"][0]["category"] == "training"


def test_run_rejects_empty_bytes():
    with pytest.raises(ValueError):
        _run(body_report.run(b"", "image/jpeg", uid="u1"))


def test_run_echoes_the_source_photo(_patch_json):
    r = _run(
        body_report.run(
            b"jpegbytes", "image/jpeg", uid="u1", source_path="uploads/u1/a.jpg"
        )
    )
    assert r["source_photos"] == ["uploads/u1/a.jpg"]


def test_run_without_a_source_path_has_no_source_photos(_patch_json):
    r = _run(body_report.run(b"jpegbytes", "image/jpeg", uid="u1"))
    assert r["source_photos"] == []


def test_render_summarises_the_read():
    text = body_report.render({**_RAW})
    assert "6.4/10" in text
    assert "Solid base" in text
    assert "Naturally wide shoulder frame" in text
    assert "Build back width" in text
    assert "Open the full report" not in text


def test_render_handles_an_unusable_photo():
    text = body_report.render({"usable": False})
    assert "full-length" in text
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
        if name == "body_reports":
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
        d for d in session_tool_declarations() if d["name"] == "body_report"
    )
    assert decl["parameters"]["properties"] == {}


def test_skill_grabs_the_latest_chat_image_and_runs_the_engine(monkeypatch):
    rows = [
        _FakeDoc({"image_path": "", "created_at": 3}),
        _FakeDoc({"image_path": "uploads/u9/body.jpg", "created_at": 2}),
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

    monkeypatch.setattr(body_skill.engine, "run", _fake_run)

    fn = make_session_tool_fns(_FakeDb(rows, reports), "u9")["body_report"]
    out = _run(fn())

    assert seen == {
        "image_bytes": b"jpegbytes", "mime": "image/jpeg", "uid": "u9",
        "source_path": "uploads/u9/body.jpg",
    }
    assert reports.added and reports.added[0]["image_path"] == "uploads/u9/body.jpg"
    assert "6.4/10" in out
    assert out.strip().endswith("[body_report:report123]")


def test_skill_asks_for_a_photo_when_there_is_none(monkeypatch):
    reports = _FakeReports()
    fn = make_session_tool_fns(_FakeDb([], reports), "u9")["body_report"]
    out = _run(fn())
    assert "share a clear full-length photo" in out
    assert not reports.added


def test_skill_does_not_store_or_mark_an_unusable_read(monkeypatch):
    rows = [_FakeDoc({"image_path": "uploads/u9/p.jpg", "created_at": 1})]
    reports = _FakeReports()
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda p: (b"jpegbytes", "image/jpeg")
    )

    async def _unusable(*a, **k):
        return {"usable": False}

    monkeypatch.setattr(body_skill.engine, "run", _unusable)
    fn = make_session_tool_fns(_FakeDb(rows, reports), "u9")["body_report"]
    out = _run(fn())

    assert "[body_report:" not in out
    assert not reports.added


def test_skill_reports_when_out_of_credits(monkeypatch):
    rows = [_FakeDoc({"image_path": "uploads/u9/p.jpg", "created_at": 1})]
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda p: (b"jpegbytes", "image/jpeg")
    )

    async def _capped(*a, **k):
        raise token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(body_skill.engine, "run", _capped)
    fn = make_session_tool_fns(_FakeDb(rows, _FakeReports()), "u9")["body_report"]
    out = _run(fn())
    assert "out of credits" in out


# --- POST /body-report -----------------------------------------------------

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

    monkeypatch.setattr(main.body_report, "run", _fake_run)
    fake_db = _EndpointDb()
    monkeypatch.setattr(main, "get_db", lambda: fake_db)
    monkeypatch.setattr(main, "_server_ts", lambda: "TS")

    appended = []
    monkeypatch.setattr(
        main.chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append((role, text)),
    )

    r = _client.post("/body-report", headers=_auth(monkeypatch), json={})
    assert r.status_code == 200
    body = r.json()
    assert body["report"]["overall_score"] == 6.4
    assert body["report_id"] == "rep777"
    assert fake_db.added and fake_db.added[0]["report"]["verdict"] == "Solid base"
    assert appended and appended[0][0] == "ayma"
    assert "6.4/10" in appended[0][1]


def test_endpoint_400_when_there_is_no_photo(monkeypatch):
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda uid: "")
    r = _client.post("/body-report", headers=_auth(monkeypatch), json={})
    assert r.status_code == 400
