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
    res = _run(completeness.compute(db, "u1"))
    assert not ({"legal_first_name", "primary_location"}
                & {n["id"] for n in res["next"]})


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


def test_get_or_recompute_returns_stale_immediately_and_schedules_refresh(
    monkeypatch,
):
    # § founder report right after the question tree grew (a604202, 13 new
    # nodes): "Takes a long time to load the profile completeness" — a stale
    # cached doc must come back immediately, not block the request on a live
    # recompute (which can include a real Gemini call).
    scheduled = []
    monkeypatch.setattr(
        completeness, "schedule", lambda db, uid: scheduled.append((db, uid))
    )
    stale = {
        "score": 42, "intent": "long_term", "intent_set": True,
        "sections": [], "next": [],
        "updated_at": (
            datetime.now(timezone.utc) - timedelta(minutes=5)
        ).isoformat(),
    }
    db = FakeDb({_profile_key(): {"completeness": stale}})

    out = _run(completeness.get_or_recompute(db, "u1"))

    assert out == stale  # returned as-is, not a freshly recomputed doc
    assert scheduled == [(db, "u1")]


def test_get_or_recompute_returns_fresh_without_scheduling(monkeypatch):
    scheduled = []
    monkeypatch.setattr(
        completeness, "schedule", lambda db, uid: scheduled.append((db, uid))
    )
    fresh = {
        "score": 42, "intent": "long_term", "intent_set": True,
        "sections": [], "next": [],
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    db = FakeDb({_profile_key(): {"completeness": fresh}})

    out = _run(completeness.get_or_recompute(db, "u1"))

    assert out == fresh
    assert scheduled == []


def test_get_or_recompute_computes_synchronously_when_nothing_cached_yet(
    monkeypatch,
):
    _stub_narrative(monkeypatch, {})
    db = FakeDb({_profile_key(): {}})

    out = _run(completeness.get_or_recompute(db, "u1"))

    assert "score" in out and "updated_at" in out


def test_sections_and_next_shape(monkeypatch):
    _stub_narrative(monkeypatch, {})
    db = FakeDb({_profile_key(): {}})
    res = _run(completeness.compute(db, "u1"))
    for s in res["sections"]:
        assert set(s) == {
            "page_type", "label", "pct", "answered", "total",
            "unlocked", "core_total", "core_answered", "priority",
        }
        assert 0 <= s["pct"] <= 100
        assert 0 <= s["answered"] <= s["total"]
        assert 0 <= s["core_answered"] <= s["core_total"]
        assert isinstance(s["unlocked"], bool)
    # the first section is always unlocked
    assert res["sections"][0]["unlocked"] is True
    assert len(res["next"]) <= 6
    assert isinstance(res["visible_score"], int)
    # persisted onto profile/main
    assert db.get(_profile_key())["completeness"]["score"] == res["score"]


def test_evaluate_excludes_nikah_for_long_term(monkeypatch):
    _stub_narrative(monkeypatch, {})
    db = FakeDb({_profile_key(): {"relationship_intent": "Long-term"}})
    _, _, ev = _run(completeness._evaluate(db, "u1"))
    branches = {e["node"]["branch"] for e in ev}
    assert branches == {"all", "long_term"}


# --- progressive disclosure: intent gate + section/node unlock ----------


_PREBOARD = {
    "name": "Sam", "birthdate": "1990-01-01", "gender": "Woman",
    "interested_in": ["Men"], "location": "Lisbon, Portugal",
}


def test_intent_unset_returns_only_the_global_core(monkeypatch):
    _stub_narrative(monkeypatch, {})
    db = FakeDb({_profile_key(): {}})
    res = _run(completeness.compute(db, "u1"))
    assert res["intent_set"] is False

    section_pts = {s["page_type"] for s in res["sections"]}
    # only `all` sections, and the routing section folds into its own CTA.
    # Family-of-origin and friends are universal getting-to-know-you basics
    # (unlike future-facing family-planning), so they're visible pre-intent
    # too, same as identity/personality/lifestyle.
    assert section_pts <= {
        "identity", "personality", "lifestyle", "family", "social_circle",
    }
    assert not section_pts & {
        "goals", "values", "career", "interests", "relationships",
    }

    view = _run(completeness.questionnaire_view(db, "u1"))
    assert {n["branch"] for n in view["nodes"]} == {"all"}
    assert all("tier" in n and "unlocked" in n for n in view["nodes"])
    assert "visible_score" in view and "visible_score" in res

    # routing node is always offered, and every `next` item is an `all` node
    next_ids = {n["id"] for n in res["next"]}
    assert "relationship_intent" in next_ids
    assert next_ids <= {n["id"] for n in view["nodes"]}


def test_section_locked_until_earlier_core_is_covered(monkeypatch):
    _stub_narrative(monkeypatch, {})
    prof = {"relationship_intent": "Long-term", **_PREBOARD}
    db = FakeDb({_profile_key(): dict(prof)})
    res = _run(completeness.compute(db, "u1"))
    by_pt = {s["page_type"]: s for s in res["sections"]}

    assert by_pt["identity"]["unlocked"] is True
    assert by_pt["identity"]["core_total"] == 5
    # 4 of 5 identity core nodes come from preboarding; relocation_radius is open
    assert by_pt["identity"]["core_answered"] == 4
    assert by_pt["personality"]["unlocked"] is False

    # a high-weight node in a locked section is kept out of `next`
    assert "attachment_style" not in {n["id"] for n in res["next"]}
    # score spans the whole long_term tree; visible_score only the open nodes
    assert 0 < res["score"] < res["visible_score"]

    # answer identity's last core node -> the next section unlocks
    db2 = FakeDb({
        _profile_key(): dict(prof),
        _q_key("u1", "relocation_radius"): {
            "node_id": "relocation_radius", "value": "Within my city",
            "source": "stated",
        },
    })
    res2 = _run(completeness.compute(db2, "u1"))
    by_pt2 = {s["page_type"]: s for s in res2["sections"]}
    assert by_pt2["identity"]["core_answered"] == 5
    assert by_pt2["personality"]["unlocked"] is True


def test_score_is_full_tree_not_just_unlocked(monkeypatch):
    _stub_narrative(monkeypatch, {})
    prof = {"relationship_intent": "Long-term", **_PREBOARD}
    db = FakeDb({_profile_key(): dict(prof)})
    res = _run(completeness.compute(db, "u1"))
    # denominator is every node in the long_term tree, locked sections included
    _, _, ev = _run(completeness._evaluate(db, "u1"))
    assert res["score"] == completeness._score(ev)
    assert res["score"] < 100


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


def test_complete_profile_explicitly_stops_questionnaire(monkeypatch):
    db = FakeDb({
        _profile_key(): {"completeness": {"score": 95, "complete": True}},
    })
    monkeypatch.setattr(main, "get_db", lambda: db)
    note = main._questionnaire_note("u1", "active")
    assert "QUESTIONNAIRE COMPLETE" in note
    assert "Do not restart" in note
    # instructs Ayma not to claim totality — "always more" is the honest framing
    assert "always more" in note


def test_complete_profile_note_falls_back_for_a_stale_cached_doc(monkeypatch):
    # a completeness doc computed before the `complete` flag existed still
    # stops the loop via the score>=95 fallback (unreachable except at full
    # coverage under the new scaled scoring).
    db = FakeDb({_profile_key(): {"completeness": {"score": 100}}})
    monkeypatch.setattr(main, "get_db", lambda: db)
    note = main._questionnaire_note("u1", "active")
    assert "QUESTIONNAIRE COMPLETE" in note


def test_full_tree_coverage_caps_at_95_end_to_end(monkeypatch):
    """Every node in the long_term tree answered -> compute() reports 95, not
    100, and `complete: True`."""
    _stub_narrative(monkeypatch, {n["id"]: "covered" for n in question_tree.nodes()})
    monkeypatch.setattr(
        completeness.wiki_query, "read_wiki_context",
        lambda db, uid, **k: "a full wiki so the narrative pass runs",
    )
    prof = {"relationship_intent": "Long-term", **_PREBOARD}
    docs = {_profile_key(): dict(prof)}
    for n in question_tree.nodes_for_intent("long_term"):
        if n["id"] in completeness._PROFILE_DERIVABLE or n["kind"] == "narrative":
            continue
        if n["id"] == "relationship_intent":
            value = "Long-term"  # keep branch resolution consistent with `prof`
        elif n["kind"] in ("enum", "multi"):
            value = n["options"][0]
        elif n["kind"] == "bool":
            value = "true"
        else:
            value = "5"
        docs[_q_key("u1", n["id"])] = {
            "node_id": n["id"], "value": value, "source": "stated",
        }
    db = FakeDb(docs)
    res = _run(completeness.compute(db, "u1"))
    assert res["score"] == 95
    assert res["complete"] is True


def test_score_caps_below_100_even_at_full_coverage():
    """Founder feedback: a user who answers *every* current question should
    land around 95%, never a literal 100 — there's always more Ayma could
    learn than today's fixed question set covers."""
    evaluated = [
        {"node": {"weight": 5}, "coverage": 1.0},
        {"node": {"weight": 5}, "coverage": 1.0},
        {"node": {"weight": 2}, "coverage": 0.0},
    ]
    partial = completeness._score(evaluated)
    assert partial < completeness._MAX_SCORE
    assert completeness._fully_covered(evaluated) is False

    evaluated[2]["coverage"] = 1.0
    full = completeness._score(evaluated)
    assert full == completeness._MAX_SCORE == 95
    assert completeness._fully_covered(evaluated) is True
    # never regresses below a near-complete score just because of the cap
    assert full > partial


def test_score_is_monotonic_in_coverage():
    """Scaling (not a post-hoc cap) means answering one more question never
    lowers the score, all the way up to the max."""
    evaluated = [
        {"node": {"weight": 1000}, "coverage": 1.0},
        {"node": {"weight": 1}, "coverage": 0.0},
    ]
    before = completeness._score(evaluated)
    evaluated[1]["coverage"] = 1.0
    after = completeness._score(evaluated)
    assert after >= before
    assert after == completeness._MAX_SCORE
