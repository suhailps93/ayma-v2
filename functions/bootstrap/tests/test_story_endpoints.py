import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


def test_story_new_endpoints_require_auth():
    assert client.get("/story/section/career/provenance").status_code in (401, 403)
    assert client.get("/story/career-timeline").status_code in (401, 403)
    assert client.post("/story/career-timeline/refresh").status_code in (401, 403)
    assert client.post("/story/linkedin", json={"url": "x"}).status_code in (401, 403)


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


def test_get_career_timeline_returns_the_built_result(monkeypatch):
    headers = _auth(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: object())

    async def _get_or_build(db, uid):
        return {
            "entries": [{"id": "e1", "kind": "work", "org": "Figure AI"}],
            "overall_confidence": "high", "show_timeline": True,
            "linkedin_url": "",
        }

    monkeypatch.setattr(main.career_timeline, "get_or_build_timeline", _get_or_build)
    r = client.get("/story/career-timeline", headers=headers)
    assert r.status_code == 200
    body = r.json()
    assert body["show_timeline"] is True
    assert body["entries"][0]["org"] == "Figure AI"


def test_refresh_career_timeline_calls_extract(monkeypatch):
    headers = _auth(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: object())
    seen = {}

    async def _extract(db, uid):
        seen["uid"] = uid
        return {"entries": [], "overall_confidence": "none", "show_timeline": False}

    monkeypatch.setattr(main.career_timeline, "extract", _extract)
    r = client.post("/story/career-timeline/refresh", headers=headers)
    assert r.status_code == 200
    assert r.json()["show_timeline"] is False
    assert seen["uid"] == "me"


def test_set_linkedin_url_success(monkeypatch):
    headers = _auth(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(
        main.career_timeline, "set_linkedin_url",
        lambda db, uid, url: url,
    )
    r = client.post(
        "/story/linkedin",
        json={"url": "https://www.linkedin.com/in/jane-doe/"},
        headers=headers,
    )
    assert r.status_code == 200
    assert r.json()["linkedin_url"] == "https://www.linkedin.com/in/jane-doe/"


def test_set_linkedin_url_rejects_bad_url(monkeypatch):
    headers = _auth(monkeypatch)
    monkeypatch.setattr(main, "get_db", lambda: object())

    def _raise(db, uid, url):
        raise ValueError("that doesn't look like a linkedin.com URL")

    monkeypatch.setattr(main.career_timeline, "set_linkedin_url", _raise)
    r = client.post(
        "/story/linkedin", json={"url": "https://example.com"}, headers=headers
    )
    assert r.status_code == 400
