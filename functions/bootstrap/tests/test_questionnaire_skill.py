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


def test_record_answer_bad_node_and_bad_value():
    db = FakeDb({_PROF: {}})
    fn = skills.make_session_tool_fns(db, "u1")["record_answer"]
    assert "no questionnaire item" in fn("not_a_node", "x", "stated")
    bad = fn("circadian_rhythm", "purple", "stated")
    assert "isn't one of" in bad
    assert _q("circadian_rhythm") not in db.docs


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
    assert {"id", "label", "kind", "options", "scale", "ayma_prompt", "weight"} == set(qs[0])


def test_next_questions_drops_answered_nodes():
    import json

    db = FakeDb({_PROF: {}})
    fns = skills.make_session_tool_fns(db, "u1")
    fns["record_answer"]("relationship_intent", "Long-term", "stated")
    fns["record_answer"]("procreation_intent", "want kids in 1-3 years", "stated")
    payload = json.loads(_run(fns["next_questions"]()))
    ids = {q["id"] for q in payload["questions"]}
    assert "procreation_intent" not in ids


def test_next_questions_refreshes_recent_cached_answers():
    import json

    db = FakeDb({_PROF: {}})
    fns = skills.make_session_tool_fns(db, "u1")
    first = json.loads(_run(fns["next_questions"]()))["questions"][0]
    fns["record_answer"](first["id"], first["options"][0] if first["options"] else "Long-term", "stated")
    refreshed = json.loads(_run(fns["next_questions"]()))["questions"]
    assert first["id"] not in {q["id"] for q in refreshed}
