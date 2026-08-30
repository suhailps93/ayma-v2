import main
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


def test_media_embeds_and_returns_the_media_id(monkeypatch):
    called = {}

    def _fake_process(db, uid, storage_path, context):
        called.update(uid=uid, path=storage_path, context=context)
        return "media-xyz"

    monkeypatch.setattr(main, "process_media", _fake_process)
    monkeypatch.setattr(
        main.media_embed, "download_bytes", lambda p: (b"IMG", "image/jpeg")
    )

    async def _attrs(*a, **k):
        return {"hair_color": "brown"}

    monkeypatch.setattr(main.photo_attrs, "extract_attributes", _attrs)

    class _P:
        def collection(self, *_):
            return self

        def document(self, *_):
            return self

        def set(self, *a, **k):
            pass

    monkeypatch.setattr(main, "get_db", lambda: _P())
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/profile_1.jpg", "context": "profile"},
    )
    assert resp.status_code == 200
    assert resp.json() == {
        "ok": True, "media_id": "media-xyz", "photo_attrs": {"hair_color": "brown"}
    }
    assert called == {
        "uid": "u-7",
        "path": "uploads/u-7/profile_1.jpg",
        "context": "profile",
    }


def test_media_502_when_embedding_fails(monkeypatch):
    def _boom(*_a, **_k):
        raise RuntimeError("vertex is grumpy")

    monkeypatch.setattr(main, "process_media", _boom)
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/x.jpg"},
    )
    assert resp.status_code == 502
