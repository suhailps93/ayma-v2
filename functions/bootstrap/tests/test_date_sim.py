"""AI Date Simulation (hackathon flagship): the two-persona engine.

Proves the headline guarantees deterministically (offline fake LLM):
* a bounded transcript + a 0–100 score and summary come back;
* ``max_messages`` is respected exactly;
* the MATCH persona is grounded ONLY in public data, the USER persona in their
  FULL own context;
* the disclosure filter design holds — a private needle seeded into the user's
  FULL context is present in their grounding but never emitted in the transcript,
  and the prompt that governs both personas carries the filter;
* out-of-credits is handled before the first message AND mid-conversation.
"""

from __future__ import annotations

import asyncio

import pytest

import date_sim
import practice_core
import practice_llm
import practice_seed
import token_ledger
from fake_firestore import FakeDb

VIEWER = "viewer_uid"
MAYA = "demo_practice_maya"

# A private needle seeded into the VIEWER's OWN full context (address + health),
# the kind of thing the disclosure filter must keep out of the chat.
NEEDLE_ADDRESS = "999 Needle Lane"
NEEDLE_HEALTH = "a serious heart condition"


def _seeded_db() -> FakeDb:
    db = FakeDb()
    practice_seed.seed(db)
    # The viewer's own full profile + wiki, including a PRIVATE page and an
    # AI-notes page carrying the needles (their own data → full grounding).
    user = db.collection("users").document(VIEWER)
    user.collection("profile").document("main").set(
        {
            "name": "Sam",
            "gender": "man",
            "birthdate": "1992-04-10",
            "location": "San Francisco",
            "photos": [],
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
            "ai_body": (
                f"Home address is {NEEDLE_ADDRESS}. Living with "
                f"{NEEDLE_HEALTH} I don't talk about."
            ),
        }
    )
    return db


def _fake_personas(*, leaky: bool = False):
    """Install deterministic persona + verdict stand-ins.

    The persona fake behaves like a model that FOLLOWS the disclosure filter:
    it never echoes the grounding, just sends a natural first-chat line. With
    ``leaky=True`` it instead parrots its whole grounding (worst case) — used to
    prove the needle really is in the user's context so the clean run's absence
    is meaningful, not vacuous."""

    async def fake_text(system, message, uid, feature, session_id):
        assert feature == token_ledger.FEATURE_DATE_SIM
        if leaky:
            return system  # dump the full grounding into the chat
        if "Start the conversation" in message:
            return "hey! your profile made me smile — how's your week going?"
        return "ha, same here honestly. what do you do for fun?"

    async def fake_json(system, contents, schema, uid, feature):
        assert feature == token_ledger.FEATURE_DATE_SIM
        return {
            "score": 78,
            "score_label": "Worth a shot",
            "summary": "You two kept it light and curious — a promising start. "
            "If you message for real, lead with the climbing.",
        }

    practice_llm.set_override(text=fake_text, json=fake_json)


# --- grounding asymmetry (the privacy boundary) ---------------------------- #
def test_user_persona_is_full_context_match_persona_is_public_only():
    db = _seeded_db()
    self_ctx = practice_core.build_self_persona_context(db, VIEWER)
    match_ctx = practice_core.build_persona_context(db, VIEWER, MAYA)
    assert self_ctx is not None and match_ctx is not None

    # The user's OWN agent is grounded in their full context — the private
    # needle is present (it's their own data).
    self_block = self_ctx.to_prompt_block()
    assert NEEDLE_ADDRESS in self_block
    assert NEEDLE_HEALTH in self_block

    # The MATCH's agent is public-only: none of the match's private needles
    # (address/phone/email/coords/other people) reach its context.
    match_block = match_ctx.to_prompt_block()
    entry = next(e for e in practice_seed.DEMO_PROFILES if e["uid"] == MAYA)
    for secret in entry["secrets"]:
        assert secret not in match_block, f"{secret!r} leaked into match persona"


def test_self_context_none_without_a_profile():
    assert practice_core.build_self_persona_context(FakeDb(), "ghost") is None


# --- the prompt carries the disclosure filter ------------------------------ #
def test_date_sim_prompt_has_disclosure_filter_for_both_personas():
    prompt = date_sim._read(date_sim._SIM_PROMPT_PATH).lower()
    assert "disclosure filter" in prompt
    assert "home address" in prompt
    assert "health" in prompt or "medical" in prompt
    assert "contact detail" in prompt or "phone number" in prompt
    assert "never" in prompt


# --- billing: both personas + verdict bill the triggering user ------------- #
def test_every_metered_call_bills_the_triggering_user():
    db = _seeded_db()
    billed: list[tuple[str, str]] = []

    async def fake_text(system, message, uid, feature, session_id):
        billed.append(("text", uid))
        return "a friendly line"

    async def fake_json(system, contents, schema, uid, feature):
        billed.append(("json", uid))
        return {"score": 50, "score_label": "ok", "summary": "fine"}

    practice_llm.set_override(text=fake_text, json=fake_json)
    try:
        asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 4))
    finally:
        practice_llm.clear_override()
    # 4 persona turns (2 USER + 2 MATCH) + 1 verdict, all on the viewer's uid.
    assert [kind for kind, _ in billed] == ["text"] * 4 + ["json"]
    assert {uid for _, uid in billed} == {VIEWER}


