"""Taste match powered by Qloo (Qloo hackathon).

Offline and deterministic: the bundled fixture stands in for Qloo, and a fake
live client proves the live wire shape, the fallback, and that only PUBLIC
Taste-page names ever reach Qloo.
"""

from __future__ import annotations

import asyncio
import json

import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import age_gate
import main
import practice_seed
import public_profile
import qloo_client
import taste_match
from fake_firestore import FakeDb

client = TestClient(main.app)
MAYA, LEO = "demo_practice_maya", "demo_practice_leo"


@pytest.fixture
def db(monkeypatch):
    fake = FakeDb()
    practice_seed.seed(fake)
    monkeypatch.setattr(taste_match, "get_db", lambda: fake)
    monkeypatch.delenv("QLOO_API_KEY", raising=False)
    taste_match._demo_cache.clear()
    return fake


def _pair(db, a, b):
    return (
        taste_match.taste_from_view(public_profile.build(db, b, a)),
        taste_match.taste_from_view(public_profile.build(db, a, b)),
    )


def test_parse_taste_handles_aliases_separators_and_dupes():
    body = "Music: Khruangbin, Bon Iver, Khruangbin · Movies: Arrival\nFood: Ramen Shop.\nPets: cats"
    assert taste_match.parse_taste(body) == {
        "music": ["Khruangbin", "Bon Iver"],
        "film": ["Arrival"],
        "dining": ["Ramen Shop"],
    }
    assert taste_match.parse_taste("no structure here") == {}


def test_fixture_match_returns_score_summary_and_date_ideas(db):
    result = asyncio.run(taste_match.match(*_pair(db, MAYA, LEO)))
    assert result["source"] == "fixture"
    assert 0 <= result["score"] <= 100
    assert result["score_label"]
    assert "Maya" in result["summary"] and "Leo" in result["summary"]
    # Both listed Khruangbin and Spirited Away outright.
    assert "Khruangbin" in result["shared"] and "Spirited Away" in result["shared"]
    assert {d["domain"] for d in result["domains"]} == {"music", "film", "dining"}
    kinds = [i["kind"] for i in result["date_ideas"]]
    assert "dining" in kinds and "film" in kinds and "music" in kinds
    # Date spots are near the first person (San Francisco) in the fixture.
    assert all(
        "San Francisco" in i["address"] for i in result["date_ideas"] if i["kind"] == "dining"
    )


def test_scores_differ_across_pairs_and_are_deterministic(db):
    scores = {
        (a, b): asyncio.run(taste_match.match(*_pair(db, a, b)))["score"]
        for a, b in [(MAYA, LEO), (MAYA, "demo_practice_noah")]
    }
    assert len(set(scores.values())) == 2
    again = asyncio.run(taste_match.match(*_pair(db, MAYA, LEO)))["score"]
    assert again == scores[(MAYA, LEO)]


def test_no_taste_page_raises(db):
    db.collection("users").document(LEO).collection("wiki_pages").document("taste").set(
        {"visibility": "private", "page_type": "taste", "title": "Taste", "ai_body": "Music: Monk"}
    )
    with pytest.raises(taste_match.NoTaste):
        taste_match.taste_from_view(public_profile.build(db, MAYA, LEO))


class _RecordingLive(qloo_client.FixtureQlooClient):
    """Fixture-backed stand-in that records every name/query sent to 'Qloo'."""

    source = "qloo"

    def __init__(self, fail=False):
        super().__init__()
        self.sent: list[str] = []
        self.fail = fail

    def search(self, name, entity_type):
        self.sent.append(name)
        if self.fail:
            raise qloo_client.QlooError("boom")
        return super().search(name, entity_type)


def test_only_public_taste_names_reach_qloo(db):
    live = _RecordingLive()
    result = asyncio.run(taste_match.match(*_pair(db, MAYA, LEO), client=live))
    assert result["source"] == "qloo"
    sent = " ".join(live.sent)
    for needle in practice_seed.all_secrets():
        assert needle not in sent


def test_live_failure_falls_back_to_fixture(db):
    result = asyncio.run(
        taste_match.match(*_pair(db, MAYA, LEO), client=_RecordingLive(fail=True))
    )
    assert result["source"] == "fixture" and result["date_ideas"]


