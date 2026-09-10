import asyncio

import gemini
import matching_skill


class _Snap:
    def __init__(self, data, doc_id=""):
        self._data = data
        self.id = doc_id

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _QCollection:
    def __init__(self, docs: dict):
        self._docs = docs

    def stream(self):
        return [_Snap(v, k) for k, v in self._docs.items()]


class _ProfileDoc:
    def __init__(self, data):
        self._data = data

    def get(self):
        return _Snap(self._data, "main")


class _ProfileCollection:
    def __init__(self, data):
        self._data = data

    def document(self, _):
        return _ProfileDoc(self._data)


class _UserDoc:
    def __init__(self, rec: dict):
        self._rec = rec

    def get(self):
        return _Snap({"trust_flags": self._rec.get("trust_flags", [])})

    def collection(self, name):
        if name == "profile":
            return _ProfileCollection(self._rec.get("profile", {}))
        if name == "questionnaire":
            return _QCollection(self._rec.get("questionnaire", {}))
        raise AssertionError(name)


class _Users:
    def __init__(self, users: dict):
        self._users = users

    def document(self, uid):
        return _UserDoc(self._users.get(uid, {}))


class _Db:
    def __init__(self, users: dict):
        self._users = users

    def collection(self, name):
        assert name == "users"
        return _Users(self._users)


def _q(**kv):
    return {k: {"value": v, "source": "stated"} for k, v in kv.items()}


def _run(coro):
    return asyncio.run(coro)


# A fully-answered long-term questionnaire (every scored node covered) so no
# dimension falls through to the LLM unless a test removes answers.
_FULL_Q = _q(
    ethnic_cultural_origin="White / European",
    attachment_style="Secure",
    social_energy="5",
    cognitive_processing="Hyper-Rational / Analytical",
    conflict_communication="Cool-down period before verbal processing",
    circadian_rhythm="Balanced / Standard Day",
    cleanliness_index="5",
    alcohol_consumption="Rare Social",
    smoking_vaping="false",
    cannabis_substances="Never",
    pets_owned="Dogs",
    relationship_intent="Long-term",
    relocation_radius="Anywhere in my country",
    primary_location="Lisbon",
    animal_allergies="None",
    capital_vs_experiential="5",
    career_integration_vector="Balanced 9-to-5 / Priority on Leisure",
    financial_comingling='Hybrid "Yours, Mine, and Ours" model',
    procreation_intent="Want children within 4-7 years",
    extended_family_boundary="5",
    parenting_ideology="Gentle / Unstructured / Progressive",
    conversational_friction_demand=(
        "I value harmony, peace, and consensus above intellectual sparring"
    ),
    core_existential_anchor="Family Preservation",
)


def _user(profile=None, questionnaire=None, trust_flags=None, completeness=80):
    prof = dict(profile or {})
    prof.setdefault("relationship_intent", "Long-term")
    prof.setdefault("location", "Lisbon")
    if completeness is not None:
        prof["completeness"] = {"score": completeness}
    return {
        "profile": prof,
        "questionnaire": questionnaire if questionnaire is not None else dict(_FULL_Q),
        "trust_flags": trust_flags or [],
    }


def _patch_wiki(monkeypatch):
    monkeypatch.setattr(
        matching_skill, "read_wiki_context", lambda _db, uid: f"wiki for {uid}"
    )


def _fake_llm(capture=None, dims=None):
    async def _json(contents, system_prompt, response_schema=None, **_kw):
        if capture is not None:
            capture["contents"] = contents
            capture["schema"] = response_schema
        return {
            "dimensions": dims or [],
            "user_explanation": {"A": "for you", "B": "for them"},
            "ai_explanation": "private reasoning",
            "shared": ["both value calm evenings"],
            "tensions": ["different money instincts"],
            "missing": ["how chores get split"],
        }

    return _json


def test_score_pair_returns_confidence_gates_and_per_dim_source(monkeypatch):
    _patch_wiki(monkeypatch)
    monkeypatch.setattr(gemini, "generate_json", _fake_llm())

    db = _Db({"a": _user(), "b": _user()})
    out = _run(matching_skill.score_pair(db, "a", "b"))

    assert 0.0 <= out["score_confidence"] <= 1.0
    assert isinstance(out["confidence_note"], str) and out["confidence_note"]
    assert out["gate_failures"] == []
    assert out["method"]
    assert len(out["dimensions"]) == len(matching_skill._DIM_KEYS)
    for d in out["dimensions"]:
        assert d["source"] in ("structured", "llm")
        assert "covered_nodes" in d
    # Both profiles fully answered the long-term tree -> only `interests`
    # (which has no structured node in that branch) falls to the LLM.
    measured = [d["key"] for d in out["dimensions"] if d["source"] == "structured"]
    assert set(measured) == set(matching_skill._DIM_KEYS) - {"interests"}
    # Two fully detailed profiles, gates all had data -> high confidence.
    assert out["score_confidence"] >= 0.66


