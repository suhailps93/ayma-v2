import asyncio

import matching_cron
from fake_firestore import SERVER_TIMESTAMP, FakeDb
from pair_key import sorted_pair_key


def _seed_user(db, uid, **profile):
    profile.setdefault("name", uid)
    db.docs[("users", uid)] = {"x": 1}
    db.docs[("users", uid, "profile", "main")] = profile


def test_cron_run_clears_stale_candidates_once_it_writes_a_real_match(
    monkeypatch,
):
    """The scheduled two-pass pipeline (Pass 1 sourcing -> Pass 2 scoring)
    must leave exactly one live record for a pair it just scored — the
    ``matches`` doc — not that plus a leftover Pass-1 ``match_candidates``
    entry from an earlier run on either side."""
    monkeypatch.setattr(matching_cron.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)

    db = FakeDb()
    _seed_user(db, "u1", community="c", gender="Woman",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    _seed_user(db, "u2", community="c", gender="Man",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    # A stale Pass-1 entry from a run that predates this pair ever being
    # scored — exactly the kind of leftover Explore could still misread.
    db.docs[("users", "u2", "match_candidates", "u1")] = {
        "heuristic_score": 0.29}

    async def _fake_score(db_, a, b, *, charge_uid=None):
        return {
            "score": 0.0,
            "structured_score": None,
            "dimensions": [],
            "user_explanation": {a: "", b: ""},
            "ai_explanation": "",
            "shared": [], "tensions": [], "missing": [],
            "gate_failures": [], "score_confidence": 0.1,
            "confidence_note": "", "method": "",
            "trust_flags": {a: [], b: []},
        }

    async def _no_notify(*a, **k):
        return None

    monkeypatch.setattr(matching_cron.matching_skill, "score_pair", _fake_score)
    monkeypatch.setattr(
        matching_cron, "notify_new_scored_matches", _no_notify
    )

    result = asyncio.run(matching_cron.run(db, user_limit=10))

    match_id = sorted_pair_key("u1", "u2")
    assert result["matches_written"] >= 1
    assert db.docs[("matches", match_id)]["score"] == 0.0
    assert ("users", "u2", "match_candidates", "u1") not in db.docs
    assert ("users", "u1", "match_candidates", "u2") not in db.docs
