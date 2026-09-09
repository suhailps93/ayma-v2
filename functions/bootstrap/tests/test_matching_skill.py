import asyncio

import gemini
import matching_skill


def _db_with_wikis(flags_a=None, flags_b=None):
    class _Snap:
        def __init__(self, data):
            self._data = data

        @property
        def exists(self):
            return self._data is not None

        def to_dict(self):
            return dict(self._data or {})

    class _DocRef:
        def __init__(self, uid):
            self.uid = uid

        def get(self):
            data = {
                "a": {"trust_flags": flags_a or []},
                "b": {"trust_flags": flags_b or []},
            }.get(self.uid)
            return _Snap(data)

        def collection(self, _):
            return self

    class _Db:
        def collection(self, _):
            return self

        def document(self, uid):
            return _DocRef(uid)

    return _Db()


def _run(coro):
    return asyncio.run(coro)


def test_score_pair_shapes_output_and_applies_trust_penalty(monkeypatch):
    monkeypatch.setattr(
        matching_skill, "read_wiki_context",
        lambda _db, uid: f"wiki for {uid}",
    )

    async def _fake_json(contents, system_prompt, response_schema=None, **_kw):
        assert "WIKI A" in contents and "WIKI B" in contents
        # Every dimension at 70 -> weighted mean = 0.70 exactly.
        return {
            "dimensions": [
                {"key": k, "score": 70, "rationale": f"r-{k}",
                 "evidence": ["e1"], "confidence": "high"}
                for k in matching_skill._DIM_KEYS
            ],
            "user_explanation": {"A": "you two align on X", "B": "they value Y"},
            "ai_explanation": "full reasoning",
            "shared": ["both want kids soon", "", "share a running habit"],
            "tensions": ["different pace around money"],
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    # no flags -> weighted mean of the dimension scores
    out = _run(matching_skill.score_pair(_db_with_wikis(), "a", "b"))
    assert abs(out["score"] - 0.70) < 1e-6
    assert len(out["dimensions"]) == len(matching_skill._DIM_KEYS)
    assert out["dimensions"][0]["label"]  # enriched with the label + weight
    assert abs(sum(d["weight"] for d in out["dimensions"]) - 1.0) < 1e-6
    assert set(out["user_explanation"]) == {"a", "b"}
    assert out["ai_explanation"] == "full reasoning"
    assert out["shared"] == ["both want kids soon", "share a running habit"]
    assert out["tensions"] == ["different pace around money"]

    # two flags on a, one on b -> 3 * 0.08 penalty off the raw 0.70
    out2 = _run(
        matching_skill.score_pair(
            _db_with_wikis(flags_a=[1, 2], flags_b=[3]), "a", "b"
        )
    )
    assert abs(out2["score"] - (0.70 - 0.24)) < 1e-6
    assert abs(out2["raw_score"] - 0.70) < 1e-6


def test_score_pair_fills_missing_dimensions_with_a_neutral(monkeypatch):
    monkeypatch.setattr(
        matching_skill, "read_wiki_context", lambda _db, uid: f"wiki {uid}"
    )

    async def _sparse(*a, **k):
        return {
            "dimensions": [
                {"key": "values", "score": 90, "rationale": "aligned"},
            ],
            "user_explanation": {"A": "x", "B": "y"},
            "ai_explanation": "z",
        }

    monkeypatch.setattr(gemini, "generate_json", _sparse)
    out = _run(matching_skill.score_pair(_db_with_wikis(), "a", "b"))
    dims = {d["key"]: d for d in out["dimensions"]}
    assert dims["values"]["score"] == 90
    assert dims["personality"]["score"] == 50  # missing -> neutral
    assert dims["personality"]["confidence"] == "low"


def test_score_pair_requires_both_wikis(monkeypatch):
    monkeypatch.setattr(
        matching_skill, "read_wiki_context",
        lambda _db, uid: "" if uid == "b" else "has wiki",
    )
    import pytest

    with pytest.raises(ValueError):
        _run(matching_skill.score_pair(_db_with_wikis(), "a", "b"))