def test_covered_dimensions_are_not_sent_to_the_llm(monkeypatch):
    _patch_wiki(monkeypatch)
    cap = {}
    monkeypatch.setattr(gemini, "generate_json", _fake_llm(capture=cap))

    # A answers nothing about interests/personality-only nodes; drop the
    # nodes that feed `interests` and `communication` for BOTH so those two
    # fall to the LLM, but keep everything else measured.
    q = dict(_FULL_Q)
    db = _Db({"a": _user(questionnaire=q), "b": _user(questionnaire=dict(q))})
    out = _run(matching_skill.score_pair(db, "a", "b"))

    structured_keys = {
        d["key"] for d in out["dimensions"] if d["source"] == "structured"
    }
    llm_keys = {d["key"] for d in out["dimensions"] if d["source"] == "llm"}
    # `interests` has no long-term structured node -> always LLM.
    assert "interests" in llm_keys
    assert "values" in structured_keys

    # The prompt's "score ONLY these keys" list must be exactly the llm keys,
    # and must not contain any measured dimension.
    import json

    tail = cap["contents"].rsplit("\n", 1)[-1]
    sent = set(json.loads(tail.strip()))
    assert sent == llm_keys
    assert not (sent & structured_keys)
    # The response schema only allows the llm keys.
    enum = cap["schema"]["properties"]["dimensions"]["items"]["properties"][
        "key"
    ]["enum"]
    assert set(enum) == llm_keys


def test_low_completeness_yields_low_confidence(monkeypatch):
    _patch_wiki(monkeypatch)
    monkeypatch.setattr(
        gemini,
        "generate_json",
        _fake_llm(
            dims=[
                {"key": k, "score": 55, "rationale": "r", "confidence": "low"}
                for k in matching_skill._DIM_KEYS
            ]
        ),
    )

    # b has almost nothing filled in.
    db = _Db(
        {
            "a": _user(completeness=90),
            "b": _user(
                questionnaire=_q(attachment_style="Secure"),
                completeness=8,
            ),
        }
    )
    out = _run(matching_skill.score_pair(db, "a", "b"))
    assert out["score_confidence"] < 0.4
    assert out["confidence_note"].lower().startswith("lower confidence")


def test_hard_gate_caps_score_and_surfaces_a_dealbreaker(monkeypatch):
    _patch_wiki(monkeypatch)
    monkeypatch.setattr(
        gemini,
        "generate_json",
        _fake_llm(
            dims=[
                {"key": k, "score": 95, "rationale": "great", "confidence": "high"}
                for k in matching_skill._DIM_KEYS
            ]
        ),
    )

    qa = dict(_FULL_Q)
    qa["procreation_intent"] = {
        "value": "Absolutely non-negotiably childfree",
        "source": "stated",
    }
    qb = dict(_FULL_Q)
    qb["procreation_intent"] = {
        "value": "Want children within 1-3 years",
        "source": "stated",
    }
    db = _Db(
        {"a": _user(questionnaire=qa), "b": _user(questionnaire=qb)}
    )
    out = _run(matching_skill.score_pair(db, "a", "b"))

    assert any(
        g["node_id"] == "procreation_intent" for g in out["gate_failures"]
    )
    # gate cap is 25/100 -> 0.25, minus nothing here.
    assert out["score"] <= 0.25


def test_trust_flags_still_penalise(monkeypatch):
    _patch_wiki(monkeypatch)
    monkeypatch.setattr(gemini, "generate_json", _fake_llm())

    clean = _Db({"a": _user(), "b": _user()})
    flagged = _Db(
        {
            "a": _user(trust_flags=[1, 2]),
            "b": _user(trust_flags=[3]),
        }
    )
    base = _run(matching_skill.score_pair(clean, "a", "b"))
    pen = _run(matching_skill.score_pair(flagged, "a", "b"))
    assert abs(base["raw_score"] - pen["raw_score"]) < 1e-9
    assert abs((base["score"] - pen["score"]) - 0.24) < 1e-6


def test_score_pair_requires_both_wikis(monkeypatch):
    monkeypatch.setattr(
        matching_skill,
        "read_wiki_context",
        lambda _db, uid: "" if uid == "b" else "has wiki",
    )
    import pytest

    db = _Db({"a": _user(), "b": _user()})
    with pytest.raises(ValueError):
        _run(matching_skill.score_pair(db, "a", "b"))


def test_llm_dimension_falls_back_to_neutral_when_model_omits_it(monkeypatch):
    _patch_wiki(monkeypatch)
    # Model returns nothing for the interests dimension it was asked to score.
    monkeypatch.setattr(gemini, "generate_json", _fake_llm(dims=[]))
    db = _Db({"a": _user(), "b": _user()})
    out = _run(matching_skill.score_pair(db, "a", "b"))
    interests = next(d for d in out["dimensions"] if d["key"] == "interests")
    assert interests["source"] == "llm"
    assert interests["score"] == 50.0
    assert interests["confidence"] == "low"
