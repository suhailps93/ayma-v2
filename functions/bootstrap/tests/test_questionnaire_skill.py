import asyncio

import completeness
import pytest
import question_tree
import skills
from skills import questionnaire


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
        return _Snap(self.key, self.store.docs.get(self.key))

    def set(self, data, merge=False):
        cur = self.store.docs.get(self.key)
        if merge and isinstance(cur, dict):
            self.store.docs[self.key] = {**cur, **data}
        else:
            self.store.docs[self.key] = dict(data)


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _DocRef(self.store, self.key + (doc_id,))

    def stream(self):
        d = len(self.key)
        seen = set()
        for k in list(self.store.docs.keys()):
            if len(k) > d and k[:d] == self.key and k[d] not in seen:
                seen.add(k[d])
                child = self.key + (k[d],)
                yield _Snap(child, self.store.docs.get(child))


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def collection(self, name):
        return _CollRef(self, (name,))


_PROF = ("users", "u1", "profile", "main")


def _q(nid):
    return ("users", "u1", "questionnaire", nid)


@pytest.fixture(autouse=True)
def _no_schedule(monkeypatch):
    # the skill fires a fire-and-forget recompute; keep it inert in tests
    monkeypatch.setattr(completeness, "schedule", lambda db, uid: False)


@pytest.fixture(autouse=True)
def _stub_narrative(monkeypatch):
    import gemini
    import wiki_query

    async def _fake(*a, **k):
        return {"assessments": []}

    monkeypatch.setattr(gemini, "generate_json", _fake)
    monkeypatch.setattr(wiki_query, "read_wiki_context", lambda *a, **k: "")


# --- registration -------------------------------------------------------


def test_registered_in_text_and_voice_tool_sets():
    names = {s.name for s in skills.all_skills()}
    assert {"next_questions", "record_answer", "set_relationship_intent"} <= names
    decls = {d["name"] for d in skills.session_tool_declarations()}
    assert {"next_questions", "record_answer", "set_relationship_intent"} <= decls
    # make_livekit_tools iterates the same _REGISTRY, so registry membership is
    # the voice guarantee; assert it directly too when livekit is importable.
    try:
        tools = skills.make_livekit_tools(FakeDb(), "u1")
    except ModuleNotFoundError:
        pytest.skip("livekit-agents not installed in this venv")
    tool_names = {getattr(t, "name", getattr(t, "__name__", "")) for t in tools}
    assert {"next_questions", "record_answer", "set_relationship_intent"} <= tool_names


def test_bound_via_make_session_tool_fns():
    fns = skills.make_session_tool_fns(FakeDb(), "u1")
    assert {"next_questions", "record_answer", "set_relationship_intent"} <= set(fns)


# --- record_answer -----------------------------------------------------


def test_record_answer_validates_writes_and_mirrors_hard_filter():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]

    # loose enum match -> canonical option, written to the questionnaire store
    out = fn("alcohol_consumption", "i drink socially, rarely", "stated")
    assert "recorded" in out
    doc = db.docs[_q("alcohol_consumption")]
    assert doc["value"] == "Rare Social"
    assert doc["source"] == "stated"
    # alcohol_consumption is a hard filter -> mirrored onto profile/main
    assert db.docs[_PROF]["qz_alcohol_consumption"] == "Rare Social"


def test_record_answer_scale_and_bool_and_inferred():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]

    assert "recorded" in fn("social_energy", "about a 7", "stated")
    assert db.docs[_q("social_energy")]["value"] == "7"

    out = fn("smoking_vaping", "no, never", "inferred")
    assert "(inferred)" in out
    d = db.docs[_q("smoking_vaping")]
    assert d["value"] == "false" and d["source"] == "inferred"
    assert db.docs[_PROF]["qz_smoking_vaping"] is False


def test_record_answer_narrative_just_marks_addressed():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]
    out = fn("casual_perfect_night_narrative", "dive bar then a rooftop", "stated")
    assert "recorded" in out
    assert db.docs[_q("casual_perfect_night_narrative")]["value"]


def _taste_page(db):
    return db.docs.get(("users", "u1", "wiki_pages", "taste"))


