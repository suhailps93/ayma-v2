"""Person-graph authoritative → the wiki STOPS being written, and the old
wiki-write tool (`remember`) leaves the tool set (design §9.5).

NOTE 225 (build 2451): the automatic post-turn ingest still wrote wiki_pages —
gated at `main._run_ingest` (Fix 1). NOTE 227 (build 2453, flags verified ON):
chat facts STILL landed in wiki_pages while graph/main stayed untouched, because
`remember` (an LLM tool) and the voice/session-end ingest
(`post_turn.persist_and_ingest`) BYPASSED that single gate. The gate now lives
centrally in `wiki_ingest.ingest` (every caller lands there) AND `remember` is
dropped from the tool set so the model records off-script facts in the graph via
`pg_add_node` instead of wiki_pages. (The structured fact-writers
`set_profile_field`/`record_answer`/`set_relationship_intent` still write
profile/qstore — non-graph code reads those — so their swap to `pg_set_answer`
waits on the Phase-7 reader migration and is NOT done here.)
"""

import asyncio
import dataclasses

import config
import gemini
import questionnaire_ingest
import skills
import wiki_ingest
from config import CONFIG
from transcript import ROLE_USER, Turn

_TURNS = [Turn(ROLE_USER, "I have a dog named Biscuit")]


# --- the central ingest gate: EVERY wiki write path lands here ---------------


def _stub_ingest(monkeypatch, *, reads: bool):
    monkeypatch.setattr(
        wiki_ingest, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=reads)
    )
    captured: list[str] = []

    async def _fake_capture(db, uid, session_id, turns):
        captured.append(uid)

    monkeypatch.setattr(questionnaire_ingest, "record_from_turns", _fake_capture)
    monkeypatch.setattr(wiki_ingest, "_read_existing_pages", lambda db, uid: [])

    async def _no_pages(*a, **k):
        return {"pages": []}

    monkeypatch.setattr(gemini, "generate_json", _no_pages)
    return captured


def test_wiki_ingest_suppressed_when_graph_authoritative(monkeypatch):
    captured = _stub_ingest(monkeypatch, reads=True)
    written = asyncio.run(
        wiki_ingest.ingest(
            object(), "u1", "s1", _TURNS, capture_questionnaire=True
        )
    )
    assert written == 0           # §9.5: the wiki stops being written
    assert captured == []         # gate short-circuits — not even structured capture ran


def test_wiki_ingest_runs_when_graph_flag_off(monkeypatch):
    captured = _stub_ingest(monkeypatch, reads=False)
    written = asyncio.run(
        wiki_ingest.ingest(
            object(), "u1", "s1", _TURNS, capture_questionnaire=True
        )
    )
    assert written == 0           # no pages from the stubbed extractor…
    assert captured == ["u1"]     # …but the gate was NOT taken: ingest proceeded


# --- the tool set: `remember` out, `pg_add_node` in, when graph-authoritative --


def test_remember_dropped_from_toolset_when_graph_authoritative(monkeypatch):
    monkeypatch.setattr(
        config, "CONFIG",
        dataclasses.replace(CONFIG, person_graph_reads=True, person_graph_tools=True),
    )
    names = {d["name"] for d in skills.session_tool_declarations()}
    assert "remember" not in names     # the wiki-write tool is gone
    assert "pg_add_node" in names      # the graph write tool is offered instead


def test_remember_present_when_graph_flag_off(monkeypatch):
    monkeypatch.setattr(
        config, "CONFIG",
        dataclasses.replace(CONFIG, person_graph_reads=False, person_graph_tools=False),
    )
    names = {d["name"] for d in skills.session_tool_declarations()}
    assert "remember" in names         # unchanged when the flag is off
