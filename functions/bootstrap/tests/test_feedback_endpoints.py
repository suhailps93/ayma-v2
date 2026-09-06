import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def test_feedback_requires_auth():
    assert client.post("/feedback", json={}).status_code in (401, 403)
    assert client.post("/product-feedback", json={"text": "x"}).status_code in (
        401, 403,
    )


def test_feedback_records_a_thumbs_down(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        main.feedback_ops, "record",
        lambda db, uid, category, note, **kw: seen.update(
            uid=uid, category=category, note=note, **kw
        ) or "f-1",
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/feedback",
        headers=_auth(monkeypatch, uid="u1"),
        json={"category": "thumbs_down", "quote": "That felt canned."},
    )
    assert resp.json() == {"ok": True, "id": "f-1"}
    assert seen["uid"] == "u1"
    assert seen["source"] == "thumbs_down"
    assert seen["quote"] == "That felt canned."


def test_product_feedback_stores_bug_with_screenshots(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        main.feedback_ops, "record_product",
        lambda db, uid, kind, text, paths, **kw: seen.update(
            uid=uid, kind=kind, text=text, paths=paths, **kw
        ) or "p-1",
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/product-feedback",
        headers=_auth(monkeypatch, uid="u1"),
        json={
            "kind": "bug",
            "text": "orb flickers on the messages tab",
            "image_paths": ["uploads/u1/feedback_1.png"],
            "app_version": "1.4.0",
        },
    )
    assert resp.json() == {"ok": True, "id": "p-1"}
    assert seen["kind"] == "bug"
    assert seen["paths"] == ["uploads/u1/feedback_1.png"]
    assert seen["app_version"] == "1.4.0"


def test_product_feedback_rejects_a_foreign_upload_path(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/product-feedback",
        headers=_auth(monkeypatch, uid="u1"),
        json={"text": "x", "image_paths": ["uploads/someone-else/x.png"]},
    )
    assert resp.status_code == 403