def test_taste_answers_compose_public_taste_wiki_page():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]

    assert "recorded" in fn(
        "taste_music", "Khruangbin, Bon Iver, Phoebe Bridgers", "stated"
    )
    page = _taste_page(db)
    assert page is not None
    assert page["page_type"] == "taste"
    assert page["visibility"] == "public"
    assert page["ai_body"] == "Music: Khruangbin, Bon Iver, Phoebe Bridgers"

    fn("taste_film", "Arrival, Amélie, Spirited Away", "stated")
    fn("taste_food", "Tartine Bakery, Zuni Café", "stated")
    body = _taste_page(db)["ai_body"]
    assert body == (
        "Music: Khruangbin, Bon Iver, Phoebe Bridgers\n"
        "Film: Arrival, Amélie, Spirited Away\n"
        "Food: Tartine Bakery, Zuni Café"
    )

    # The composed body is exactly what the Qloo engine's parser reads.
    import taste_match

    assert taste_match.parse_taste(body) == {
        "music": ["Khruangbin", "Bon Iver", "Phoebe Bridgers"],
        "film": ["Arrival", "Amélie", "Spirited Away"],
        "dining": ["Tartine Bakery", "Zuni Café"],
    }


def test_taste_page_preserves_user_chosen_visibility_on_reanswer():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]
    fn("taste_music", "Khruangbin", "stated")
    # the user later hides the page themselves
    db.docs[("users", "u1", "wiki_pages", "taste")]["visibility"] = "private"
    fn("taste_music", "Khruangbin, Bon Iver", "stated")
    page = _taste_page(db)
    assert page["visibility"] == "private"
    assert page["ai_body"] == "Music: Khruangbin, Bon Iver"


def test_merge_taste_mentions_fills_film_and_food_from_free_chat():
    """Named films/food the user mentions in free chat populate the TASTE page's
    Film:/Food: lines (not Interests), appending to any direct answer; Music is
    left working. This is the extraction half of taste capture (wiki_ingest)."""
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]
    # Music came in as a direct taste answer.
    fn("taste_music", "Billie Eilish, Bruno Mars", "stated")

    changed = questionnaire.merge_taste_mentions(
        db,
        "u1",
        {
            "music": ["Billie Eilish", "Russ"],  # dupe dropped, Russ appended
            "film": ["Iron Man", "WALL-E", "Terminator"],
            "food": ["ramen"],
        },
    )
    assert set(changed) == {"music", "film", "food"}
    assert db.docs[_q("taste_film")]["value"] == "Iron Man, WALL-E, Terminator"
    assert db.docs[_q("taste_food")]["value"] == "ramen"
    assert db.docs[_q("taste_music")]["value"] == "Billie Eilish, Bruno Mars, Russ"

    import taste_match

    parsed = taste_match.parse_taste(_taste_page(db)["ai_body"])
    assert parsed["film"] == ["Iron Man", "WALL-E", "Terminator"]
    assert parsed["dining"] == ["ramen"]


def test_merge_taste_mentions_caps_dedupes_and_drops_prose():
    db = FakeDb({_PROF: {}})
    changed = questionnaire.merge_taste_mentions(
        db,
        "u1",
        {
            "film": [
                "Iron Man", "iron man", "WALL-E", "Terminator", "Friends",
                "Marvel", "Dune",  # 6th+ unique over the cap of 5 is dropped
                "a long sentence the model mistakenly put here as a title okay",
            ]
        },
    )
    assert changed == ["film"]
    names = db.docs[_q("taste_film")]["value"].split(", ")
    assert len(names) == 5  # capped
    assert "iron man" not in [n for n in names if n != "Iron Man"]  # dedup kept first


def test_merge_taste_mentions_noop_returns_empty():
    db = FakeDb({_PROF: {}})
    assert questionnaire.merge_taste_mentions(db, "u1", {}) == []
    assert questionnaire.merge_taste_mentions(db, "u1", {"film": []}) == []
    assert _taste_page(db) is None


def test_record_answer_bad_node_and_bad_value():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]
    assert "no questionnaire item" in fn("not_a_node", "x", "stated")
    bad = fn("circadian_rhythm", "purple", "stated")
    assert "isn't one of" in bad


# --- provenance (§ fact-source-of-truth, 2026-09-21) ------------------------


