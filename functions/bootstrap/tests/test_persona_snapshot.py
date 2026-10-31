"""Persistent AI-avatar snapshot (founder directive 2026-10-27).

Proves the standing-snapshot guarantees deterministically (offline fake LLM):
* a snapshot is written with the full private grounding + style exemplars and
  reads back instantly as a PersonaContext;
* the background refresh is SKIPPED when ``source_hash`` is unchanged, SKIPPED
  when younger than the min interval, and only REBUILDS (LLM) when genuinely due;
* a source write (DM send) flips ``stale`` without any LLM call;
* an opted-out user gets no snapshot (and an existing one is deleted);
* the defence-in-depth private-leak scrub removes obvious contact/address data,
  including out of an LLM-distilled brief before it is persisted;
* date-sim spawns the match's own snapshot when eligible, else the public-only
  persona; and the sim preflight carries the avatar readiness score;
* readiness score math (weights, 0-100, rounding) and the low-context boundary.
"""

from __future__ import annotations

import asyncio
from types import SimpleNamespace

import pytest

import config
import date_sim
import persona_snapshot
import practice_core
import practice_llm
import practice_seed
import token_ledger
from fake_firestore import FakeDb

VIEWER = "viewer_uid"
MAYA = "demo_practice_maya"
NEEDLE_ADDRESS = "999 Needle Lane"


def _seeded_db() -> FakeDb:
    db = FakeDb()
    practice_seed.seed(db)
    user = db.collection("users").document(VIEWER)
    user.collection("profile").document("main").set(
        {
            "name": "Sam",
            "gender": "man",
            "birthdate": "1992-04-10",
            "location": "San Francisco",
            "photos": [{"url": "p1"}],
        }
    )
    user.collection("wiki_pages").document("about").set(
        {
            "visibility": "public",
            "page_type": "about",
            "title": "About Sam",
            "ai_body": "Rock climber, amateur chef, terrible at board games.",
        }
    )
    user.collection("wiki_pages").document("private").set(
        {
            "visibility": "private",
            "page_type": "misc",
            "title": "Private",
            "ai_body": f"Home address is {NEEDLE_ADDRESS}. Private stuff.",
        }
    )
    return db


def _avatar_doc(db, uid):
    return (
        db.collection("users").document(uid).collection("persona").document("avatar")
    )


# --- snapshot written + read ---------------------------------------------- #
def test_snapshot_written_and_read_back():
    db = _seeded_db()
    ctx = asyncio.run(
        persona_snapshot.build_persona_snapshot(db, VIEWER, distill=False)
    )
    assert ctx is not None and ctx.name == "Sam"
    # Full private grounding is in the snapshot (own data).
    assert NEEDLE_ADDRESS in ctx.to_prompt_block()

    data = _avatar_doc(db, VIEWER).get().to_dict()
    assert data["version"] == persona_snapshot.SNAPSHOT_VERSION
    assert data["source_hash"]
    assert data["distilled"] is False and data["stale"] is True  # seed → needs distill
    assert "readiness_score" in data and "low_context" in data

    # get_persona_snapshot reconstructs the same persona instantly.
    read = persona_snapshot.get_persona_snapshot(db, VIEWER)
    assert read is not None and read.name == "Sam"
    assert NEEDLE_ADDRESS in read.to_prompt_block()


def test_get_snapshot_none_when_missing():
    assert persona_snapshot.get_persona_snapshot(FakeDb(), "ghost") is None


# --- refresh gating: source_hash + min-interval ---------------------------- #
def _distill_ok(brief: str = "You are Sam, a climber.", highlights=None):
    calls = {"n": 0}

    async def fake_json(system, contents, schema, uid, feature):
        calls["n"] += 1
        return {"brief": brief, "story_highlights": highlights or ["Climbs rock"]}

    practice_llm.set_override(json=fake_json)
    return calls


def test_refresh_rebuilds_then_skips_when_source_hash_unchanged():
    db = _seeded_db()
    calls = _distill_ok()
    try:
        # First: missing → rebuild (one distill call).
        r1 = asyncio.run(persona_snapshot.refresh_persona_if_due(db, VIEWER))
        assert r1["status"] == "rebuilt"
        assert calls["n"] == 1
        data = _avatar_doc(db, VIEWER).get().to_dict()
        assert data["distilled"] is True and data["stale"] is False
        assert data["brief"] == "You are Sam, a climber."

        # Age the snapshot and mark it stale, but DO NOT change the source.
        _avatar_doc(db, VIEWER).set({"updated_at": 0.0, "stale": True}, merge=True)
        r2 = asyncio.run(persona_snapshot.refresh_persona_if_due(db, VIEWER))
        assert r2["status"] == "unchanged"
        assert calls["n"] == 1  # NO second LLM call — source_hash matched
        assert _avatar_doc(db, VIEWER).get().to_dict()["stale"] is False
    finally:
        practice_llm.clear_override()


