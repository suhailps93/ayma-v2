import dataclasses

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
        import start_grant
    except ModuleNotFoundError:  # pragma: no cover - agent venv
        return
    monkeypatch.setattr(
        start_grant, "grant_status",
        lambda _uid, _data: start_grant.GRANT_OK,
    )


@pytest.fixture(autouse=True)
def no_routing_doc(monkeypatch):
    """Feature flags (config/feature_flags and the legacy docs) are never read
    from Firestore in tests; flag tests set ``feature_flags._read_docs`` or the
    ``FLAG_<NAME>`` env themselves."""
    import feature_flags

    monkeypatch.setattr(feature_flags, "_read_docs", lambda: {})
    # Baseline for the existing suite: HOSTILE routing flags (Google routes,
    # fallback on) — the 2026-11-04 kill means routing ignores them and every
    # call still goes to Inference. Optional features off. The branch's ON
    # defaults are asserted in test_feature_flags.
    monkeypatch.setattr(
        feature_flags,
        "CONFIG",
        dataclasses.replace(
            feature_flags.CONFIG,
            llm_route_json="vertex",
            llm_route_vision="vertex",
            llm_route_chat="vertex",
            voice_provider="google",
            llm_inference_fallback=True,
            gemini_maps_grounding=False,
            deepdive_public_profiles=False,
            vertex_ai_search=False,
        ),
    )
    feature_flags.reset_cache()


@pytest.fixture(autouse=True)
def no_link_network(monkeypatch):
    """Deep-dive link validation never touches the network in tests: every
    URL counts as working, grounding redirects pass through and stored-report
    revalidation is off. test_deep_dive_links.py exercises the real checks
    against a mocked transport."""
    try:
        import deep_dive_links
    except ModuleNotFoundError:  # pragma: no cover - agent venv
        return
    monkeypatch.setattr(deep_dive_links, "_check", lambda url, grounded: True)
    monkeypatch.setattr(deep_dive_links, "resolve_grounding_url", lambda url: url)
    monkeypatch.setattr(
        deep_dive_links, "revalidate_in_background", lambda *a, **k: None
    )
    deep_dive_links._reset_cache()


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
    # Practice Date endpoints also call get_db directly, so patch it there too
    try:
        import practice_date
        monkeypatch.setattr(practice_date, "get_db", lambda: object())
    except ModuleNotFoundError:  # pragma: no cover - agent venv
        pass
    # The 18+ gate has its own tests (test_age_gate.py); everywhere else every
    # test caller is treated as a verified adult.
    monkeypatch.setattr(
        main.age_gate, "enforce", lambda *a, **k: None
    )
    return rec


@pytest.fixture(autouse=True)
def biometric_consent_granted(request, monkeypatch):
    """Every test account holds the mandatory biometric consent; the consent
    gate's own tests opt out with ``@pytest.mark.real_biometric_consent``."""
    if request.node.get_closest_marker("real_biometric_consent"):
        return
    try:
        import biometric_consent
    except ModuleNotFoundError:  # pragma: no cover - agent venv
        return
    monkeypatch.setattr(biometric_consent, "has_consent", lambda _db, _uid: True)
    monkeypatch.setattr(biometric_consent, "has_consent_fresh", lambda _db, _uid: True)