def test_record_answer_stores_provenance_when_given_a_session_ctx():
    from transcript import ROLE_AYMA, ROLE_USER, Turn

    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(
        db, "u1",
        session_ctx={
            "session_id": "sess-9",
            "turn_index": 2,
            "turns": [
                Turn(ROLE_AYMA, "socially or more than that?"),
                Turn(ROLE_USER, "just socially, rarely more than that"),
            ],
        },
    )["record_answer"]

    fn("alcohol_consumption", "i drink socially, rarely", "stated")
    prov = db.docs[_q("alcohol_consumption")]["provenance"]
    assert prov["source_type"] == "chat"
    assert prov["quote"] == "just socially, rarely more than that"
    assert prov["session_id"] == "sess-9"
    assert prov["turn_index"] == 2


def test_record_answer_without_session_ctx_has_no_provenance():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]
    fn("alcohol_consumption", "i drink socially, rarely", "stated")
    assert "provenance" not in db.docs[_q("alcohol_consumption")]
    assert _q("circadian_rhythm") not in db.docs


def test_record_answer_refuses_inferred_gender_identity():
    # Founder directive, 2026-09-20: never let a pronoun/gender-identity value
    # be guessed. Unlike other hard-filter nodes (e.g. smoking_vaping above),
    # gender_identity must be refused when marked source="inferred" — nothing
    # gets written, to either the questionnaire store or the mirrored
    # profile/main.qz_gender_identity filter field.
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]

    out = fn("gender_identity", "Female", "inferred")
    assert "no questionnaire item" not in out
    assert not out.startswith("recorded")
    assert _q("gender_identity") not in db.docs
    assert "qz_gender_identity" not in db.docs.get(_PROF, {})

    # but an explicitly stated answer still records normally
    out2 = fn("gender_identity", "Female", "stated")
    assert "recorded" in out2
    assert db.docs[_q("gender_identity")]["value"] == "Female"
    assert db.docs[_q("gender_identity")]["source"] == "stated"
    assert db.docs[_PROF]["qz_gender_identity"] == "Female"


# --- set_relationship_intent + tree switch ---------------------------------


def test_set_relationship_intent_switches_the_active_tree():
    db = FakeDb({_PROF: {}})
    fns = skills.make_session_tool_fns(db, "u1")
    fns["set_relationship_intent"]("casual")
    assert db.docs[_PROF]["relationship_intent"] == "Casual"
    assert db.docs[_PROF]["qz_relationship_intent"] == "Casual"
    assert db.docs[_q("relationship_intent")]["value"] == "Casual"

    _, _, ev = _run(completeness._evaluate(db, "u1"))
    branches = {e["node"]["branch"] for e in ev}
    assert branches == {"all", "casual"}


# --- next_questions ---------------------------------------------------


def test_next_questions_returns_highest_weight_unanswered_first():
    import json

    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["next_questions"]
    payload = json.loads(_run(fn()))
    qs = payload["questions"]
    assert 1 <= len(qs) <= 4
    weights = [q["weight"] for q in qs]
    assert weights == sorted(weights, reverse=True)
    assert weights[0] == 5
    assert {
        "id", "label", "kind", "options", "scale", "ayma_prompt", "weight",
        "sensitive",
    } == set(qs[0])


def test_next_questions_offers_taste_early_for_a_user_without_taste():
    # Founder directive (meta-hackathon): taste must be asked EARLY so the
    # public Taste page / Qloo "Taste match" gets populated. `taste_music` is a
    # promoted, top-weight node, so it rides near the top of the short list the
    # conversational agent is handed, for a user who hasn't answered it yet.
    import json

    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["next_questions"]
    ids = [q["id"] for q in json.loads(_run(fn()))["questions"]]
    assert "taste_music" in ids


def test_next_questions_drops_answered_nodes():
    import json

    db = FakeDb({_PROF: {}})
    fns = skills.make_session_tool_fns(db, "u1")
    fns["record_answer"]("relationship_intent", "Long-term", "stated")
    fns["record_answer"]("procreation_intent", "want kids in 1-3 years", "stated")
    payload = json.loads(_run(fns["next_questions"]()))
    ids = {q["id"] for q in payload["questions"]}
    assert "procreation_intent" not in ids


