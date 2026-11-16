"""Person-graph is authoritative → the wiki stops being written (design §9.5).

NOTE 225 Leg 3 (demo-test1, build 2451): with the switch meant to be live,
chat-learned facts still landed in the OLD ``wiki_pages`` store (the Career
answer woven into ``design-and-craft`` ai_body, "Biscuit" into ``pets``),
because the automatic post-turn ingest (``main._run_ingest`` → ``wiki_ingest``)
runs unconditionally. When the graph is authoritative (``PERSON_GRAPH_READS``)
the automatic wiki write must stop — renders read the graph and chat facts land
in the graph via the ``pg_*`` write tools. The old documents are kept read-only
(Phase 7 deletion stays gated).
"""

import asyncio
import dataclasses

import main
from config import CONFIG
from transcript import ROLE_USER, Turn


def _patch(monkeypatch, *, reads: bool):
    monkeypatch.setattr(
        main, "CONFIG", dataclasses.replace(CONFIG, person_graph_reads=reads)
    )
    calls = []

    async def _fake_ingest(db, uid, session_id, turns, *, capture_questionnaire=False):
        calls.append((uid, session_id, capture_questionnaire))
        return 1

    monkeypatch.setattr(main, "wiki_ingest", _fake_ingest)
    monkeypatch.setattr(main, "get_db", lambda: object())
    return calls


def test_run_ingest_skips_wiki_when_graph_authoritative(monkeypatch):
    calls = _patch(monkeypatch, reads=True)
    asyncio.run(
        main._run_ingest(
            "u1", "s1", [Turn(ROLE_USER, "I have a dog named Biscuit")],
            capture_questionnaire=True,
        )
    )
    assert calls == []  # §9.5: the wiki stops being written


def test_run_ingest_writes_wiki_when_graph_flag_off(monkeypatch):
    calls = _patch(monkeypatch, reads=False)
    asyncio.run(
        main._run_ingest("u1", "s1", [Turn(ROLE_USER, "I have a dog named Biscuit")])
    )
    assert calls == [("u1", "s1", False)]  # unchanged when the flag is off