def test_refresh_skipped_when_under_min_interval():
    db = _seeded_db()
    calls = _distill_ok()
    try:
        asyncio.run(persona_snapshot.refresh_persona_if_due(db, VIEWER))
        assert calls["n"] == 1
        # Mark stale but keep updated_at recent → rate limited, no rebuild.
        persona_snapshot.mark_persona_stale(db, VIEWER)
        r = asyncio.run(
            persona_snapshot.refresh_persona_if_due(
                db, VIEWER, min_interval=3600.0
            )
        )
        assert r["status"] == "rate_limited"
        assert calls["n"] == 1
    finally:
        practice_llm.clear_override()


def test_refresh_rebuilds_when_stale_source_changed_and_past_interval():
    db = _seeded_db()
    calls = _distill_ok()
    try:
        asyncio.run(persona_snapshot.refresh_persona_if_due(db, VIEWER))
        assert calls["n"] == 1
        hash_before = _avatar_doc(db, VIEWER).get().to_dict()["source_hash"]

        # Genuinely change the source, age the snapshot, mark stale.
        db.collection("users").document(VIEWER).collection("wiki_pages").document(
            "about"
        ).set({"ai_body": "Now also a potter and a runner."}, merge=True)
        _avatar_doc(db, VIEWER).set({"updated_at": 0.0, "stale": True}, merge=True)

        r = asyncio.run(persona_snapshot.refresh_persona_if_due(db, VIEWER))
        assert r["status"] == "rebuilt"
        assert calls["n"] == 2  # a real rebuild
        assert _avatar_doc(db, VIEWER).get().to_dict()["source_hash"] != hash_before
    finally:
        practice_llm.clear_override()


def test_fresh_snapshot_is_skipped_without_building_context():
    db = _seeded_db()
    calls = _distill_ok()
    try:
        asyncio.run(persona_snapshot.refresh_persona_if_due(db, VIEWER))
        # Not stale now → fresh, nothing to do.
        r = asyncio.run(persona_snapshot.refresh_persona_if_due(db, VIEWER))
        assert r["status"] == "fresh"
        assert calls["n"] == 1
    finally:
        practice_llm.clear_override()


# --- stale flips on a source write ----------------------------------------- #
def test_mark_stale_flips_the_flag():
    db = _seeded_db()
    asyncio.run(persona_snapshot.build_persona_snapshot(db, VIEWER, distill=False))
    _avatar_doc(db, VIEWER).set({"stale": False}, merge=True)
    persona_snapshot.mark_persona_stale(db, VIEWER)
    assert _avatar_doc(db, VIEWER).get().to_dict()["stale"] is True


def test_dm_send_marks_the_sender_stale():
    import dm_ops

    db = _seeded_db()
    asyncio.run(persona_snapshot.build_persona_snapshot(db, VIEWER, distill=False))
    _avatar_doc(db, VIEWER).set({"stale": False}, merge=True)
    dm_ops.post_message(db, VIEWER, MAYA, "text", "hey there")
    # The SENDER's avatar is flagged; it never raises and never touches updated_at.
    assert _avatar_doc(db, VIEWER).get().to_dict()["stale"] is True


# --- opted-out user gets no snapshot --------------------------------------- #
def _opt_out(db, uid):
    db.collection("users").document(uid).collection("profile").document(
        "main"
    ).set({"ai_avatar_enabled": False}, merge=True)


def test_opted_out_user_gets_no_snapshot_and_existing_is_deleted():
    db = _seeded_db()
    asyncio.run(persona_snapshot.build_persona_snapshot(db, VIEWER, distill=False))
    assert _avatar_doc(db, VIEWER).get().exists
    _opt_out(db, VIEWER)
    # A build for an opted-out user writes nothing and deletes the old snapshot.
    assert (
        asyncio.run(
            persona_snapshot.build_persona_snapshot(db, VIEWER, distill=False)
        )
        is None
    )
    assert not _avatar_doc(db, VIEWER).get().exists
    assert (
        asyncio.run(persona_snapshot.refresh_persona_if_due(db, VIEWER))["status"]
        == "opted_out"
    )


