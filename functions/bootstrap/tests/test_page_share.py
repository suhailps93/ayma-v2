"""Reusable page-share links (page_share.py, page_share_page.py,
POST /share-link, /p/*). Profile is the first public kind; story is
Ayma-only and can never get a link."""

import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import main
import page_share
import page_share_page
import public_profile
from config import CONFIG
from fake_firestore import SERVER_TIMESTAMP, FakeDb

client = TestClient(main.app)

VIEW = {
    "uid": "u2",
    "deleted": False,
    "self": False,
    "blocked": False,
    "name": "Dillu <b>",
    "age": 30,
    "gender": "female",
    "location": "San Jose, United States",
    "online": True,
    "photos": ["https://example.com/p1.jpg", "https://example.com/p2.jpg"],
    "photos_thumb": [],
    "photos_medium": [],
    "pages": [
        {"page_type": "identity", "title": "Identity", "body": "Goes by Dillu."},
        {"page_type": "interests", "title": "Interests", "body": "Man City."},
    ],
    "score": 87.5,
    "liked": True,
    "deep_dive_id": "dive1",
    "physical_attributes": {"height": "secret"},
    "thread_id": "pairkey",
    "has_chatted": True,
}


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setattr(page_share.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
    monkeypatch.setattr(public_profile, "build", lambda db, caller, other: VIEW)


def _auth(monkeypatch, uid="u1"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer <redacted>"}


def test_create_profile_link_is_idempotent_and_public_only():
    db = FakeDb()
    a = page_share.create(db, "u1", "profile", "u2")
    b = page_share.create(db, "u1", "profile", "u2")
    assert a["token"] == b["token"] and len(a["token"]) >= 40
    assert a["url"] == f"{CONFIG.share_base_url}/p/{a['token']}"
    assert a["title"] == "Dillu <b> on Ayma"
    assert a["summary"] == "Dillu <b> · 30 · San Jose, United States"
    pub = page_share.fetch_public(db, a["token"])
    snap = pub["snapshot"]
    # Only public fields are frozen into the snapshot.
    assert set(snap) == {"name", "age", "location", "photo_url", "photos", "sections"}
    assert snap["photo_url"] == "https://example.com/p1.jpg"
    assert [s["title"] for s in snap["sections"]] == ["Identity", "Interests"]
    # The public payload never carries the owner or caller-relative data.
    assert "owner_uid" not in pub and "score" not in pub and "thread_id" not in pub


def test_ayma_only_and_unknown_kinds_are_refused():
    db = FakeDb()
    for kind in ("story", "story_private", "nope"):
        with pytest.raises(ValueError):
            page_share.create(db, "u1", kind, "u2")
    assert db.docs == {}


def test_blocked_and_missing_profiles_are_refused(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(
        public_profile, "build", lambda db, caller, other: {**VIEW, "blocked": True}
    )
    with pytest.raises(PermissionError):
        page_share.create(db, "u1", "profile", "u2")
    monkeypatch.setattr(public_profile, "build", lambda db, caller, other: None)
    with pytest.raises(KeyError):
        page_share.create(db, "u1", "profile", "ghost")


def test_revoke_kills_the_link(monkeypatch):
    db = FakeDb()
    t = page_share.create(db, "u1", "profile", "u2")["token"]
    with pytest.raises(PermissionError):
        page_share.revoke(db, "u2", t)
    page_share.revoke(db, "u1", t)
    assert page_share.fetch_public(db, t) is None
    assert page_share.create(db, "u1", "profile", "u2")["token"] != t


def test_landing_page_routes_by_platform_and_stays_public(monkeypatch):
    db = FakeDb()
    t = page_share.create(db, "u1", "profile", "u2")["token"]
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = client.get(f"/p/{t}")
    assert r.status_code == 200
    body = r.text
    # Teaser: public fields, escaped.
    assert "Dillu &lt;b&gt;" in body and "Goes by Dillu." in body
    assert "https://example.com/p1.jpg" in body
    # Nothing caller-relative or private leaks into the page.
    for leaked in ("87.5", "pairkey", "dive1", "secret", "physical"):
        assert leaked not in body
    # Platform routing: Android intent + Play fallback carrying the token,
    # iOS store URL (TestFlight while no store id is configured).
    assert "intent://" in body and CONFIG.share_android_package in body
    assert "ayma_page%3D" + t in body or "ayma_page=" + t in body
    assert page_share_page.ios_store_url() in body
    assert "detectOS" in body
    data = client.get(f"/p/{t}/data").json()
    assert data == {
        "kind": "profile",
        "target_id": "u2",
        "title": "Dillu <b> on Ayma",
        "summary": "Dillu <b> · 30 · San Jose, United States",
    }


def test_public_routes_404_for_unknown_token(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: FakeDb())
    assert client.get("/p/nope").status_code == 404
    assert client.get("/p/nope/data").status_code == 404


def test_share_link_endpoint_requires_auth_and_refuses_story(monkeypatch):
    body = {"kind": "profile", "target_id": "u2"}
    assert client.post("/share-link", json=body).status_code in (401, 403)
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    h = _auth(monkeypatch)
    r = client.post("/share-link", json=body, headers=h)
    assert r.status_code == 200 and r.json()["url"].startswith(
        f"{CONFIG.share_base_url}/p/"
    )
    story = client.post(
        "/share-link", json={"kind": "story", "target_id": "u1"}, headers=h
    )
    assert story.status_code == 400
