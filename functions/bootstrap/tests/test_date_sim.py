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


# --- self-persona texting-style exemplars (own sent DMs only) -------------- #
OTHER = "other_participant_uid"
OWN_MESSAGE = "lol fair enough, same tbh"
OTHER_MESSAGE = "OTHER_USER_SECRET_LINE_do_not_ingest"


def _seed_dm_messages(db, *, own: int = 3):
    """Seed one dm_thread between VIEWER and OTHER with ``own`` messages the
    VIEWER sent plus messages OTHER sent. Message shape matches ``dm_ops``:
    ``sender_uid`` / ``type`` / ``body`` / ``created_at``."""
    thread = db.collection("dm_threads").document("viewer_other")
    thread.set({"participants": [VIEWER, OTHER]})
    msgs = thread.collection("messages")
    ts = 0
    for i in range(own):
        ts += 1
        msgs.document(f"own{i}").set(
            {
                "sender_uid": VIEWER,
                "type": "text",
                "body": f"{OWN_MESSAGE} ({i})",
                "created_at": ts,
            }
        )
    # Messages the OTHER user sent — must NEVER enter the self persona.
    for i in range(3):
        ts += 1
        msgs.document(f"other{i}").set(
            {
                "sender_uid": OTHER,
                "type": "text",
                "body": f"{OTHER_MESSAGE} {i}",
                "created_at": ts,
            }
        )
    return thread


def test_self_persona_includes_own_sent_messages_excludes_the_other_party():
    db = _seeded_db()
    _seed_dm_messages(db, own=3)
    ctx = practice_core.build_self_persona_context(db, VIEWER)
    assert ctx is not None

    # The user's OWN sent messages are present as style exemplars...
    assert ctx.style_exemplars
    assert any(OWN_MESSAGE in ex for ex in ctx.style_exemplars)
    block = ctx.to_prompt_block()
    assert OWN_MESSAGE in block
    assert "how this user texts" in block.lower()

    # ...and the OTHER participant's messages are NEVER ingested (privacy).
    assert all(OTHER_MESSAGE not in ex for ex in ctx.style_exemplars)
    assert OTHER_MESSAGE not in block


def test_self_persona_style_exemplars_respect_the_caps():
    db = _seeded_db()
    # Many own messages, each unique and short.
    thread = db.collection("dm_threads").document("viewer_other")
    thread.set({"participants": [VIEWER, OTHER]})
    msgs = thread.collection("messages")
    n = practice_core._SELF_STYLE_MAX_MESSAGES + 25
    for i in range(n):
        msgs.document(f"own{i}").set(
            {
                "sender_uid": VIEWER,
                "type": "text",
                "body": f"message number {i} here",
                "created_at": i,
            }
        )
    # One over-long message that must be skipped (exceeds the per-message cap).
    msgs.document("toolong").set(
        {
            "sender_uid": VIEWER,
            "type": "text",
            "body": "x" * (practice_core._SELF_STYLE_MAX_MSG_CHARS + 50),
            "created_at": n + 1,
        }
    )
    ctx = practice_core.build_self_persona_context(db, VIEWER)
    assert ctx is not None
    assert len(ctx.style_exemplars) <= practice_core._SELF_STYLE_MAX_MESSAGES
    assert sum(len(e) for e in ctx.style_exemplars) <= (
        practice_core._SELF_STYLE_MAX_TOTAL_CHARS
    )
    assert all(len(e) <= practice_core._SELF_STYLE_MAX_MSG_CHARS for e in ctx.style_exemplars)


def test_match_persona_never_carries_dm_style_exemplars():
    """The MATCH path is untouched: no DM content, exemplars always empty."""
    db = _seeded_db()
    _seed_dm_messages(db, own=3)
    match_ctx = practice_core.build_persona_context(db, VIEWER, MAYA)
    assert match_ctx is not None
    assert match_ctx.style_exemplars == []
    assert OWN_MESSAGE not in match_ctx.to_prompt_block()