# --- defence-in-depth private-leak scrub ----------------------------------- #
def test_redact_private_leaks_scrubs_obvious_details():
    text = (
        "Reach me at sam@example.com or (415) 555-0199. I live at "
        f"{NEEDLE_ADDRESS}. SSN 123-45-6789."
    )
    clean, flagged = persona_snapshot.redact_private_leaks(text)
    assert "sam@example.com" not in clean
    assert "555-0199" not in clean
    assert NEEDLE_ADDRESS not in clean
    assert "123-45-6789" not in clean
    assert set(flagged) == {"email", "phone", "street_address", "ssn"}


def test_redact_leaves_clean_text_untouched():
    clean, flagged = persona_snapshot.redact_private_leaks("Loves climbing and jazz.")
    assert clean == "Loves climbing and jazz." and flagged == []


def test_distilled_brief_is_scrubbed_before_storage():
    db = _seeded_db()

    async def leaky_json(system, contents, schema, uid, feature):
        return {
            "brief": f"You are Sam. Home: {NEEDLE_ADDRESS}. Email sam@x.com.",
            "story_highlights": ["Reachable at (212) 555-0147"],
        }

    practice_llm.set_override(json=leaky_json)
    try:
        asyncio.run(persona_snapshot.build_persona_snapshot(db, VIEWER, distill=True))
    finally:
        practice_llm.clear_override()
    data = _avatar_doc(db, VIEWER).get().to_dict()
    assert NEEDLE_ADDRESS not in data["brief"]
    assert "sam@x.com" not in data["brief"]
    assert all("555-0147" not in h for h in data["story_highlights"])
    assert set(data["leak_flags"]) >= {"email", "street_address", "phone"}


# --- readiness score math + low-context boundary --------------------------- #
def test_readiness_score_weights_and_bounds():
    # Weights are locked 80/20; both sub-metrics 1.0 → 100; both 0 → 0.
    assert persona_snapshot.compute_readiness_score(1.0, 1.0) == 100
    assert persona_snapshot.compute_readiness_score(0.0, 0.0) == 0
    # Profile dominates (80%): full profile, zero conversation → 80.
    assert persona_snapshot.compute_readiness_score(1.0, 0.0) == 80
    # Conversation is 20%: zero profile, full conversation → 20.
    assert persona_snapshot.compute_readiness_score(0.0, 1.0) == 20
    # Rounding to nearest int.
    assert persona_snapshot.compute_readiness_score(0.5, 0.5) == 50
    assert persona_snapshot.compute_readiness_score(0.333, 0.333) == 33


def test_low_context_threshold_boundary():
    # Threshold is 20: 19 → low context, 20 → not.
    assert persona_snapshot.CONFIG.persona_readiness_low_context_threshold == 20
    assert persona_snapshot.is_low_context(19) is True
    assert persona_snapshot.is_low_context(20) is False
    # And via the real score: 0.2375 profile, 0 conv → 19 (low); 0.25 → 20 (not).
    assert persona_snapshot.compute_readiness_score(0.2375, 0.0) == 19
    assert persona_snapshot.is_low_context(
        persona_snapshot.compute_readiness_score(0.2375, 0.0)
    )
    assert persona_snapshot.compute_readiness_score(0.25, 0.0) == 20
    assert not persona_snapshot.is_low_context(
        persona_snapshot.compute_readiness_score(0.25, 0.0)
    )


def test_readiness_block_on_snapshot_doc():
    db = _seeded_db()
    asyncio.run(persona_snapshot.build_persona_snapshot(db, VIEWER, distill=False))
    data = _avatar_doc(db, VIEWER).get().to_dict()
    assert 0 <= data["readiness_score"] <= 100
    assert isinstance(data["low_context"], bool)
    assert 0.0 <= data["profile_completeness"] <= 1.0
    assert 0.0 <= data["conversation_volume"] <= 1.0


# --- preflight readiness (the sim setup screen) ---------------------------- #
def test_preflight_uses_match_snapshot_when_present():
    db = _seeded_db()
    asyncio.run(persona_snapshot.build_persona_snapshot(db, MAYA, distill=False))
    out = persona_snapshot.preflight_readiness(db, VIEWER, MAYA)
    assert out is not None
    assert out["name"] == "Maya"
    assert 0 <= out["readiness_score"] <= 100
    assert isinstance(out["low_context"], bool)


