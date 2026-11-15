"""Mandatory session-end questionnaire capture — founder reqs 3 & 4."""

import asyncio

import completeness
import gemini
import questionnaire_ingest
import supplemental
from transcript import ROLE_AYMA, ROLE_USER, Turn
from tests.fake_firestore import FakeDb

_UID = "u1"
_Q = ("users", _UID, "questionnaire", "financial_strategy_narrative")


def _run(coro):
    return asyncio.run(coro)


def _no_schedule(monkeypatch):
    # The fire-and-forget completeness recompute would otherwise make a real
    # (unstubbed) Gemini narrative call; the capture path itself is what's under
    # test here.
    monkeypatch.setattr(completeness, "schedule", lambda *a, **k: False)


def _stub(monkeypatch, payload, counter=None):
    async def _fake(contents, *a, **k):  # noqa: ARG001
        if counter is not None:
            counter.append(contents)
        return payload

    monkeypatch.setattr(gemini, "generate_json", _fake)


def _turns():
    return [
        Turn(ROLE_AYMA, "How do you think about money long-term?"),
        Turn(
            ROLE_USER,
            "I'm aiming to retire by 45, I max my 401k and index funds, and I'd "
            "want a partner who saves too.",
        ),
    ]


def test_records_an_open_tree_answer_the_model_never_wrote(monkeypatch):
    _no_schedule(monkeypatch)
    _stub(monkeypatch, {
        "answers": [{
            "node_id": "financial_strategy_narrative",
            "value": "Retire by 45, maxes 401k and index funds, wants a saver partner",
            "source": "stated",
        }],
        "supplemental": [],
    })
    db = FakeDb()
    out = _run(questionnaire_ingest.record_from_turns(db, _UID, "s1", _turns()))
    assert out["answers"] == 1
    # Written to the structured store exactly like record_answer would.
    assert _Q in db.docs and "45" in db.docs[_Q]["value"]
    assert db.docs[_Q]["node_id"] == "financial_strategy_narrative"


def test_records_a_volunteered_off_tree_topic(monkeypatch):
    _no_schedule(monkeypatch)
    _stub(monkeypatch, {
        "answers": [],
        "supplemental": [{
            "section": "family",
            "topic": "Their dog Max",
            "value": "Has a golden retriever named Max",
            "status": "answered",
        }],
    })
    db = FakeDb()
    out = _run(questionnaire_ingest.record_from_turns(db, _UID, "s1", _turns()))
    assert out["supplemental"] == 1
    supp = supplemental.read_supplemental(db, _UID)
    assert supp and supp[0]["topic"] == "Their dog Max"


def test_does_not_touch_an_already_answered_node(monkeypatch):
    _no_schedule(monkeypatch)
    _stub(monkeypatch, {
        "answers": [{
            "node_id": "financial_strategy_narrative",
            "value": "some different later answer that should not overwrite",
            "source": "stated",
        }],
        "supplemental": [],
    })
    db = FakeDb({_Q: {"node_id": "financial_strategy_narrative",
                      "value": "already recorded", "source": "stated"}})
    out = _run(questionnaire_ingest.record_from_turns(db, _UID, "s1", _turns()))
    # Already in the store → not a candidate → never re-recorded.
    assert out["answers"] == 0
    assert db.docs[_Q]["value"] == "already recorded"


def test_thin_answer_is_rejected_by_the_shared_validator(monkeypatch):
    _no_schedule(monkeypatch)
    _stub(monkeypatch, {
        "answers": [{
            "node_id": "financial_strategy_narrative",
            "value": "money",  # too thin for a narrative node
            "source": "stated",
        }],
        "supplemental": [],
    })
    db = FakeDb()
    out = _run(questionnaire_ingest.record_from_turns(db, _UID, "s1", _turns()))
    assert out["answers"] == 0
    assert _Q not in db.docs


def test_no_user_speech_skips_the_llm_entirely(monkeypatch):
    _no_schedule(monkeypatch)
    calls = []
    _stub(monkeypatch, {"answers": [], "supplemental": []}, counter=calls)
    db = FakeDb()
    turns = [Turn(ROLE_AYMA, "Hello there, welcome.")]
    out = _run(questionnaire_ingest.record_from_turns(db, _UID, "s1", turns))
    assert out == {"answers": 0, "supplemental": 0}
    assert calls == []  # no Gemini call made
