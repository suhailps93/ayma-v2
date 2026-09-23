import knowledge_wipe
import main
from fake_firestore import DELETE_FIELD, SERVER_TIMESTAMP, FakeDb
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def test_wiki_reset_archives_then_resets_the_learned_data(monkeypatch):
    monkeypatch.setattr(
        knowledge_wipe.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP
    )
    monkeypatch.setattr(knowledge_wipe.firestore, "DELETE_FIELD", DELETE_FIELD)

    db = FakeDb()
    db.docs[("users", "me")] = {"trust_flags": ["x"]}
    db.docs[("users", "me", "profile", "main")] = {"name": "Jo"}
    db.docs[("users", "me", "wiki_pages", "career")] = {"ai_body": "Nurse."}
    db.docs[("users", "me", "wiki_pages", "values")] = {"ai_body": "Kind."}
    db.docs[("users", "me", "raw_turns", "s1")] = {"turn_count": 2}
    db.docs[("users", "me", "raw_turns", "s2")] = {"turn_count": 1}
    db.docs[("users", "me", "raw_turns", "s3")] = {"turn_count": 4}
    db.docs[("users", "me", "pending_questions", "q1")] = {"status": "pending"}

    monkeypatch.setattr(main, "get_db", lambda: db)

    resp = client.post("/wiki/reset", headers=_auth(monkeypatch, uid="me"))
    assert resp.status_code == 200
    body = resp.json()
    assert body["ok"] is True
    assert body["archived"]["wiki_pages"] == 2
    assert body["archived"]["raw_turns"] == 3
    assert body["archived"]["pending_questions"] == 1

    # live "learned" collections cleared
    assert ("users", "me", "wiki_pages", "career") not in db.docs
    assert ("users", "me", "raw_turns", "s1") not in db.docs
    # profile untouched
    assert db.docs[("users", "me", "profile", "main")] == {"name": "Jo"}
    # archived for admin lookup, not reachable by the caller
    archive_id = body["archive_id"]
    assert db.docs[
        ("archived_knowledge", "me", "snapshots", archive_id, "wiki_pages", "career")
    ] == {"ai_body": "Nurse."}


def test_wiki_reset_requires_auth():
    assert client.post("/wiki/reset").status_code in (401, 403)
