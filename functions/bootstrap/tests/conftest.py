import pytest

import main


class _Recorder:
    def __init__(self):
        self.persisted = []
        self.ingested = []


@pytest.fixture(autouse=True)
def no_firestore(monkeypatch):
    """Keep Firestore and the ingest LLM call off the wire in every test.
    Returns a recorder of what would have been persisted / ingested."""
    rec = _Recorder()

    def _fake_persist(_db, uid, session_id, turns):
        rec.persisted.append(
            {"uid": uid, "session_id": session_id, "turns": list(turns)}
        )

    async def _fake_ingest(_db, uid, session_id, turns):
        rec.ingested.append(
            {"uid": uid, "session_id": session_id, "turns": list(turns)}
        )
        return 0

    monkeypatch.setattr(main, "persist_raw_turns", _fake_persist)
    monkeypatch.setattr(main, "wiki_ingest", _fake_ingest)
    monkeypatch.setattr(main, "get_db", lambda: object())
    return rec
