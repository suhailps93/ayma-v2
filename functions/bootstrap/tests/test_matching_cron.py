import asyncio
from datetime import datetime, timezone

import matching
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


# --- NOTE 244: the bounded re-score sweep over existing pairs ---------------

_OLD = datetime(2026, 10, 29, 5, 7, 13, tzinfo=timezone.utc)  # the founder's stuck scored_at
_NEWER = datetime(2026, 11, 16, tzinfo=timezone.utc)          # a profile edit after the move


def _score_result(score):
    def _fields(a, b):
        return {
            "score": score,
            "structured_score": None,
            "dimensions": [],
            "user_explanation": {a: "", b: ""},
            "ai_explanation": "",
            "shared": [], "tensions": [], "missing": [],
            "gate_failures": [], "score_confidence": 0.1,
            "confidence_note": "", "method": "",
            "trust_flags": {a: [], b: []},
        }
    return _fields


def _fake_score(score):
    calls = []

    async def _score(db_, a, b, *, charge_uid=None):
        calls.append((a, b, charge_uid))
        return _score_result(score)(a, b)

    return _score, calls


async def _no_notify(*a, **k):
    return None


def _seed_scored_pair(db, a, b, *, scored_at, updated_at=None, score=0.589, **extra):
    """An EXISTING scored pair doc, the way a prior Pass-2/recalculate left it."""
    lo, hi = sorted((a, b))
    mid = sorted_pair_key(a, b)
    doc = {
        "uids": [lo, hi],
        "score": score,
        "structured_score": None,
        "status": "scored",
        "scored_at": scored_at,
        "updated_at": updated_at if updated_at is not None else scored_at,
    }
    doc.update(extra)
    db.docs[("matches", mid)] = doc
    return mid


def _prep(monkeypatch, score=0.74):
    monkeypatch.setattr(matching_cron.firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP)
    fake, calls = _fake_score(score)
    monkeypatch.setattr(matching_cron.matching_skill, "score_pair", fake)
    monkeypatch.setattr(matching_cron, "notify_new_scored_matches", _no_notify)
    return calls


def test_cron_rescores_a_stale_existing_pair_and_bumps_scored_at(monkeypatch):
    """The core NOTE 244 fix: a stored pair whose inputs changed since it was
    scored (profile edited after the Austin move) must be re-scored by the
    cron and get a FRESH ``scored_at`` — Pass 1 excludes already-matched pairs
    from sourcing, so without the sweep the pair is never re-scored and its
    ``scored_at`` freezes forever. A mutual_interest pair keeps its status and
    ``accepted_by`` (merge write)."""
    calls = _prep(monkeypatch, score=0.74)
    db = FakeDb()
    _seed_user(db, "u1", updated_at=_NEWER, community="c", gender="Woman",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    _seed_user(db, "u2", updated_at=_OLD, community="c", gender="Man",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    both = sorted(("u1", "u2"))
    mid = _seed_scored_pair(db, "u1", "u2", scored_at=_OLD, score=0.589,
                            status="mutual_interest", accepted_by=both)

    result = asyncio.run(matching_cron.run(db, user_limit=10))

    doc = db.docs[("matches", mid)]
    assert doc["scored_at"] is SERVER_TIMESTAMP   # bumped off the Oct-29 datetime
    assert doc["score"] == 0.74                   # the fresh score landed
    assert doc["status"] == "mutual_interest"     # not clobbered back to "scored"
    assert doc["accepted_by"] == both             # preserved by the merge write
    assert result["pairs_rescored"] == 1
    assert len(calls) == 1                         # inference actually ran, once


def test_cron_leaves_a_fresh_pair_alone(monkeypatch):
    """A pair scored AFTER its inputs last changed is not stale — no re-score,
    no inference spend, ``scored_at`` untouched."""
    calls = _prep(monkeypatch, score=0.74)
    db = FakeDb()
    _seed_user(db, "u1", updated_at=_OLD, community="c", gender="Woman",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    _seed_user(db, "u2", updated_at=_OLD, community="c", gender="Man",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    mid = _seed_scored_pair(db, "u1", "u2", scored_at=_NEWER, score=0.589)

    result = asyncio.run(matching_cron.run(db, user_limit=10))

    assert db.docs[("matches", mid)]["scored_at"] == _NEWER  # unchanged
    assert result["pairs_rescored"] == 0
    assert calls == []                                        # no spend


def test_cron_rescore_keys_on_scored_at_not_updated_at(monkeypatch):
    """The founder's exact lead: ``updated_at`` bumped on some docs (a
    like/pass/accept) while ``scored_at`` stayed put. A recent ``updated_at``
    must NOT mask a stale score — ``score_is_stale`` keys on ``scored_at``, so
    the pair is still re-scored."""
    calls = _prep(monkeypatch, score=0.74)
    db = FakeDb()
    _seed_user(db, "u1", updated_at=_NEWER, community="c", gender="Woman",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    _seed_user(db, "u2", updated_at=_OLD, community="c", gender="Man",
               interested_in=["Everyone"], location="X", birthdate="1994-01-01")
    very_recent = datetime(2026, 11, 16, 23, 59, tzinfo=timezone.utc)
    mid = _seed_scored_pair(db, "u1", "u2", scored_at=_OLD, updated_at=very_recent)

    result = asyncio.run(matching_cron.run(db, user_limit=10))

    assert db.docs[("matches", mid)]["scored_at"] is SERVER_TIMESTAMP  # re-scored
    assert result["pairs_rescored"] == 1
    assert len(calls) == 1


def test_cron_rescore_budget_caps_inference_spend(monkeypatch):
    """The cost guard: the sweep re-scores at most ``rescore_budget`` pairs per
    run, never an unbounded re-score across all users; ``0`` disables it."""
    calls = _prep(monkeypatch, score=0.74)
    db = FakeDb()
    # Each pair sits in its OWN community so Pass 1 never cross-sources a new
    # pairing between pairs — the only scoring in this run is the re-sweep.
    pairs = [("u1", "u2", "c1"), ("u3", "u4", "c2"), ("u5", "u6", "c3")]
    for a, b, comm in pairs:
        _seed_user(db, a, updated_at=_NEWER, community=comm, gender="Woman",
                   interested_in=["Everyone"], location="X", birthdate="1994-01-01")
        _seed_user(db, b, updated_at=_OLD, community=comm, gender="Man",
                   interested_in=["Everyone"], location="X", birthdate="1994-01-01")
        _seed_scored_pair(db, a, b, scored_at=_OLD)

    capped = asyncio.run(matching_cron.run(db, user_limit=10, rescore_budget=2))
    assert capped["pairs_rescored"] == 2
    assert len(calls) == 2   # exactly the budget — no more inference than allowed

    off = asyncio.run(matching_cron.run(db, user_limit=10, rescore_budget=0))
    assert off["pairs_rescored"] == 0
