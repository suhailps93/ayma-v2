import pytest

try:  # the agent venv has no fastapi — its tests never use this fixture
    import main
    import ratelimit

    # Repeated TestClient calls to one route would otherwise trip the limiter.
    ratelimit.ENABLED = False
except ModuleNotFoundError:  # pragma: no cover
    main = None


class _Recorder:
    def __init__(self):
        self.persisted = []
        self.ingested = []


@pytest.fixture(autouse=True)
def accounts_verified(monkeypatch):
    """Treat every test account as eligible for the start grant (verified +
    selfie, not a duplicate) and keep Firebase Auth/Firestore vector lookups off the wire; the anti-abuse tests
    in test_billing.py override this."""
    try:
        import token_ledger
    except ModuleNotFoundError:  # pragma: no cover - agent venv
        return
    monkeypatch.setattr(
        token_ledger, "_grant_status", lambda _uid, _data: token_ledger.GRANT_OK
    )


@pytest.fixture(autouse=True)
def no_routing_doc(monkeypatch):
    """The runtime routing override (config/llm_routing) is never read from
    Firestore in tests; routing tests set ``llm_routing._read_doc`` themselves."""
    import llm_routing

    monkeypatch.setattr(llm_routing, "_read_doc", lambda: {})


@pytest.fixture(autouse=True)
def no_firestore(monkeypatch):
    """Keep Firestore and the ingest LLM call off the wire in every test.
    Returns a recorder of what would have been persisted / ingested."""
    rec = _Recorder()
    if main is None:
        return rec

    def _fake_persist(_db, uid, session_id, turns):
        rec.persisted.append(
            {"uid": uid, "session_id": session_id, "turns": list(turns)}
        )

    async def _fake_ingest(_db, uid, session_id, turns):
        rec.ingested.append(
            {"uid": uid, "session_id": session_id, "turns": list(turns)}
        )
        return 0

    class _FakeTurnCaps:
        @staticmethod
        def evaluate(_db, uid, mode):
            from turn_caps import TurnCapResult

            return TurnCapResult(True, None, False, mode, 0, 0)

        @staticmethod
        def peek(_db, _uid, mode):
            return {"mode": mode, "count": 0, "cap": 0, "reached": False}

    monkeypatch.setattr(main, "persist_raw_turns", _fake_persist)
    monkeypatch.setattr(main, "wiki_ingest", _fake_ingest)
    monkeypatch.setattr(
        main, "read_wiki_context", lambda _db, _uid, *a, **k: ""
    )
    monkeypatch.setattr(main, "turn_caps", _FakeTurnCaps)
    monkeypatch.setattr(main, "_session_mode", lambda _caller: "marketing")
    monkeypatch.setattr(main, "_recovery_required", lambda _uid: False)
    monkeypatch.setattr(main, "get_db", lambda: object())
    return rec
