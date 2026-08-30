import pytest

import main


@pytest.fixture(autouse=True)
def no_firestore(monkeypatch):
    """Keep raw_turns persistence off the wire in every test. Returns the list
    of persist calls so a test can assert on what would have been written."""
    calls = []

    def _fake_persist(_db, uid, session_id, turns):
        calls.append(
            {"uid": uid, "session_id": session_id, "turns": list(turns)}
        )

    monkeypatch.setattr(main, "persist_raw_turns", _fake_persist)
    monkeypatch.setattr(main, "get_db", lambda: object())
    return calls
