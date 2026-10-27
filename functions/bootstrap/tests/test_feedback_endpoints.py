import auth
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def _dev_auth(monkeypatch, uid="dev"):
    monkeypatch.setattr(
        firebase_auth,
        "verify_id_token",
        lambda _t: {"uid": uid, "email": "dev@x", "email_verified": True},
    )
    monkeypatch.setattr(auth, "is_dev_token", lambda _d: True)
    return {"Authorization": "Bearer valid"}


def test_feedback_requires_auth():
    assert client.post("/feedback", json={}).status_code in (401, 403)
    assert client.post(
        "/feedback/submit", json={"body": "x"}
    ).status_code in (401, 403)


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


def test_feedback_submit_persists_a_bug_with_screenshot(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        main.feedback_ops, "record_submission",
        lambda db, uid, kind, title, body, **kw: seen.update(
            uid=uid, kind=kind, title=title, body=body, **kw
        ) or "p-1",
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/feedback/submit",
        headers=_auth(monkeypatch, uid="u1"),
        json={
            "kind": "bug",
            "title": "Orb flickers",
            "body": "orb flickers on the messages tab",
            "screenshot_paths": ["uploads/u1/feedback_1.png"],
            "screen": "messages",
            "app_version": "1.30.0",
            "platform": "android",
            "source": "chat_card",
        },
    )
    assert resp.json() == {"ok": True, "id": "p-1"}
    assert seen["kind"] == "bug"
    assert seen["title"] == "Orb flickers"
    assert seen["source"] == "chat_card"
    assert seen["screenshot_paths"] == ["uploads/u1/feedback_1.png"]
    assert seen["screen"] == "messages"
    assert seen["platform"] == "android"


def test_feedback_submit_persists_without_screenshot(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        main.feedback_ops, "record_submission",
        lambda db, uid, kind, title, body, **kw: seen.update(
            kind=kind, **kw
        ) or "p-2",
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/feedback/submit",
        headers=_auth(monkeypatch, uid="u1"),
        json={
            "kind": "feature",
            "title": "Dark map",
            "body": "a dark theme for the explore map",
            "source": "settings_form",
        },
    )
    assert resp.json() == {"ok": True, "id": "p-2"}
    assert seen["kind"] == "feature"
    assert seen["source"] == "settings_form"
    assert seen["screenshot_paths"] == []


def test_feedback_submit_rejects_a_foreign_upload_path(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/feedback/submit",
        headers=_auth(monkeypatch, uid="u1"),
        json={"body": "x", "screenshot_paths": ["uploads/someone-else/x.png"]},
    )
    assert resp.status_code == 403


def test_admin_feedback_list_requires_dev(monkeypatch):
    # A signed-in but non-dev caller is refused.
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "u1"}
    )
    monkeypatch.setattr(auth, "is_dev_token", lambda _d: False)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.get(
        "/admin/feedback", headers={"Authorization": "Bearer valid"}
    )
    assert resp.status_code == 403


def test_admin_feedback_list_returns_rows_for_a_dev(monkeypatch):
    rows = [{"id": "p-1", "kind": "bug", "title": "x", "status": "new"}]
    monkeypatch.setattr(
        main.feedback_ops, "list_submissions",
        lambda db, **kw: rows,
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.get("/admin/feedback", headers=_dev_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json() == {"feedback": rows}


def test_admin_feedback_status_update(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        main.feedback_ops, "set_submission_status",
        lambda db, fid, status: seen.update(fid=fid, status=status) or True,
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/admin/feedback/p-1",
        headers=_dev_auth(monkeypatch),
        json={"status": "triaged"},
    )
    assert resp.status_code == 200
    assert seen == {"fid": "p-1", "status": "triaged"}


def test_admin_feedback_status_unknown_row_is_404(monkeypatch):
    monkeypatch.setattr(
        main.feedback_ops, "set_submission_status", lambda db, fid, status: False
    )
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/admin/feedback/nope",
        headers=_dev_auth(monkeypatch),
        json={"status": "done"},
    )
    assert resp.status_code == 404
