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

# Captured before the autouse `_no_wiki` fixture below stubs the module
# attribute — a test that wants the real implementation back can't recover it
# via `wiki_query.read_wiki_context` at that point, since that name would
# just resolve to the already-stubbed lambda.
_REAL_READ_WIKI_CONTEXT = wiki_query.read_wiki_context


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
            "ayma_prompt", "weight", "sensitive"} == set(res["next"][0])


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


def test_gender_identity_question_skipped_for_straight_cis_user(monkeypatch):
    # Founder directive, 2026-09-20: don't ask a gender-identity/pronoun
    # follow-up of straight/cisgender users — the basic preboarding `gender`
    # field already fully answers it for them, same as before this fix.
    _stub_narrative(monkeypatch, {})
    db = FakeDb({
        _profile_key(): {
            "name": "Sam", "birthdate": "1990-01-01", "gender": "Woman",
            "interested_in": ["Men"], "location": "Lisbon, Portugal",
        }
    })
    view = _run(completeness.questionnaire_view(db, "u1"))
    node = next(n for n in view["nodes"] if n["id"] == "gender_identity")
    assert node["status"] == "covered"
    assert node["source"] == "profile"

    res = _run(completeness.compute(db, "u1"))
    assert "gender_identity" not in {n["id"] for n in res["next"]}


def test_gender_identity_question_asked_for_lgbtq_user(monkeypatch):
    # Same basic `gender` field filled in at preboarding, but this time the
    # user's own gender + interested_in marks them LGBTQ+ (a woman interested
    # in women) — the richer conversational gender_identity node (which asks
    # about Trans-Male/Trans-Female/Non-Binary/Custom, not just the basic
    # preboarding options) should stay open and be offered via `next`.
    _stub_narrative(monkeypatch, {})
    db = FakeDb({
        _profile_key(): {
            "name": "Sam", "birthdate": "1990-01-01", "gender": "Woman",
            "interested_in": ["Women"], "location": "Lisbon, Portugal",
        }
    })
    view = _run(completeness.questionnaire_view(db, "u1"))
    node = next(n for n in view["nodes"] if n["id"] == "gender_identity")
    assert node["status"] != "covered"
    assert node["source"] != "profile"

    res = _run(completeness.compute(db, "u1"))
    assert "gender_identity" in {n["id"] for n in res["next"]}


def test_gender_identity_question_asked_for_non_binary_user(monkeypatch):
    # A non-binary/other gender is LGBTQ+ regardless of interested_in.
    _stub_narrative(monkeypatch, {})
    db = FakeDb({
        _profile_key(): {
            "name": "Sam", "birthdate": "1990-01-01", "gender": "Non-Binary",
            "interested_in": ["Everyone"], "location": "Lisbon, Portugal",
        }
    })
    res = _run(completeness.compute(db, "u1"))
    assert "gender_identity" in {n["id"] for n in res["next"]}


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


def test_story_captured_structured_answer_is_not_re_asked(monkeypatch):
    """Founder bug (2026-10): Ayma asked the same onboarding question (e.g.
    "how many kids") again and again even though the user answered and the
    story updated. Root cause: `wiki_ingest` reliably folds every chat answer
    into the free-text story each turn, but `record_answer` — the only writer
    of the questionnaire store — fires only when the model remembers to call
    it. Structured nodes (enum/scale/...) used to be scored against that store
    alone, so a story-captured answer never marked them covered and
    `next_questions` re-selected the same node forever. The story-coverage
    pass now judges structured nodes too: a concrete (`covered`) story answer
    satisfies the node (coverage 1.0 -> excluded from `next`), while a vague
    (`partial`) mention does not, so a genuinely-unanswered node is still
    asked."""
    monkeypatch.setattr(
        completeness.wiki_query, "read_wiki_context",
        lambda db, uid, **k: "Has two children who live with them full time.",
    )
    _stub_narrative(monkeypatch, {
        "existing_children": "covered",   # concrete answer stated in the story
        "children_count": "partial",      # merely touched, no concrete count
    })
    db = FakeDb({
        _profile_key(): {"relationship_intent": "Long-term", **_PREBOARD},
    })

    _, _, ev = _run(completeness._evaluate(db, "u1"))
    by_id = {e["node"]["id"]: e for e in ev}

    # existing_children is an enum, not in the questionnaire store and not a
    # preboarding field — before the fix it stayed `missing` forever. A
    # concrete story answer now satisfies it at full coverage, so `_next`
    # (which only offers nodes with coverage < 1.0) cannot re-select it.
    assert by_id["existing_children"]["node"]["kind"] == "enum"
    assert by_id["existing_children"]["coverage"] == 1.0
    assert by_id["existing_children"]["status"] == "covered"
    assert by_id["existing_children"]["source"] == "wiki"

    # a merely-partial story mention of a structured node does NOT satisfy it:
    # the exact value is still unknown, so it stays open and askable.
    assert by_id["children_count"]["coverage"] == 0.0
    assert by_id["children_count"]["status"] == "missing"

    res = _run(completeness.compute(db, "u1"))
    next_ids = {n["id"] for n in res["next"]}
    assert "existing_children" not in next_ids
    # normal behaviour intact: still-unanswered nodes are still offered.
    assert res["next"]


