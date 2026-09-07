import main
import photo_pipeline
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "u-7"}
    )
    return {"Authorization": "Bearer valid"}


def test_media_requires_a_token():
    resp = client.post("/media", json={"storage_path": "uploads/u-7/a.jpg"})
    assert resp.status_code in (401, 403)


def test_media_rejects_a_path_outside_the_callers_uploads(monkeypatch):
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/someone-else/a.jpg"},
    )
    assert resp.status_code == 403


def test_media_runs_the_pipeline_and_returns_its_status(monkeypatch):
    called = {}

    async def _fake_process(db, uid, storage_path, context, **kw):
        called.update(uid=uid, path=storage_path, context=context, kw=kw)
        return {
            "media_id": "media-xyz",
            "moderation_status": "approved",
            "published": True,
            "reason": "",
            "attributes": {"hair_color": "brown"},
            "caption": "a person outside",
        }

    monkeypatch.setattr(photo_pipeline, "process", _fake_process)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/profile_1.jpg", "context": "profile"},
    )
    assert resp.status_code == 200
    assert resp.json() == {
        "ok": True,
        "media_id": "media-xyz",
        "moderation_status": "approved",
        "published": True,
        "reason": "",
        "photo_attrs": {"hair_color": "brown"},
    }
    assert called["uid"] == "u-7"
    assert called["path"] == "uploads/u-7/profile_1.jpg"
    assert called["kw"]["wiki_uids"] == ["u-7"]


def test_media_reports_a_flagged_photo_without_publishing(monkeypatch):
    async def _flagged(db, uid, storage_path, context, **kw):
        return {
            "media_id": "m-flag",
            "moderation_status": "flagged",
            "published": False,
            "reason": "nudity",
            "attributes": None,
            "caption": "",
        }

    monkeypatch.setattr(photo_pipeline, "process", _flagged)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/bad.jpg", "context": "profile"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["published"] is False
    assert body["moderation_status"] == "flagged"
    assert body["reason"] == "nudity"


def test_media_schedules_auto_analysis_on_the_uploaded_photo(monkeypatch):
    seen = []

    async def _spy(_db, uid, storage_path):
        seen.append((uid, storage_path))

    monkeypatch.setattr(main.auto_analysis, "analyse_photo", _spy)

    async def _fake_process(db, uid, storage_path, context, **kw):
        return {
            "media_id": "m1",
            "moderation_status": "approved",
            "published": True,
            "reason": "",
            "attributes": {},
            "caption": "",
        }

    monkeypatch.setattr(photo_pipeline, "process", _fake_process)
    monkeypatch.setattr(main, "get_db", lambda: object())

    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/p.jpg", "context": "profile"},
    )
    assert resp.status_code == 200
    # TestClient drains background tasks after the response.
    assert seen == [("u-7", "uploads/u-7/p.jpg")]


def test_media_photos_add_schedules_auto_analysis(monkeypatch):
    import photo_ops

    seen = []

    async def _spy(_db, uid, storage_path):
        seen.append((uid, storage_path))

    monkeypatch.setattr(main.auto_analysis, "analyse_photo", _spy)
    monkeypatch.setattr(
        photo_ops, "add_photo", lambda db, uid, mid: [{"media_id": mid}]
    )
    monkeypatch.setattr(
        main, "_media_storage_path", lambda uid, mid: "uploads/u-7/grid.jpg"
    )
    monkeypatch.setattr(main, "get_db", lambda: object())

    resp = client.post(
        "/media/photos", headers=_auth(monkeypatch), json={"media_id": "m-42"}
    )
    assert resp.status_code == 200
    assert seen == [("u-7", "uploads/u-7/grid.jpg")]


def test_media_502_when_pipeline_fails(monkeypatch):
    async def _boom(*_a, **_k):
        raise RuntimeError("vertex is grumpy")

    monkeypatch.setattr(photo_pipeline, "process", _boom)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/x.jpg"},
    )
    assert resp.status_code == 502
