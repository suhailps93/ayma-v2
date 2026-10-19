"""Shareable report snapshots (share.py, share_page.py, /share, /s/*)."""

import io
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth
from PIL import Image

import main
import ratelimit
import report_hub
import share
from config import CONFIG
from fake_firestore import SERVER_TIMESTAMP, FakeDb

client = TestClient(main.app)

REPORT = {
    "title": "Appearance <script>",
    "sections": [
        {
            "heading": "Overview",
            "blocks": [
                {"block_id": "s", "type": "stat", "label": "Score", "value": 7, "basis": "photos"},
                {"block_id": "t", "type": "text", "text": "Warm <b>smile</b>."},
                {"block_id": "p", "type": "photo", "url": "javascript:alert(1)"},
                {"block_id": "l", "type": "link", "url": "https://example.com/a", "label": "Src"},
            ],
        }
    ],
    "meta": {"owner_uid": "u1"},
}


@pytest.fixture(autouse=True)
def _env(monkeypatch):
    monkeypatch.setattr(share.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
    monkeypatch.setattr(report_hub, "get_report", lambda *_a: REPORT)


def _auth(monkeypatch, uid="u1"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


def test_create_is_idempotent_and_refreshes_snapshot():
    db = FakeDb()
    a = share.create(db, "u1", "appearance", "u1")
    b = share.create(db, "u1", "appearance", "u1")
    assert a["token"] == b["token"] and len(a["token"]) >= 40
    assert a["url"] == f"{CONFIG.share_base_url}/s/{a['token']}"
    assert a["summary"].startswith("Score: 7")
    assert len(db.docs) == 1


def test_create_rejects_unshareable_type_and_foreign_report():
    db = FakeDb()
    with pytest.raises(ValueError):
        share.create(db, "u1", "story_private", "u1")
    with pytest.raises(PermissionError):
        share.create(db, "someone-else", "deep_dive", "r1")


def test_revoke_blocks_public_and_new_share_mints_new_token():
    db = FakeDb()
    t = share.create(db, "u1", "appearance", "u1")["token"]
    with pytest.raises(PermissionError):
        share.revoke(db, "u2", t)
    share.revoke(db, "u1", t)
    share.revoke(db, "u1", t)
    assert share.fetch_public(db, t) is None
    assert share.create(db, "u1", "appearance", "u1")["token"] != t
    with pytest.raises(KeyError):
        share.revoke(db, "u1", "nope")


def test_deleted_owner_hides_share():
    db = FakeDb({("deleted_accounts", "u1"): {"x": 1}})
    t = share.create(db, "u1", "appearance", "u1")["token"]
    assert share.fetch_public(db, t) is None


def test_public_page_escapes_and_has_meta(monkeypatch):
    db = FakeDb()
    t = share.create(db, "u1", "appearance", "u1")["token"]
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = client.get(f"/s/{t}")
    assert r.status_code == 200
    body = r.text
    assert "<script>" not in body and "&lt;script&gt;" in body
    assert "<b>smile" not in body
    assert "javascript:" not in body
    assert f'og:image content="{CONFIG.share_base_url}/s/{t}/card.png"' in body
    assert "twitter:card" in body and "Google Play" in body
    assert "https://example.com/a" in body


def test_public_routes_404_for_unknown_token(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: FakeDb())
    for path in ("/s/nope", "/s/nope/data", "/s/nope/card.png"):
        assert client.get(path).status_code == 404


def test_data_and_card_sizes(monkeypatch):
    db = FakeDb()
    t = share.create(db, "u1", "appearance", "u1")["token"]
    monkeypatch.setattr(main, "get_db", lambda: db)
    data = client.get(f"/s/{t}/data").json()
    assert data["meta"]["viewer_can_edit"] is False and data["sections"]
    for fmt, size in (("link", (1200, 630)), ("story", (1080, 1920))):
        r = client.get(f"/s/{t}/card.png?format={fmt}")
        assert r.headers["content-type"] == "image/png"
        assert Image.open(io.BytesIO(r.content)).size == size
    assert client.get(f"/s/{t}/card.png?format=bad").status_code == 422


def test_share_endpoints_require_auth_and_create(monkeypatch):
    body = {"report_type": "appearance", "report_id": "u1"}
    assert client.post("/share", json=body).status_code in (401, 403)
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    h = _auth(monkeypatch)
    r = client.post("/share", json=body, headers=h)
    assert r.status_code == 200 and r.json()["token"]
    bad = client.post(
        "/share", json={"report_type": "story_private", "report_id": "u1"}, headers=h
    )
    assert bad.status_code == 400
    token = {"token": r.json()["token"]}
    h2 = _auth(monkeypatch, "u2")
    assert client.post("/share/revoke", json=token, headers=h2).status_code == 403
    h = _auth(monkeypatch)
    assert client.post("/share/revoke", json=token, headers=h).status_code == 200


def test_assetlinks(monkeypatch):
    assert client.get("/.well-known/assetlinks.json").status_code == 404
    monkeypatch.setattr(
        main, "CONFIG", replace(CONFIG, share_assetlinks_sha256=("AA:BB",))
    )
    body = client.get("/.well-known/assetlinks.json").json()
    assert body[0]["target"]["sha256_cert_fingerprints"] == ["AA:BB"]
    assert body[0]["target"]["package_name"] == CONFIG.share_android_package


def test_public_routes_have_own_rate_limit():
    assert ratelimit.rate_for("/s/abc") == CONFIG.rate_share_public
    assert ratelimit.rate_for("/s/abc/card.png") == CONFIG.rate_share_public
    assert ratelimit.rate_for("/share") == CONFIG.rate_share