def test_story_coverage_does_not_cover_the_routing_node(monkeypatch):
    """The routing (`relationship_intent`) node is resolved separately and set
    through its own skill, so a passing story mention must not silently mark it
    covered and drop it out of the intent gate. With no intent recorded it
    stays open and keeps leading `next`, even if the story pass would call it
    `covered`."""
    monkeypatch.setattr(
        completeness.wiki_query, "read_wiki_context",
        lambda db, uid, **k: "Mentioned wanting something long-term one day.",
    )
    _stub_narrative(monkeypatch, {"relationship_intent": "covered"})
    db = FakeDb({_profile_key(): {}})

    _, intent_set, ev = _run(completeness._evaluate(db, "u1"))
    routing = next(e for e in ev if e["node"]["id"] == "relationship_intent")
    assert intent_set is False
    assert routing["coverage"] == 0.0
    assert routing["source"] is None

    res = _run(completeness.compute(db, "u1"))
    assert res["intent_set"] is False
    assert res["next"][0]["id"] == "relationship_intent"


def test_narrative_pass_ignores_interactions_and_steering_churn(monkeypatch):
    """Root-caused against a real account (uid iWhWjiWhEpU7iyu9B9vy7GlT0PD2,
    2026-09-26): a session of pure small talk still triggered a wiki_ingest
    rewrite of only the `interactions`/`steering` pages (Ayma's own
    session-behaviour log and standing instructions — never a narrative
    topic), which used to change the wiki-hash cache key in
    `_narrative_status` and force a second, wasted Gemini call for a turn
    that added nothing narratively new. `read_wiki_context` is exercised for
    real here (not stubbed) so the exclusion is proven end to end."""
    monkeypatch.setattr(
        completeness.wiki_query, "read_wiki_context", _REAL_READ_WIKI_CONTEXT
    )
    calls = []
    _stub_narrative(monkeypatch, {}, counter=calls)

    def _wiki_key(page_id):
        return ("users", "u1", "wiki_pages", page_id)

    db = FakeDb({
        _profile_key(): {"relationship_intent": "Casual"},
        _wiki_key("career"): {"page_type": "career", "ai_body": "Builds robots."},
        _wiki_key("interactions"): {
            "page_type": "interactions",
            "ai_body": "2026-09-26 — said hi, sang a bit.",
        },
    })

    _run(completeness.compute(db, "u1"))
    assert len(calls) == 1

    # Only `interactions` changes (as wiki_ingest does on nearly every real
    # turn) — the narrative pass must not re-run.
    db[_wiki_key("interactions")] = {
        "page_type": "interactions",
        "ai_body": "2026-09-26 — said hi, sang a bit, again.",
    }
    _run(completeness.compute(db, "u1"))
    assert len(calls) == 1, "interactions-only churn must not re-hit gemini"

    # A real change to a narrative-relevant page must still invalidate it.
    db[_wiki_key("career")] = {
        "page_type": "career", "ai_body": "Builds robots and humanoids now.",
    }
    _run(completeness.compute(db, "u1"))
    assert len(calls) == 2, "an actual narrative-page change must still recompute"


