import asyncio
import dataclasses
from datetime import datetime, timedelta, timezone

import auth
import completeness
import gemini
import main
import pytest
import question_tree
import wiki_query
from config import CONFIG
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# --- a tiny path-keyed Firestore fake -------------------------------------


class _Snap:
    def __init__(self, key, data):
        self.id = key[-1]
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    @property
    def id(self):
        return self.key[-1]

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))

    def get(self):
        return _Snap(self.key, self.store.get(self.key))

    def set(self, data, merge=False):
        cur = self.store.get(self.key)
        if merge and isinstance(cur, dict):
            self.store[self.key] = {**cur, **data}
        else:
            self.store[self.key] = dict(data)


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _DocRef(self.store, self.key + (doc_id,))

    def stream(self):
        d = len(self.key)
        seen = set()
        for k in list(self.store.keys()):
            if len(k) > d and k[:d] == self.key and k[d] not in seen:
                seen.add(k[d])
                child = self.key + (k[d],)
                yield _Snap(child, self.store.get(child))


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def get(self, key):
        return self.docs.get(key)

    def keys(self):
        return self.docs.keys()

    def __setitem__(self, key, value):
        self.docs[key] = value

    def collection(self, name):
        return _CollRef(self, (name,))


def _profile_key(uid="u1"):
    return ("users", uid, "profile", "main")


def _q_key(uid, nid):
    return ("users", uid, "questionnaire", nid)


@pytest.fixture(autouse=True)
def _no_wiki(monkeypatch):
    monkeypatch.setattr(wiki_query, "read_wiki_context", lambda db, uid, **k: "")
    monkeypatch.setattr(
        completeness.wiki_query, "read_wiki_context", lambda db, uid, **k: ""
    )


def _stub_narrative(monkeypatch, mapping, counter=None):
    async def _fake(contents, system_prompt, schema, **kw):  # noqa: ARG001
        if counter is not None:
            counter.append(1)
        return {
            "assessments": [
                {"id": k, "status": v} for k, v in mapping.items()
            ]
        }

    monkeypatch.setattr(gemini, "generate_json", _fake)


# --- scoring --------------------------------------------------------------


def test_score_zero_for_empty_user(monkeypatch):
    _stub_narrative(monkeypatch, {})
    db = FakeDb({_profile_key(): {}})
    res = _run(completeness.compute(db, "u1"))
    assert res["score"] == 0
    assert res["intent"] == "long_term"
    assert res["intent_set"] is False
    assert isinstance(res["sections"], list) and res["sections"]
    assert isinstance(res["next"], list) and res["next"]
    # highest-weight nodes come first in `next`
    assert res["next"][0]["weight"] == 5
    assert {"id", "label", "page_type", "kind", "options", "scale",
            "ayma_prompt", "weight"} == set(res["next"][0])


def test_profile_fields_mark_preboarding_nodes_covered(monkeypatch):
    _stub_narrative(monkeypatch, {})
    db = FakeDb({
        _profile_key(): {
            "name": "Sam", "birthdate": "1990-01-01", "gender": "Woman",
            "interested_in": ["Men"], "location": "Lisbon, Portugal",
        }
    })
    view = _run(completeness.questionnaire_view(db, "u1"))
    by_id = {n["id"]: n for n in view["nodes"]}
    for nid in ("legal_first_name", "date_of_birth", "gender_identity",
                "target_match_genders", "primary_location"):
        assert by_id[nid]["status"] == "covered"
        assert by_id[nid]["source"] == "profile"
    # none of these should show up in `next`
    assert not ({"legal_first_name", "primary_location"}
                & {n["id"] for n in completeness._next(
                    _run(completeness._evaluate(db, "u1"))[2])})


def test_inferred_value_counts_0_7_not_1_0(monkeypatch):
    _stub_narrative(monkeypatch, {})
    db_stated = FakeDb({
        _profile_key(): {},
        _q_key("u1", "attachment_style"): {
            "node_id": "attachment_style", "value": "Secure",
            "source": "stated", "confidence": "high",
        },
    })
    db_inferred = FakeDb({
        _profile_key(): {},
        _q_key("u1", "attachment_style"): {
            "node_id": "attachment_style", "value": "Secure",
            "source": "inferred", "confidence": "low",
        },
    })
    _, _, ev_s = _run(completeness._evaluate(db_stated, "u1"))
    _, _, ev_i = _run(completeness._evaluate(db_inferred, "u1"))
    cov_s = next(e for e in ev_s if e["node"]["id"] == "attachment_style")
    cov_i = next(e for e in ev_i if e["node"]["id"] == "attachment_style")
    assert cov_s["coverage"] == 1.0 and cov_s["status"] == "covered"
    assert cov_i["coverage"] == 0.7 and cov_i["status"] == "partial"
    assert cov_i["source"] == "inferred"


