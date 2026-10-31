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
                            "tags": [{"name": "Jazz", "tag_id": "urn:tag:genre:jazz"}],
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
        {
            "id": "P1",
            "name": "Yoshi's",
            "affinity": 0.91,
            "tags": ["Jazz"],
            "tag_ids": ["urn:tag:genre:jazz"],
            "address": "510 Embarcadero W",
        }
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
# Qloo DEPTH: new domains, shared_tags, demographics (additive response fields)
# --------------------------------------------------------------------------- #
def test_parse_taste_recognizes_all_new_domain_headers():
    body = (
        "Music: Khruangbin · TV: Fleabag, Twin Peaks · Books: Dune\n"
        "Podcasts: Radiolab · Games: Hades · Travel: Kyoto, Big Sur\n"
        "Brands: A24 · Nightlife: The Saloon"
    )
    parsed = taste_match.parse_taste(body)
    assert parsed["tv"] == ["Fleabag", "Twin Peaks"]
    assert parsed["books"] == ["Dune"]
    assert parsed["podcasts"] == ["Radiolab"]
    assert parsed["games"] == ["Hades"]
    assert parsed["travel"] == ["Kyoto", "Big Sur"]
    assert parsed["brands"] == ["A24"]
    assert parsed["nightlife"] == ["The Saloon"]


def test_new_entity_types_parsed_and_scored_via_fixture():
    """A Taste page with TV + Books + Travel scores those domains and emits a
    date idea per present domain (fixture entities)."""
    fix = qloo_client.FixtureQlooClient()
    a = ("Ada", "San Francisco", {"tv": ["Fleabag", "Twin Peaks"], "books": ["Just Kids", "Norwegian Wood"], "travel": ["Kyoto"]})
    b = ("Bo", "Oakland", {"tv": ["Twin Peaks", "Chef's Table"], "books": ["Dune", "The Overstory"], "travel": ["Big Sur"]})
    result = asyncio.run(taste_match.match(a, b, client=fix))
    present = {d["domain"] for d in result["domains"]}
    assert {"tv", "books"} <= present
    assert 0 <= result["score"] <= 100
    # Both listed Twin Peaks outright → it's a shared taste.
    assert "Twin Peaks" in result["shared"]
    kinds = {i["kind"] for i in result["date_ideas"]}
    assert "tv" in kinds and "books" in kinds


def test_absence_of_a_domain_does_not_break_scoring():
    """A music-only pair scores only music — no film/dining calls, no crash."""
    fix = qloo_client.FixtureQlooClient()
    a = ("A", "San Francisco", {"music": ["Khruangbin", "Bon Iver"]})
    b = ("B", "Oakland", {"music": ["Tame Impala", "Khruangbin"]})
    result = asyncio.run(taste_match.match(a, b, client=fix))
    assert {d["domain"] for d in result["domains"]} <= {"music"}
    assert 0 <= result["score"] <= 100
    assert "shared_tags" in result and isinstance(result["shared_tags"], list)


def test_domain_only_one_side_stated_is_never_an_overlap():
    """Bug G: a domain only ONE person listed (here Ada's books) must never be
    scored, shown as a per-domain overlap bar, or named the "strongest
    overlap", and its Qloo cross-domain predictions must never surface as a
    shared taste. Only the both-stated domains (music, film) are scored, and
    the shared chips hold only entities both people actually listed."""
    fix = qloo_client.FixtureQlooClient()
    a = (
        "Ada",
        "San Francisco",
        {
            "music": ["Khruangbin", "Bon Iver"],
            "film": ["Spirited Away"],
            "books": ["Just Kids", "Dune"],
        },
    )
    b = ("Bo", "Oakland", {"music": ["Khruangbin", "Tame Impala"], "film": ["Spirited Away"]})
    result = asyncio.run(taste_match.match(a, b, client=fix))
    present = {d["domain"] for d in result["domains"]}
    assert "books" not in present  # only Ada listed books
    assert present <= {"music", "film"}
    assert "books" not in result["summary"].lower()  # not the strongest overlap
    # The shared chips are genuine stated overlap only — both listed these.
    assert "Khruangbin" in result["shared"] and "Spirited Away" in result["shared"]
    # No books date idea either (neither a both-stated nor a places domain).
    assert "books" not in {i["kind"] for i in result["date_ideas"]}


def test_shared_tags_intersects_profile_tags_with_fallback():
    a_tags = [
        {"id": "urn:tag:genre:indie", "name": "Indie", "affinity": 1.0},
        {"id": "urn:tag:genre:folk", "name": "Folk", "affinity": 0.9},
        {"id": "urn:tag:genre:jazz", "name": "Jazz", "affinity": 0.5},
    ]
    b_tags = [
        {"id": "urn:tag:genre:folk", "name": "Folk", "affinity": 0.8},
        {"id": "urn:tag:genre:indie", "name": "Indie", "affinity": 0.95},
        {"id": "urn:tag:genre:soul", "name": "Soul", "affinity": 0.6},
    ]
    shared = taste_match._shared_tags(a_tags, b_tags, {}, {})
    assert shared[:2] == ["Indie", "Folk"]  # ranked by combined affinity
    assert "Jazz" not in shared and "Soul" not in shared
    # No profile-tag overlap → fall back to literal seed-entity tag overlap.
    a_ents = {"music": [{"tags": ["chill", "groove"]}]}
    b_ents = {"music": [{"tags": ["groove", "ambient"]}]}
    assert taste_match._shared_tags([], [], a_ents, b_ents) == ["groove"]