def test_recompute_debounces(monkeypatch):
    _stub_narrative(monkeypatch, {})
    fresh = {
        "score": 42, "intent": "long_term", "intent_set": True,
        "tree_version": question_tree.version(),
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
        "tree_version": question_tree.version(),
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
        "tree_version": question_tree.version(),
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
    # too, same as identity/personality/lifestyle. `taste` (music/film/food —
    # the Qloo Taste page) is a branch-`all` section, so it also shows
    # pre-intent, like interests.
    assert section_pts <= {
        "identity", "personality", "lifestyle", "family", "social_circle",
        "career", "values", "interests", "taste", "dealbreakers", "sensitive",
    }
    assert not section_pts & {"goals", "relationships", "finances"}

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
    core_ids = [
        n["id"] for n in question_tree.nodes_for_intent("long_term")
        if n["page_type"] == "identity" and n["tier"] == "core"
    ]
    assert by_pt["identity"]["core_total"] == len(core_ids)
    # 4 identity core nodes come from preboarding; the rest are open
    assert by_pt["identity"]["core_answered"] == 4
    assert by_pt["personality"]["unlocked"] is False

    # a high-weight node in a locked section is kept out of `next`
    assert "attachment_style" not in {n["id"] for n in res["next"]}
    # score spans the whole long_term tree; visible_score only the open nodes
    assert 0 < res["score"] < res["visible_score"]

    # answer identity's last core node -> the next section unlocks
    answers = {
        "relocation_radius": "Within my city",
        "partner_age_min": "28",
        "partner_age_max": "38",
        "geographic_flexibility": "Rooted - staying where I live",
    }
    docs = {_profile_key(): dict(prof)}
    for nid, val in answers.items():
        docs[_q_key("u1", nid)] = {
            "node_id": nid, "value": val, "source": "stated",
        }
    db2 = FakeDb(docs)
    res2 = _run(completeness.compute(db2, "u1"))
    by_pt2 = {s["page_type"]: s for s in res2["sections"]}
    assert by_pt2["identity"]["core_answered"] == len(core_ids)
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


# --- taste promoted early (Qloo Taste page population) ------------------


def test_taste_section_is_unlocked_and_offered_early_without_finishing_earlier(
    monkeypatch,
):
    # Founder directive (meta-hackathon): the taste questions must be asked
    # EARLY so the public Taste page / Qloo "Taste match" gets populated,
    # rather than staying buried behind every earlier section's core. `taste`
    # is a promoted (always-unlocked) section and `taste_music` is top weight,
    # so it surfaces near the top of `next` for a user who hasn't answered it —
    # even though the identity/personality/... cores are still open.
    _stub_narrative(monkeypatch, {})
    prof = {"relationship_intent": "Long-term", **_PREBOARD}
    db = FakeDb({_profile_key(): dict(prof)})
    res = _run(completeness.compute(db, "u1"))
    by_pt = {s["page_type"]: s for s in res["sections"]}

    # promoted: open from the start, highest priority tier, yet earlier
    # sections' cores are NOT all done (personality stays locked).
    assert by_pt["taste"]["unlocked"] is True
    assert by_pt["taste"]["priority"] == 5
    assert by_pt["personality"]["unlocked"] is False

    next_ids = [n["id"] for n in res["next"]]
    assert "taste_music" in next_ids
    # near the top of the flow — within the first handful offered.
    assert next_ids.index("taste_music") <= 2
    # a locked-section high-weight node is still kept out.
    assert "attachment_style" not in next_ids


def test_taste_surfaces_for_a_bare_user_with_no_preboarding(monkeypatch):
    # Even with nothing filled in at all (intent unset), the taste question is
    # offered right after the routing node — not buried.
    _stub_narrative(monkeypatch, {})
    db = FakeDb({_profile_key(): {}})
    res = _run(completeness.compute(db, "u1"))
    next_ids = [n["id"] for n in res["next"]]
    assert "taste_music" in next_ids
    assert next_ids.index("taste_music") <= 2


def test_promoted_taste_does_not_lock_sections_after_it(monkeypatch):
    # The taste section is transparent to the sequential gate: an unanswered
    # `taste_music` must never lock the sections that follow taste in priority
    # order. With identity's core complete, the next core-first section unlocks
    # regardless of taste being unanswered.
    _stub_narrative(monkeypatch, {})
    prof = {
        "relationship_intent": "Long-term",
        "relocation_radius": "Within my city",
        "partner_age_min": "28",
        "partner_age_max": "38",
        "geographic_flexibility": "Rooted - staying where I live",
        **_PREBOARD,
    }
    docs = {_profile_key(): dict(prof)}
    for nid in ("relocation_radius", "partner_age_min", "partner_age_max",
                "geographic_flexibility"):
        docs[_q_key("u1", nid)] = {
            "node_id": nid, "value": prof[nid], "source": "stated",
        }
    db = FakeDb(docs)
    res = _run(completeness.compute(db, "u1"))
    by_pt = {s["page_type"]: s for s in res["sections"]}
    # identity core is complete -> the first gated section opens, and taste
    # being unanswered did not stand in the way.
    assert by_pt["identity"]["core_answered"] == by_pt["identity"]["core_total"]
    assert by_pt["personality"]["unlocked"] is True
    assert by_pt["taste"]["unlocked"] is True


def test_taste_film_food_unlock_once_music_answered(monkeypatch):
    # Progressive disclosure within the taste section: the deep film/food nodes
    # open once the section's single core node (`taste_music`) is answered.
    _stub_narrative(monkeypatch, {})
    prof = {"relationship_intent": "Long-term", **_PREBOARD}
    docs = {
        _profile_key(): dict(prof),
        _q_key("u1", "taste_music"): {
            "node_id": "taste_music", "value": "Khruangbin, Bon Iver",
            "source": "stated",
        },
    }
    db = FakeDb(docs)
    view = _run(completeness.questionnaire_view(db, "u1"))
    unlocked = {
        n["id"]: n["unlocked"] for n in view["nodes"]
        if n["page_type"] == "taste"
    }
    assert unlocked == {
        "taste_music": True, "taste_film": True, "taste_food": True,
    }


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
        _profile_key(): {"completeness": {
            "score": 95, "complete": True,
            "tree_version": question_tree.version(),
        }},
    })
    monkeypatch.setattr(main, "get_db", lambda: db)
    note = main._questionnaire_note("u1", "active")
    assert "QUESTIONNAIRE COMPLETE" in note
    assert "Do not restart" in note
    # instructs Ayma not to claim totality — "always more" is the honest framing
    assert "always more" in note