def test_narrative_pass_mapped_and_cached(monkeypatch):
    calls = []
    _stub_narrative(
        monkeypatch,
        {
            "casual_perfect_night_narrative": "covered",
            "casual_hill_to_die_on_narrative": "partial",
        },
        counter=calls,
    )
    # a non-empty wiki so the LLM pass actually runs
    monkeypatch.setattr(
        completeness.wiki_query, "read_wiki_context",
        lambda db, uid, **k: "Loves loud dive bars and vinyl nights.",
    )
    db = FakeDb({
        _profile_key(): {"relationship_intent": "Casual"},
    })
    r1 = _run(completeness.compute(db, "u1"))
    r2 = _run(completeness.compute(db, "u1"))
    assert len(calls) == 1, "unchanged wiki must not re-hit gemini"
    assert r1["intent"] == "casual" and r2["intent"] == "casual"
    view = _run(completeness.questionnaire_view(db, "u1"))
    by_id = {n["id"]: n for n in view["nodes"]}
    assert by_id["casual_perfect_night_narrative"]["status"] == "covered"
    assert by_id["casual_hill_to_die_on_narrative"]["status"] == "partial"


def test_recompute_debounces(monkeypatch):
    _stub_narrative(monkeypatch, {})
    fresh = {
        "score": 42, "intent": "long_term", "intent_set": True,
        "sections": [], "next": [],
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    db = FakeDb({_profile_key(): {"completeness": fresh}})
    out = _run(completeness.recompute(db, "u1"))
    assert out == fresh  # returned as-is, no recompute

    stale = dict(fresh, updated_at=(
        datetime.now(timezone.utc) - timedelta(minutes=5)
    ).isoformat())
    db2 = FakeDb({_profile_key(): {"completeness": stale}})
    out2 = _run(completeness.recompute(db2, "u1"))
    assert out2["score"] == 0  # recomputed from an empty tree
    out3 = _run(completeness.recompute(db2, "u1", force=True))
    assert out3["updated_at"] >= out2["updated_at"]


def test_sections_and_next_shape(monkeypatch):
    _stub_narrative(monkeypatch, {})
    db = FakeDb({_profile_key(): {}})
    res = _run(completeness.compute(db, "u1"))
    for s in res["sections"]:
        assert set(s) == {"page_type", "label", "pct", "answered", "total"}
        assert 0 <= s["pct"] <= 100
        assert 0 <= s["answered"] <= s["total"]
    assert len(res["next"]) <= 6
    # persisted onto profile/main
    assert db.get(_profile_key())["completeness"]["score"] == res["score"]


def test_evaluate_excludes_nikah_for_long_term(monkeypatch):
    _stub_narrative(monkeypatch, {})
    db = FakeDb({_profile_key(): {"relationship_intent": "Long-term"}})
    _, _, ev = _run(completeness._evaluate(db, "u1"))
    branches = {e["node"]["branch"] for e in ev}
    assert branches == {"all", "long_term"}


# --- endpoints ----------------------------------------------------------


client = TestClient(main.app)
_SECRET = "cron-secret-abcdefghijklmnop"


def _auth(monkeypatch, uid="u1"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def test_completeness_endpoint_requires_auth():
    assert client.get("/completeness").status_code in (401, 403)
    assert client.get("/questionnaire").status_code in (401, 403)


def test_completeness_endpoint_shape(monkeypatch):
    db = FakeDb({_profile_key("me"): {}})
    monkeypatch.setattr(main, "get_db", lambda: db)
    _stub_narrative(monkeypatch, {})

    resp = client.get("/completeness", headers=_auth(monkeypatch, "me"))
    assert resp.status_code == 200
    body = resp.json()
    assert set(body) >= {"score", "intent", "sections", "next", "updated_at"}

    resp2 = client.get("/questionnaire", headers=_auth(monkeypatch, "me"))
    assert resp2.status_code == 200
    b2 = resp2.json()
    assert set(b2) >= {"intent", "score", "nodes"}
    assert b2["nodes"] and "status" in b2["nodes"][0]


def test_cron_completeness_backfill_guarded(monkeypatch):
    monkeypatch.setattr(
        auth, "CONFIG", dataclasses.replace(CONFIG, cron_secret=_SECRET)
    )
    assert client.post("/cron/completeness-backfill").status_code == 403
    assert client.post(
        "/cron/completeness-backfill", headers={"X-Cron-Secret": "nope"}
    ).status_code == 403

    db = FakeDb({_profile_key("a"): {}})
    monkeypatch.setattr(main, "get_db", lambda: db)
    _stub_narrative(monkeypatch, {})
    ok = client.post(
        "/cron/completeness-backfill?user_limit=5",
        headers={"X-Cron-Secret": _SECRET},
    )
    assert ok.status_code == 200
    assert ok.json()["users"] == 1