def test_self_persona_style_survives_missing_dm_threads():
    """No DM threads → simply no exemplars, never an error."""
    db = _seeded_db()
    ctx = practice_core.build_self_persona_context(db, VIEWER)
    assert ctx is not None
    assert ctx.style_exemplars == []


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


# --- live streaming to Firestore ------------------------------------------- #
def _sim_docs(db, sim_id):
    ref = db.collection("users").document(VIEWER).collection("date_sims").document(sim_id)
    msgs = sorted(
        (s.to_dict() for s in ref.collection("messages").stream()),
        key=lambda m: m["seq"],
    )
    return ref.get().to_dict(), msgs


def test_each_turn_is_written_the_moment_it_is_produced():
    db = _seeded_db()
    seen: list[int] = []

    async def fake_text(system, message, uid, feature, session_id):
        # Before generating turn N, exactly N messages must already be stored.
        _, msgs = _sim_docs(db, "sim_stream_1")
        seen.append(len(msgs))
        return "a friendly line"

    async def fake_json(system, contents, schema, uid, feature):
        return {"score": 61, "score_label": "ok", "summary": "fine"}

    practice_llm.set_override(text=fake_text, json=fake_json)
    try:
        asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 4, "sim_stream_1"))
    finally:
        practice_llm.clear_override()
    assert seen == [0, 1, 2, 3]
    parent, msgs = _sim_docs(db, "sim_stream_1")
    assert parent["status"] == "done"
    assert parent["verdict"]["score"] == 61
    assert parent["estimate"] == date_sim.estimate_credits(4)
    assert [m["speaker"] for m in msgs] == ["you", "them", "you", "them"]


def test_failure_marks_error_and_keeps_partial_transcript():
    db = _seeded_db()
    calls = {"n": 0}

    async def flaky(system, message, uid, feature, session_id):
        calls["n"] += 1
        if calls["n"] == 3:
            raise RuntimeError("boom")
        return "a friendly line"

    practice_llm.set_override(text=flaky)
    try:
        with pytest.raises(RuntimeError):
            asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 6, "sim_err_001"))
    finally:
        practice_llm.clear_override()
    parent, msgs = _sim_docs(db, "sim_err_001")
    assert parent["status"] == "error"
    assert parent["error"]["code"] == "failed"
    assert len(msgs) == 2


def test_a_hung_turn_times_out_instead_of_hanging(monkeypatch):
    db = _seeded_db()
    monkeypatch.setattr(date_sim, "TURN_TIMEOUT_S", 0.05)

    async def hang(system, message, uid, feature, session_id):
        await asyncio.sleep(5)
        return "never"

    practice_llm.set_override(text=hang)
    try:
        with pytest.raises(asyncio.TimeoutError):
            asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 4, "sim_hang_01"))
    finally:
        practice_llm.clear_override()
    parent, _ = _sim_docs(db, "sim_hang_01")
    assert parent["status"] == "error" and parent["error"]["code"] == "timeout"


def test_opt_out_writes_no_sim_doc():
    db = _seeded_db()
    _opt_out(db, MAYA)
    _run_blocked(db)
    assert not db.collection("users").document(VIEWER).collection(
        "date_sims"
    ).document("any").get().exists


def test_sim_id_is_validated_against_path_tricks():
    assert not date_sim._SIM_ID_RE.match("../other")
    assert not date_sim._SIM_ID_RE.match("a/b/c/d/e/f/g/h")
    assert date_sim._SIM_ID_RE.match("abcDEF12_-34")


# --- anti-fabrication grounding (readiness-conditioned) -------------------- #
def test_date_sim_prompt_forbids_fabricating_unknown_facts():
    """The shared prompt carries the anti-fabrication rule (distinct from the
    disclosure filter): never invent a job/employer/location/history."""
    prompt = date_sim._read(date_sim._SIM_PROMPT_PATH).lower()
    assert "never" in prompt and "invent" in prompt
    assert "job" in prompt and "employer" in prompt
    # The readiness-conditioned fragment is injected here.
    assert date_sim._CONTEXT_DEPTH_TOKEN in date_sim._read(date_sim._SIM_PROMPT_PATH)