def test_live_client_wire_shape(monkeypatch):
    calls = []

    class _Resp:
        def __init__(self, payload):
            self._b = json.dumps(payload).encode()

        def read(self):
            return self._b

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout):
        calls.append((req.full_url, req.headers.get("X-api-key")))
        if "/search" in req.full_url:
            return _Resp({"results": [{"entity_id": "E1", "name": "Khruangbin"}]})
        return _Resp(
            {
                "results": {
                    "entities": [
                        {
                            "entity_id": "P1",
                            "name": "Yoshi's",
                            "query": {"affinity": 0.91},
                            "tags": [{"name": "Jazz"}],
                            "properties": {"address": "510 Embarcadero W"},
                        }
                    ]
                }
            }
        )

    monkeypatch.setattr(qloo_client.urllib.request, "urlopen", fake_urlopen)
    live = qloo_client.LiveQlooClient("k", "https://q.example", 3)
    assert live.search("Khruangbin", "urn:entity:artist")["id"] == "E1"
    recs = live.insights("urn:entity:place", ["E1"], location="Oakland", take=3)
    assert recs == [
        {"id": "P1", "name": "Yoshi's", "affinity": 0.91, "tags": ["Jazz"], "address": "510 Embarcadero W"}
    ]
    assert all(key == "k" for _, key in calls)
    assert "signal.interests.entities=E1" in calls[1][0]
    assert "filter.location.query=Oakland" in calls[1][0]


def test_get_client_uses_key_when_present(monkeypatch):
    monkeypatch.delenv("QLOO_API_KEY", raising=False)
    assert isinstance(qloo_client.get_client(), qloo_client.FixtureQlooClient)
    monkeypatch.setenv("QLOO_API_KEY", "x")
    assert isinstance(qloo_client.get_client(), qloo_client.LiveQlooClient)


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
def test_demo_page_and_pair_are_public(db):
    page = client.get("/taste/demo")
    assert page.status_code == 200 and "Qloo" in page.text
    resp = client.get("/taste/demo/pair", params={"a": "maya", "b": "aisha"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["a"]["name"] == "Maya" and body["b"]["name"] == "Aisha"


def test_demo_pair_refuses_non_demo_ids(db):
    assert client.get("/taste/demo/pair", params={"a": "maya", "b": "someone"}).status_code == 404
    assert client.get("/taste/demo/pair", params={"a": "maya", "b": "maya"}).status_code == 404


def _auth(monkeypatch, uid):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    monkeypatch.setattr(age_gate, "enforce", lambda *a, **k: None)
    return {"Authorization": "Bearer valid"}


def test_pair_endpoint_between_caller_and_match(db, monkeypatch):
    resp = client.post("/taste/pair", json={"other_uid": LEO}, headers=_auth(monkeypatch, MAYA))
    assert resp.status_code == 200
    assert resp.json()["b"]["name"] == "Leo"


def test_pair_endpoint_no_taste_is_404_with_code(db, monkeypatch):
    user = db.collection("users").document("fresh")
    user.collection("profile").document("main").set({"name": "Sam", "birthdate": "1990-01-01"})
    resp = client.post("/taste/pair", json={"other_uid": LEO}, headers=_auth(monkeypatch, "fresh"))
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "no_taste"
    assert "Sam" in resp.json()["detail"]["message"]


def test_pair_endpoint_requires_auth(db):
    assert client.post("/taste/pair", json={"other_uid": LEO}).status_code in (401, 403)


# --------------------------------------------------------------------------- #
# Match-report taste section (GET /match/{id} → "taste")
# --------------------------------------------------------------------------- #
def test_report_section_ok_has_status_score_and_ideas(db):
    section = asyncio.run(taste_match.report_section(db, MAYA, LEO))
    assert section["status"] == "ok"
    assert section["source"] == "fixture"
    assert 0 <= section["score"] <= 100
    assert {d["domain"] for d in section["domains"]} == {"music", "film", "dining"}
    assert section["date_ideas"]


def test_report_section_no_taste_degrades_without_error(db):
    user = db.collection("users").document("fresh")
    user.collection("profile").document("main").set(
        {"name": "Sam", "birthdate": "1990-01-01"}
    )
    section = asyncio.run(taste_match.report_section(db, "fresh", LEO))
    assert section["status"] == "no_taste"
    assert "Sam" in section["message"]


def test_match_report_endpoint_embeds_taste_section(db, monkeypatch):
    import pair_key

    key = pair_key.sorted_pair_key(MAYA, LEO)
    db.collection("matches").document(key).set({"score": 0.8, "updated_at": "TS"})
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main, "_primary_profile_photo_path", lambda u: f"p/{u}")
    monkeypatch.setattr(main.story, "_photo_url_safe", lambda sp: f"https://cdn/{sp}")
    monkeypatch.setattr(main, "_profile_full_name", lambda u: "Leo")

    resp = client.get(f"/match/{key}", headers=_auth(monkeypatch, MAYA))
    assert resp.status_code == 200
    taste = resp.json()["taste"]
    assert taste["status"] == "ok"
    assert 0 <= taste["score"] <= 100
    assert taste["date_ideas"]