# --- AI Avatar opt-out ----------------------------------------------------- #
def _opt_out(db, uid):
    db.collection("users").document(uid).collection("profile").document(
        "main"
    ).set({"ai_avatar_enabled": False}, merge=True)


def _run_blocked(db) -> tuple[str, list]:
    calls: list = []

    async def fake_text(system, message, uid, feature, session_id):
        calls.append(uid)
        return "hi"

    async def fake_json(system, contents, schema, uid, feature):
        calls.append(uid)
        return {}

    practice_llm.set_override(text=fake_text, json=fake_json)
    try:
        with pytest.raises(date_sim.AvatarOptOut) as exc:
            asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 4))
    finally:
        practice_llm.clear_override()
    return exc.value.who, calls


def test_opted_out_match_blocks_the_sim_and_builds_no_persona():
    db = _seeded_db()
    _opt_out(db, MAYA)
    who, calls = _run_blocked(db)
    assert who == "match" and calls == []
    assert practice_core.build_persona_context(db, VIEWER, MAYA) is None


def test_opted_out_caller_cannot_run_the_sim():
    db = _seeded_db()
    _opt_out(db, VIEWER)
    who, calls = _run_blocked(db)
    assert who == "self" and calls == []


def test_ai_avatar_defaults_on_when_unset():
    assert practice_core.ai_avatar_enabled(FakeDb(), "anyone") is True


# --- cost estimate --------------------------------------------------------- #
def test_estimate_grows_with_message_count():
    assert date_sim.estimate_credits(2) >= 1
    assert date_sim.estimate_credits(20) > date_sim.estimate_credits(2)


# --- the engine: bounded transcript + score + summary ---------------------- #
def test_sim_returns_bounded_transcript_and_verdict():
    db = _seeded_db()
    _fake_personas()
    try:
        out = asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 6))
    finally:
        practice_llm.clear_override()
    assert out["simulation"] is True
    assert out["persona"]["name"] == "Maya"
    assert len(out["transcript"]) == 6
    # Alternates, user opens.
    assert [t["from"] for t in out["transcript"]] == [
        "you", "them", "you", "them", "you", "them"
    ]
    assert 0 <= out["score"] <= 100
    assert out["score_label"] and out["summary"]
    assert out["usage_capped"] is False


@pytest.mark.parametrize("cap", [2, 3, 8])
def test_sim_respects_max_messages(cap):
    db = _seeded_db()
    _fake_personas()
    try:
        out = asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, cap))
    finally:
        practice_llm.clear_override()
    assert len(out["transcript"]) == cap


def test_cap_is_clamped_to_bounds():
    db = _seeded_db()
    _fake_personas()
    try:
        out = asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 999))
    finally:
        practice_llm.clear_override()
    assert len(out["transcript"]) == date_sim.MAX_MESSAGES


# --- disclosure filter: the needle never reaches the transcript ------------ #
def test_private_needle_is_grounded_but_never_emitted():
    db = _seeded_db()
    # Sanity: with a leaky model the needle WOULD surface (the context really
    # does contain it), so the compliant run's absence below is meaningful.
    _fake_personas(leaky=True)
    try:
        leaked = asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 2))
    finally:
        practice_llm.clear_override()
    leaked_text = "\n".join(t["text"] for t in leaked["transcript"])
    assert NEEDLE_ADDRESS in leaked_text  # proves the needle is in-context

    # A filter-following model never emits the needle into the chat.
    _fake_personas()
    try:
        clean = asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 6))
    finally:
        practice_llm.clear_override()
    clean_text = "\n".join(t["text"] for t in clean["transcript"])
    assert NEEDLE_ADDRESS not in clean_text
    assert NEEDLE_HEALTH not in clean_text


# --- out of credits -------------------------------------------------------- #
def test_out_of_credits_before_first_message_raises():
    db = _seeded_db()

    async def broke(system, message, uid, feature, session_id):
        raise token_ledger.TokenCapExceeded("empty")

    practice_llm.set_override(text=broke)
    try:
        with pytest.raises(token_ledger.TokenCapExceeded):
            asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 6))
    finally:
        practice_llm.clear_override()


def test_out_of_credits_midway_returns_partial_transcript():
    db = _seeded_db()
    calls = {"n": 0}

    async def flaky(system, message, uid, feature, session_id):
        calls["n"] += 1
        if calls["n"] > 2:
            raise token_ledger.TokenCapExceeded("mid")
        return "a friendly line"

    async def fake_json(system, contents, schema, uid, feature):
        return {"score": 50, "score_label": "ok", "summary": "s"}

    practice_llm.set_override(text=flaky, json=fake_json)
    try:
        out = asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 6))
    finally:
        practice_llm.clear_override()
    assert len(out["transcript"]) == 2
    assert out["usage_capped"] is True
    # No verdict call is made once capped — the score stays at its default.
    assert out["score"] == 0


def test_date_sim_has_a_credit_label():
    assert token_ledger.FEATURE_DATE_SIM in token_ledger.FEATURE_LABELS