def test_preflight_public_fallback_when_no_snapshot():
    db = _seeded_db()
    out = persona_snapshot.preflight_readiness(db, VIEWER, MAYA)
    assert out is not None and out["name"] == "Maya"
    assert 0 <= out["readiness_score"] <= 100


def test_preflight_none_for_opted_out_match():
    db = _seeded_db()
    _opt_out(db, MAYA)
    assert persona_snapshot.preflight_readiness(db, VIEWER, MAYA) is None


def test_low_context_preflight_carries_warning_copy():
    db = _seeded_db()
    # A profile with almost nothing → low context, warning message present.
    db.collection("users").document("sparse").collection("profile").document(
        "main"
    ).set({"name": "Dillu"})
    out = persona_snapshot.preflight_readiness(db, VIEWER, "sparse")
    assert out is not None and out["low_context"] is True
    assert "Dillu" in out["message"]
    assert "accurate reflection" in out["message"]


def test_estimate_endpoint_includes_readiness(monkeypatch):
    db = _seeded_db()
    monkeypatch.setattr(date_sim, "get_db", lambda: db)
    caller = SimpleNamespace(uid=VIEWER)
    out = asyncio.run(date_sim.date_sim_estimate(other_uid=MAYA, caller=caller))
    assert "credits_by_messages" in out
    assert "readiness" in out
    assert "readiness_score" in out["readiness"]
    assert "low_context" in out["readiness"]


def test_estimate_endpoint_without_other_uid_has_no_readiness(monkeypatch):
    db = _seeded_db()
    monkeypatch.setattr(date_sim, "get_db", lambda: db)
    caller = SimpleNamespace(uid=VIEWER)
    out = asyncio.run(date_sim.date_sim_estimate(caller=caller))
    assert "readiness" not in out


# --- date-sim spawn routing: match snapshot vs public fallback ------------- #
def _fake_sim_personas():
    async def fake_text(system, message, uid, feature, session_id):
        return "hey, nice to meet you!"

    async def fake_json(system, contents, schema, uid, feature):
        # Could be the verdict OR a distill; both are tolerated downstream.
        return {"score": 70, "score_label": "ok", "summary": "s"}

    practice_llm.set_override(text=fake_text, json=fake_json)


def test_match_uses_their_snapshot_when_eligible(monkeypatch):
    db = _seeded_db()
    asyncio.run(persona_snapshot.build_persona_snapshot(db, MAYA, distill=False))
    public_calls = {"n": 0}
    orig = date_sim.build_persona_context

    def spy(dbx, viewer, target):
        if target == MAYA:
            public_calls["n"] += 1
        return orig(dbx, viewer, target)

    monkeypatch.setattr(date_sim, "build_persona_context", spy)
    _fake_sim_personas()
    try:
        asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 2))
    finally:
        practice_llm.clear_override()
    # The match's own snapshot was used — the public fallback was NOT called.
    assert public_calls["n"] == 0


def test_match_falls_back_to_public_when_no_snapshot(monkeypatch):
    db = _seeded_db()
    public_calls = {"n": 0}
    orig = date_sim.build_persona_context

    def spy(dbx, viewer, target):
        if target == MAYA:
            public_calls["n"] += 1
        return orig(dbx, viewer, target)

    monkeypatch.setattr(date_sim, "build_persona_context", spy)
    _fake_sim_personas()
    try:
        asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 2))
    finally:
        practice_llm.clear_override()
    assert public_calls["n"] == 1


def test_sweep_walks_users_and_reports(monkeypatch):
    db = _seeded_db()
    # The sweep lists top-level users/{uid} docs (as real Firestore does); every
    # real user has one from onboarding. Seed two so the walk has something.
    db.collection("users").document(VIEWER).set({"onboarding_started": True})
    db.collection("users").document(MAYA).set({"onboarding_started": True})
    calls = _distill_ok()
    try:
        out = asyncio.run(persona_snapshot.run_sweep(db, user_limit=50))
    finally:
        practice_llm.clear_override()
    assert out["checked"] >= 1
    assert sum(out["statuses"].values()) == out["checked"]
    # At least the seeded demo users / viewer got rebuilt.
    assert out["statuses"].get("rebuilt", 0) >= 1