def test_complete_claim_from_an_older_tree_is_not_trusted(monkeypatch):
    # Existing users who read "complete" under the old, shallower tree must not
    # keep being told the questionnaire is finished once new nodes exist.
    for stored in (
        {"score": 95, "complete": True},
        {"score": 95, "complete": True, "tree_version": 1},
        {"score": 100},
    ):
        db = FakeDb({_profile_key(): {"completeness": stored}})
        monkeypatch.setattr(main, "get_db", lambda: db)
        note = main._questionnaire_note("u1", "active")
        assert "QUESTIONNAIRE COMPLETE" not in note


def test_old_tree_result_is_never_reported_complete_and_is_refreshed(monkeypatch):
    scheduled = []
    monkeypatch.setattr(
        completeness, "schedule", lambda db, uid: scheduled.append(uid)
    )
    old = {
        "score": 95, "complete": True, "tree_version": 1, "intent": "long_term",
        "intent_set": True, "sections": [], "next": [],
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    db = FakeDb({_profile_key(): {"completeness": old}})
    out = _run(completeness.get_or_recompute(db, "u1"))
    assert out["complete"] is False
    assert scheduled == ["u1"]


def test_recompute_ignores_the_debounce_for_an_old_tree_result(monkeypatch):
    _stub_narrative(monkeypatch, {})
    old = {
        "score": 95, "complete": True, "tree_version": 1, "intent": "long_term",
        "intent_set": True, "sections": [], "next": [],
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    db = FakeDb({_profile_key(): {"completeness": old}})
    out = _run(completeness.recompute(db, "u1"))
    assert out["tree_version"] == question_tree.version()
    assert out["complete"] is False


def test_a_profile_answering_only_the_old_nodes_is_not_complete(monkeypatch):
    # Regression for the founder report: every node of the pre-v2 tree
    # answered, yet new dating-relevant nodes are still open -> not complete.
    _stub_narrative(monkeypatch, {})
    new_ids = {
        "partner_age_min", "partner_age_max", "career_role_narrative",
        "dealbreakers_narrative", "financial_strategy_narrative",
        "dating_to_marriage_timeline", "stress_support_style",
    }
    prof = {"relationship_intent": "Long-term", **_PREBOARD}
    docs = {_profile_key(): dict(prof)}
    for n in question_tree.nodes_for_intent("long_term"):
        if n["id"] in new_ids or n["id"] in completeness._PROFILE_DERIVABLE:
            continue
        docs[_q_key("u1", n["id"])] = {
            "node_id": n["id"], "value": "x", "source": "stated",
        }
    db = FakeDb(docs)
    res = _run(completeness.compute(db, "u1"))
    assert res["complete"] is False
    open_ids = {n["id"] for n in res["next"]}
    assert open_ids and open_ids <= new_ids


def test_web_findings_never_count_toward_narrative_coverage():
    assert {"web_findings", "face_analysis", "body_analysis"} <= (
        completeness._NARRATIVE_EXCLUDED_PAGE_TYPES
    )


def test_questionnaire_note_never_instructs_a_progress_announcement(monkeypatch):
    """Root cause of the real "profile's looking much fuller" violation
    (ARCHITECTURE.md questionnaire bug, Sept 2026): this per-turn note used to
    end with "Tell them a fuller questionnaire gets them noticeably more
    accurate matches" — an unconditional instruction to comment on fullness,
    landing right before the conversation history (i.e. closest to where the
    model actually decides its next line). That line, and the raw score
    percentage, leaked near-verbatim into production replies. The note must
    never invite stating the score or a "fuller/looking good" framing, and
    must call out the actual banned shape concretely, not just abstractly."""
    db = FakeDb({
        _profile_key(): {
            "completeness": {
                "score": 60,
                "complete": False,
                "intent_set": True,
                "intent": "long_term",
                "next": [{"label": "X", "ayma_prompt": "ask about x"}],
            }
        },
    })
    monkeypatch.setattr(main, "get_db", lambda: db)
    note = main._questionnaire_note("u1", "active")
    assert "Tell them a fuller questionnaire" not in note
    assert "never say" in note.lower()
    # the exact real-world violation is named so it isn't just a vague rule
    assert "looking much fuller" in note


def test_next_deprioritises_a_recently_offered_unanswered_node(monkeypatch):
    """`next_questions` forces a fresh recompute, so there's no stale-cache
    bug here — but with nothing recorded, the top-weight open node is *always*
    the same one, so a user who declines it gets it right back next call.
    Verified against real data (uid iWhWjiWhEpU7iyu9B9vy7GlT0PD2): the same
    core node got re-offered three times in a few minutes after the user
    twice declined it. `mark_offered` + the cooldown in `_next` fix that by
    pushing a just-offered-but-still-unanswered node down, not off, the list."""
    _stub_narrative(monkeypatch, {})
    prof = {"relationship_intent": "Long-term", **_PREBOARD}
    db = FakeDb({_profile_key(): dict(prof)})

    res1 = _run(completeness.compute(db, "u1"))
    top_id = res1["next"][0]["id"]

    completeness.mark_offered(db, "u1", [top_id])

    res2 = _run(completeness.compute(db, "u1"))
    assert res2["next"][0]["id"] != top_id
    # deprioritised, not deleted: recorded as still-open somewhere, or the
    # window is small enough it fell off the top of a longer open list
    ids2 = {n["id"] for n in res2["next"]}
    assert top_id not in ids2 or res2["next"].index(
        next(n for n in res2["next"] if n["id"] == top_id)
    ) > 0


def test_next_returns_to_normal_order_once_cooldown_lapses(monkeypatch):
    _stub_narrative(monkeypatch, {})
    prof = {"relationship_intent": "Long-term", **_PREBOARD}
    db = FakeDb({_profile_key(): dict(prof)})

    res1 = _run(completeness.compute(db, "u1"))
    top_id = res1["next"][0]["id"]

    stale_ts = (
        datetime.now(timezone.utc)
        - timedelta(seconds=completeness._OFFER_COOLDOWN_SECONDS + 60)
    ).isoformat()
    completeness._offers_ref(db, "u1").set({top_id: stale_ts}, merge=True)

    res2 = _run(completeness.compute(db, "u1"))
    assert res2["next"][0]["id"] == top_id


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