def test_demographics_block_parsed_and_degrades():
    a_demo = {
        "age": {"25_to_29": 0.4, "30_to_34": 0.1, "55_and_older": -0.6},
        "gender": {"male": 0.2, "female": -0.2},
    }
    b_demo = {
        "age": {"25_to_29": 0.5, "30_to_34": -0.2},
        "gender": {"male": -0.3, "female": 0.3},
    }
    block = taste_match._demographics_block("Maya", "Leo", a_demo, b_demo)
    assert block["a"]["top_age"] == "25–29" and block["a"]["gender_lean"] == "male"
    assert block["b"]["gender_lean"] == "female"
    assert "25–29" in block["note"]
    # Degraded: no data on either side → no demographics block.
    assert taste_match._demographics_block("Maya", "Leo", {}, {}) is None


def test_fixture_match_adds_shared_tags_and_degrades_demographics(db):
    result = asyncio.run(taste_match.match(*_pair(db, MAYA, LEO)))
    assert result["source"] == "fixture"
    assert result["shared_tags"] and isinstance(result["shared_tags"], list)
    # The fixture carries no demographic data → the block degrades to None.
    assert result["demographics"] is None


def test_live_client_tags_and_demographics_wire_shape(monkeypatch):
    def fake_urlopen(req, timeout):
        url = req.full_url

        class _Resp:
            def __init__(self, payload):
                self._b = json.dumps(payload).encode()

            def read(self):
                return self._b

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        if "urn%3Atag" in url or "urn:tag" in url:
            return _Resp({"results": {"tags": [
                {"tag_id": "urn:tag:genre:indie", "name": "Indie", "query": {"affinity": 0.92}},
                {"tag_id": "urn:tag:genre:folk", "name": "Folk", "popularity": 0.5},
            ]}})
        return _Resp({"results": {"demographics": [
            {"entity_id": "E1", "query": {"age": {"25_to_29": 0.4, "30_to_34": 0.2}, "gender": {"male": 0.1, "female": -0.1}}},
            {"entity_id": "E2", "query": {"age": {"25_to_29": 0.2, "30_to_34": 0.4}, "gender": {"male": 0.3, "female": -0.3}}},
        ]}})

    monkeypatch.setattr(qloo_client.urllib.request, "urlopen", fake_urlopen)
    live = qloo_client.LiveQlooClient("k", "https://q.example", 3)
    tags = live.tags(["E1", "E2"])
    assert tags == [
        {"id": "urn:tag:genre:indie", "name": "Indie", "affinity": 0.92},
        {"id": "urn:tag:genre:folk", "name": "Folk", "affinity": 0.5},
    ]
    demo = live.demographics(["E1", "E2"])
    # Averaged across the two anchor entities.
    assert demo["age"]["25_to_29"] == 0.3 and demo["age"]["30_to_34"] == 0.3
    assert demo["gender"]["male"] == 0.2


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
    # Viewer (Sam) has no Taste page, the match (Leo) does — the one-sided
    # "add yours" state, still 404 no_taste, message tells the viewer to add
    # their page and names the match.
    user = db.collection("users").document("fresh")
    user.collection("profile").document("main").set({"name": "Sam", "birthdate": "1990-01-01"})
    resp = client.post("/taste/pair", json={"other_uid": LEO}, headers=_auth(monkeypatch, "fresh"))
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "no_taste"
    msg = resp.json()["detail"]["message"]
    assert "Leo" in msg and "Taste page" in msg


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
    # Viewer has no Taste page (the match does): the "add yours" one-sided
    # state — status no_taste, message prompts the viewer and names the match.
    user = db.collection("users").document("fresh")
    user.collection("profile").document("main").set(
        {"name": "Sam", "birthdate": "1990-01-01"}
    )
    section = asyncio.run(taste_match.report_section(db, "fresh", LEO))
    assert section["status"] == "no_taste"
    assert "Leo" in section["message"] and "Taste page" in section["message"]


def test_report_section_one_sided_surfaces_viewer_tastes(db):
    """Viewer HAS a Taste page, the match does NOT: the card no longer
    dead-ends — it surfaces the viewer's own tastes and a friendly line."""
    # Maya (seeded, full taste) views a match with no Taste page.
    bare = db.collection("users").document("bare")
    bare.collection("profile").document("main").set(
        {"name": "Dillu", "birthdate": "1992-01-01"}
    )
    section = asyncio.run(taste_match.report_section(db, MAYA, "bare"))
    assert section["status"] == "no_taste"
    msg = section["message"]
    assert "Dillu" in msg
    # The viewer's own tastes are surfaced (Maya listed Khruangbin under Music).
    assert "Music:" in msg and "Khruangbin" in msg


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