def test_next_questions_stops_immediately_re_offering_a_declined_item():
    """Real production repro (uid iWhWjiWhEpU7iyu9B9vy7GlT0PD2): the user
    declined a question twice, Ayma moved on, but a couple of exchanges later
    `next_questions` handed the exact same node straight back because it was
    still the single highest-weight unanswered item — nothing ever
    distinguished "just declined" from "never asked". `next_questions` now
    marks what it just returned, so calling it again with nothing recorded
    surfaces something else first instead of looping on the same item.

    All *core* nodes are answered so every section unlocks (core-tier items
    would otherwise gate later sections) — the ~20 remaining *deep*-tier
    nodes are left open as a realistic-size pool, mirroring a user well into
    their questionnaire like the real one this reproduces."""
    import json

    preboard = {
        "name": "Sam", "birthdate": "1990-01-01", "gender": "Woman",
        "interested_in": ["Men"], "location": "Lisbon, Portugal",
    }
    docs = {
        _PROF: {"relationship_intent": "Long-term", **preboard},
        # `set_relationship_intent` always writes both this doc and the
        # profile field together (skills.questionnaire._record) — seed both
        # so this node reads as answered, same as real usage.
        _q("relationship_intent"): {
            "node_id": "relationship_intent", "value": "Long-term",
            "source": "stated",
        },
    }
    for n in question_tree.nodes_for_intent("long_term"):
        nid = n["id"]
        if n["tier"] != "core" or nid in (
            "relationship_intent", "legal_first_name", "date_of_birth",
            "gender_identity", "target_match_genders", "primary_location",
        ):
            continue
        value = (
            n["options"][0] if n["kind"] in ("enum", "multi")
            else "true" if n["kind"] == "bool"
            else "5" if n["kind"] == "scale"
            else "addressed"
        )
        docs[_q(nid)] = {"node_id": nid, "value": value, "source": "stated"}
    db = FakeDb(docs)
    fn = skills.make_session_tool_fns(db, "u1")["next_questions"]

    first = json.loads(_run(fn()))["questions"]
    assert len(first) == 4  # confirms there's a real pool of open deep nodes
    top_id = first[0]["id"]

    # the user declines to answer -> nothing is recorded, Ayma asks again
    second = json.loads(_run(fn()))["questions"]
    assert second[0]["id"] != top_id


def test_next_questions_refreshes_recent_cached_answers():
    import json

    db = FakeDb({_PROF: {}})
    fns = skills.make_session_tool_fns(db, "u1")
    first = json.loads(_run(fns["next_questions"]()))["questions"][0]
    fns["record_answer"](first["id"], first["options"][0] if first["options"] else "Long-term", "stated")
    refreshed = json.loads(_run(fns["next_questions"]()))["questions"]
    assert first["id"] not in {q["id"] for q in refreshed}


# --- coverage v2: concrete answers, sensitive decline, age range ------------


def test_story_narrative_rejects_a_vague_one_word_answer():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]
    out = fn("career_role_narrative", "tech", "stated")
    assert "too thin" in out
    assert _q("career_role_narrative") not in db.docs

    ok = fn(
        "career_role_narrative",
        "Staff ML engineer at a fintech, mostly remote, deep-focus mornings",
        "stated",
    )
    assert ok.startswith("recorded")
    assert db.docs[_q("career_role_narrative")]["value"].startswith("Staff ML")


def test_identity_narratives_may_be_short():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]
    assert fn("primary_location", "Lisbon", "stated").startswith("recorded")


def test_sensitive_node_can_be_declined_and_counts_as_answered():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]
    out = fn("political_orientation", "prefer not to say", "stated")
    assert out.startswith("recorded")
    assert db.docs[_q("political_orientation")]["value"] == "Prefer not to say"
    # mirrored for matching, where it is ignored as a non-answer
    import match_deterministic as md

    node = question_tree.node("political_orientation")
    assert md._typed_value(node, db.docs[_PROF], {}) is None


def test_partner_age_range_is_recorded_as_two_numbers():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]
    assert fn("partner_age_min", "27", "stated").startswith("recorded")
    assert fn("partner_age_max", "36", "stated").startswith("recorded")
    assert db.docs[_PROF]["qz_partner_age_min"] == 27
    assert db.docs[_PROF]["qz_partner_age_max"] == 36
    assert "give a number" in fn("partner_age_min", "17", "stated")


def test_next_questions_flags_sensitive_items():
    import json

    db = FakeDb({_PROF: {}})
    fns = skills.make_session_tool_fns(db, "u1")
    payload = json.loads(_run(fns["next_questions"]()))
    assert all("sensitive" in q for q in payload["questions"])
