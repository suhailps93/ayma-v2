import main
import photo_notes
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


def test_photo_note_requires_auth():
    assert client.put("/wiki/photo-note", json={"url": "https://x/1.jpg"}).status_code in (401, 403)


def test_photo_note_sets_context_and_is_user(monkeypatch):
    calls = []
    monkeypatch.setattr(
        photo_notes, "set_context",
        lambda db, uid, url, **kw: calls.append((uid, url, kw)) or
        {"context": kw.get("context", ""), "is_user": kw.get("is_user", ""), "hidden": False},
    )
    r = client.put(
        "/wiki/photo-note",
        json={"url": "https://x/1.jpg", "context": "my grad photo", "is_user": "yes"},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["context"] == "my grad photo"
    assert calls == [("me", "https://x/1.jpg",
                       {"context": "my grad photo", "is_user": "yes"})]


def test_photo_note_bad_is_user_is_400(monkeypatch):
    def _raise(*_a, **_kw):
        raise ValueError("is_user must be '', 'yes' or 'no'")
    monkeypatch.setattr(photo_notes, "set_context", _raise)
    r = client.put(
        "/wiki/photo-note",
        json={"url": "https://x/1.jpg", "is_user": "maybe"},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 400


def test_photo_hide_calls_through(monkeypatch):
    calls = []
    monkeypatch.setattr(
        photo_notes, "hide_photo",
        lambda db, uid, url, **kw: calls.append((uid, url, kw)),
    )
    r = client.post(
        "/wiki/photo-hide",
        json={"url": "https://x/1.jpg", "source": "profile"},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 200
    assert r.json() == {"ok": True}
    assert calls == [("me", "https://x/1.jpg", {"source": "profile"})]


async def _fake_publish_ok(db, uid, url, *, source):
    return {"published": True, "media_id": "m1"}


def test_photo_publish_calls_through(monkeypatch):
    monkeypatch.setattr(photo_notes, "publish_photo", _fake_publish_ok)
    r = client.post(
        "/wiki/photo-publish",
        json={"url": "https://x/1.jpg", "source": "chat"},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 200
    assert r.json() == {"ok": True, "published": True, "media_id": "m1"}


def test_photo_publish_bad_input_is_400(monkeypatch):
    async def _raise(*_a, **_kw):
        raise ValueError("url is required")
    monkeypatch.setattr(photo_notes, "publish_photo", _raise)
    r = client.post(
        "/wiki/photo-publish",
        json={"url": "https://x/1.jpg", "source": "chat"},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 400