# --------------------------------------------------------------------------- #
# Questionnaire → public Taste page → real pairing (the collection path)
# --------------------------------------------------------------------------- #
def test_questionnaire_taste_answers_produce_a_real_pairing(db):
    """Two fresh users with NO Taste page start at no_taste; after each answers
    the taste questionnaire nodes, both have a public Taste page in the shape
    parse_taste reads and the match returns a real score (not no_taste)."""
    import skills

    for uid, name in (("qa", "Ada"), ("qb", "Bruno")):
        db.collection("users").document(uid).collection("profile").document(
            "main"
        ).set({"name": name, "location": "San Francisco"})

    # Before answering: no public Taste page → no_taste.
    with pytest.raises(taste_match.NoTaste):
        taste_match.taste_from_view(public_profile.build(db, "qb", "qa"))

    def answer(uid, pairs):
        fn = skills.make_session_tool_fns(db, uid)["record_answer"]
        for nid, val in pairs:
            assert "recorded" in fn(nid, val, "stated")

    answer("qa", [
        ("taste_music", "Khruangbin, Bon Iver, Phoebe Bridgers"),
        ("taste_film", "Lost in Translation, Amélie, Spirited Away"),
        ("taste_food", "Tartine Bakery, Zuni Café"),
    ])
    answer("qb", [
        ("taste_music", "Thelonious Monk, Khruangbin, Kamasi Washington"),
        ("taste_film", "Blade Runner 2049, Arrival, Spirited Away"),
        ("taste_food", "Ramen Shop, Blue Bottle Coffee"),
    ])

    # The composed page is public and parseable.
    page = (
        db.collection("users").document("qa").collection("wiki_pages")
        .document("taste").get().to_dict()
    )
    assert page["visibility"] == "public" and page["page_type"] == "taste"
    assert taste_match.parse_taste(page["ai_body"])["music"][0] == "Khruangbin"

    a = taste_match.taste_from_view(public_profile.build(db, "qb", "qa"))
    b = taste_match.taste_from_view(public_profile.build(db, "qa", "qb"))
    result = asyncio.run(taste_match.match(a, b))
    assert 0 <= result["score"] <= 100 and result["score_label"]

    section = asyncio.run(taste_match.report_section(db, "qa", "qb"))
    assert section["status"] == "ok"


# --------------------------------------------------------------------------- #
# Kill switch — the ``qloo_enabled`` feature flag (billing protection)
# --------------------------------------------------------------------------- #
def test_kill_switch_makes_zero_qloo_calls(db, monkeypatch):
    """With qloo_enabled OFF, match() short-circuits to NoTaste and the Qloo
    client is NEVER invoked — proving no outbound Qloo HTTP call (no billing)."""
    monkeypatch.setenv("FLAG_QLOO_ENABLED", "false")
    assert qloo_client.qloo_enabled() is False
    spy = _RecordingLive()  # records every name it would send to Qloo
    with pytest.raises(taste_match.NoTaste):
        asyncio.run(taste_match.match(*_pair(db, MAYA, LEO), client=spy))
    assert spy.sent == []  # not one name reached the Qloo client


def test_kill_switch_get_client_never_returns_live(monkeypatch):
    """Even with a key set, get_client() hands out the offline fixture (no
    network) while the kill switch is off; back to live once re-enabled."""
    monkeypatch.setenv("QLOO_API_KEY", "x")
    monkeypatch.setenv("FLAG_QLOO_ENABLED", "false")
    assert isinstance(qloo_client.get_client(), qloo_client.FixtureQlooClient)
    monkeypatch.setenv("FLAG_QLOO_ENABLED", "true")
    assert isinstance(qloo_client.get_client(), qloo_client.LiveQlooClient)


def test_kill_switch_report_section_degrades_to_no_taste(db, monkeypatch):
    monkeypatch.setenv("FLAG_QLOO_ENABLED", "false")
    section = asyncio.run(taste_match.report_section(db, MAYA, LEO))
    assert section["status"] == "no_taste"
    assert section["message"]


def test_kill_switch_pair_endpoint_is_404_no_taste(db, monkeypatch):
    monkeypatch.setenv("FLAG_QLOO_ENABLED", "false")
    resp = client.post(
        "/taste/pair", json={"other_uid": LEO}, headers=_auth(monkeypatch, MAYA)
    )
    assert resp.status_code == 404
    assert resp.json()["detail"]["code"] == "no_taste"


def test_kill_switch_demo_pair_is_404(db, monkeypatch):
    monkeypatch.setenv("FLAG_QLOO_ENABLED", "false")
    resp = client.get("/taste/demo/pair", params={"a": "maya", "b": "aisha"})
    assert resp.status_code == 404


def test_on_by_default_normal_behaviour_unchanged(db):
    """Default (flag unset) keeps Qloo on — the engine still scores a pair."""
    assert qloo_client.qloo_enabled() is True
    result = asyncio.run(taste_match.match(*_pair(db, MAYA, LEO)))
    assert 0 <= result["score"] <= 100 and result["source"] == "fixture"
