from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

from main import app

client = TestClient(app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "u-42"}
    )
    return {"Authorization": "Bearer valid"}


def test_post_turn_requires_a_token():
    resp = client.post("/post-turn", json={"session_id": "s-1"})
    assert resp.status_code in (401, 403)


def test_post_turn_persists_the_window(monkeypatch, no_firestore):
    resp = client.post(
        "/post-turn",
        headers=_auth(monkeypatch),
        json={
            "session_id": "s-xyz-1",
            "recent_turns": [
                {"role": "user", "text": "we spoke earlier"},
                {"role": "ayma", "text": "we did"},
            ],
        },
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True, "persisted": 2}
    assert no_firestore.persisted == [
        {
            "uid": "u-42",
            "session_id": "s-xyz-1",
            "turns": no_firestore.persisted[0]["turns"],
        }
    ]
    assert [(t.role, t.text) for t in no_firestore.persisted[0]["turns"]] == [
        ("user", "we spoke earlier"),
        ("ayma", "we did"),
    ]


def test_post_turn_rejects_a_bad_session_id(monkeypatch):
    resp = client.post(
        "/post-turn",
        headers=_auth(monkeypatch),
        json={"session_id": "bad id!", "recent_turns": []},
    )
    assert resp.status_code == 422
