import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


def test_story_new_endpoints_require_auth():
    assert client.get("/story/section/career/provenance").status_code in (401, 403)


def test_retired_career_timeline_routes_are_gone():
    # The legacy career-timeline subsystem was deleted (Nov 16 2026); these
    # routes no longer exist (404), not merely auth-gated.
    assert client.get("/story/career-timeline").status_code == 404
    assert client.post("/story/career-timeline/refresh").status_code == 404
    assert client.post("/story/linkedin", json={"url": "x"}).status_code == 404


def test_provenance_endpoint_returns_the_resolved_sources(monkeypatch):
    headers = _auth(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(
        main.story, "get_section_provenance",
        lambda db, uid, page_id: {
            "page_id": page_id, "conversation_count": 2,
            "updated_at": "2026-09-03T00:00:00+00:00",
            "user_updated_at": None,
            "sources": [{"date": "2026-09-03T00:00:00+00:00"}],
        },
    )
    r = client.get("/story/section/career/provenance", headers=headers)
    assert r.status_code == 200
    assert r.json()["conversation_count"] == 2


def test_provenance_endpoint_404s_for_a_missing_section(monkeypatch):
    headers = _auth(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: object())

    def _raise(db, uid, page_id):
        raise KeyError(page_id)

    monkeypatch.setattr(main.story, "get_section_provenance", _raise)
    r = client.get("/story/section/nope/provenance", headers=headers)
    assert r.status_code == 404