def _thin_ctx() -> practice_core.PersonaContext:
    # Only a name → very low profile completeness → low-context.
    return practice_core.PersonaContext(
        target_uid="thin", name="Alex", age=None, location=""
    )


def _rich_ctx() -> practice_core.PersonaContext:
    return practice_core.PersonaContext(
        target_uid="rich",
        name="Jordan",
        age=29,
        location="Austin",
        gender="woman",
        photo_count=3,
        pages=[{"title": f"Page {i}", "body": f"body {i}"} for i in range(5)],
    )


def test_thin_profile_persona_is_more_conservative_than_a_rich_one():
    """A thin profile (low readiness) gets the conservative "stay vague, never
    invent" fragment; a rich one gets the normal fragment — so a sparse persona
    cannot fabricate specifics to fill the gaps."""
    thin = _thin_ctx()
    assert date_sim.persona_snapshot.readiness_for_context(thin)["low_context"]
    thin_system, _ = date_sim.compose_sim_prompt(thin, "Alex", "Sam", [], date_sim.ROLE_YOU)
    assert "context here is thin" in thin_system.lower()

    rich = _rich_ctx()
    assert not date_sim.persona_snapshot.readiness_for_context(rich)["low_context"]
    rich_system, _ = date_sim.compose_sim_prompt(rich, "Jordan", "Sam", [], date_sim.ROLE_YOU)
    assert "context here is thin" not in rich_system.lower()
    assert "lean on the real interests" in rich_system.lower()


# --- continue: append more turns, CONTINUING (never a restart) ------------- #
def test_continue_appends_more_turns_and_rescores():
    db = _seeded_db()
    _fake_personas()
    try:
        asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 6, "sim_cont_1"))
        before, before_msgs = _sim_docs(db, "sim_cont_1")
        assert len(before_msgs) == 6
        first_six = [m["text"] for m in before_msgs]

        out = asyncio.run(
            date_sim.continue_simulation(db, VIEWER, "sim_cont_1", 4)
        )
    finally:
        practice_llm.clear_override()

    # CONTINUED, not restarted: the original 6 are untouched and the new turns
    # are appended at the next absolute seqs, preserving the alternation.
    after, after_msgs = _sim_docs(db, "sim_cont_1")
    assert len(after_msgs) == 10
    assert [m["text"] for m in after_msgs[:6]] == first_six
    assert [m["seq"] for m in after_msgs] == list(range(10))
    assert [m["speaker"] for m in after_msgs] == [
        "you", "them", "you", "them", "you", "them", "you", "them", "you", "them"
    ]
    assert len(out["transcript"]) == 10
    assert after["status"] == "done"
    assert after["verdict"]["score_label"]  # re-scored over the full transcript


def test_continue_missing_sim_raises_value_error():
    db = _seeded_db()
    _fake_personas()
    try:
        with pytest.raises(ValueError):
            asyncio.run(date_sim.continue_simulation(db, VIEWER, "nope_nope", 4))
    finally:
        practice_llm.clear_override()


def test_continue_blocked_when_a_party_opts_out():
    db = _seeded_db()
    _fake_personas()
    try:
        asyncio.run(date_sim.run_simulation(db, VIEWER, MAYA, 4, "sim_cont_2"))
    finally:
        practice_llm.clear_override()
    _opt_out(db, MAYA)
    _fake_personas()
    try:
        with pytest.raises(date_sim.AvatarOptOut) as exc:
            asyncio.run(date_sim.continue_simulation(db, VIEWER, "sim_cont_2", 4))
    finally:
        practice_llm.clear_override()
    assert exc.value.who == "match"
