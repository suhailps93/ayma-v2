"""Practice Date (hackathon deliverable B): persona building, query-level
privacy exclusion, prompt composition, the session flow, and the provider seam.

The headline privacy extraction test is in ``test_practice_extraction.py``."""

from __future__ import annotations

import asyncio

import pytest

# Public-repo note: the tests target the fastapi-free domain core
# (`practice_core`) rather than the HTTP layer `practice_date.py`, which depends
# on Ayma's private FastAPI app, auth, age-gate and db wiring (not included).
# Every name used below is part of `practice_core`'s public surface, which
# `practice_date.py` re-exports unchanged in production.
import practice_core as practice_date
import practice_llm
import practice_seed
from fake_firestore import FakeDb

VIEWER = "viewer_uid"
MAYA = "demo_practice_maya"


def _seeded_db() -> FakeDb:
    db = FakeDb()
    practice_seed.seed(db)
    return db


# --- persona context: whitelists only viewer-visible fields ---------------- #
def test_persona_context_keeps_public_fields():
    ctx = practice_date.build_persona_context(_seeded_db(), VIEWER, MAYA)
    assert ctx is not None
    assert ctx.name == "Maya"
    assert ctx.age and ctx.age > 18
    assert ctx.location == "San Francisco"
    block = ctx.to_prompt_block().lower()
    assert "ceramicist" in block  # from the public wiki page
    assert "looking for" in block  # second public page title


def test_persona_context_excludes_private_and_contact_data():
    """Query-level exclusion: nothing from a NEVER_LOAD category is present."""
    ctx = practice_date.build_persona_context(_seeded_db(), VIEWER, MAYA)
    assert ctx is not None
    block = ctx.to_prompt_block()
    entry = next(e for e in practice_seed.DEMO_PROFILES if e["uid"] == MAYA)
    for secret in entry["secrets"]:
        assert secret not in block, f"{secret!r} leaked into persona context"


def test_persona_context_none_for_missing_self_and_deleted():
    db = _seeded_db()
    assert practice_date.build_persona_context(db, VIEWER, "nobody_here") is None
    # a user cannot practice against their own profile
    assert practice_date.build_persona_context(db, MAYA, MAYA) is None
    # a deleted target yields nothing to simulate
    db.collection("deleted_users").document(MAYA).set({"deleted": True})
    assert practice_date.build_persona_context(db, VIEWER, MAYA) is None


# --- prompt composition ----------------------------------------------------- #
def test_compose_persona_prompt_injects_persona_and_deflection():
    ctx = practice_date.build_persona_context(_seeded_db(), VIEWER, MAYA)
    prompt = practice_date.compose_persona_prompt(ctx)
    assert practice_date._PERSONA_TOKEN not in prompt  # token was replaced
    assert "Maya" in prompt
    lowered = prompt.lower()
    assert "simulation" in lowered  # clearly labelled as practice
    assert "deflect" in lowered  # the extraction defence is in the prompt
    assert "in character" in lowered


def test_compose_persona_prompt_appends_conversation():
    ctx = practice_date.build_persona_context(_seeded_db(), VIEWER, MAYA)
    turns = [
        {"role": practice_date.ROLE_USER, "text": "hey!"},
        {"role": practice_date.ROLE_MATCH, "text": "oh hi"},
    ]
    prompt = practice_date.compose_persona_prompt(ctx, turns)
    assert "Conversation so far" in prompt
    assert "hey!" in prompt and "oh hi" in prompt


# --- session flow (persona reply + coach + debrief, deterministic LLM) ------ #
def _install_fake_llm():
    async def fake_text(system, message, uid, feature, session_id):
        assert "Maya" in system  # the persona really is seeded in
        return f"haha, {message} — sounds good to me"

    async def fake_json(system, contents, schema, uid, feature):
        props = (schema or {}).get("properties", {})
        if "hint" in props:
            return {"hint": "warm opener, now ask about her ceramics"}
        return {
            "what_worked": ["you kept it light and curious"],
            "suggested_next_lines": ["Ask what she's throwing on the wheel lately"],
            "avoid": ["Don't push for her address — it reads as a red flag"],
        }

    practice_llm.set_override(text=fake_text, json=fake_json)


def test_session_flow_end_to_end():
    db = _seeded_db()
    _install_fake_llm()
    try:
        session_id = practice_date.start_session(db, VIEWER, MAYA)
        ctx = practice_date.build_persona_context(db, VIEWER, MAYA)

        reply = asyncio.run(
            practice_date.persona_reply(
                ctx, [], "hey, your pottery is gorgeous", uid=VIEWER, session_id=session_id
            )
        )
        assert "sounds good to me" in reply

        full = practice_date.append_turns(
            db,
            VIEWER,
            session_id,
            [
                {"role": practice_date.ROLE_USER, "text": "hey, your pottery is gorgeous"},
                {"role": practice_date.ROLE_MATCH, "text": reply},
            ],
        )
        assert len(full) == 2

        hint = asyncio.run(practice_date.coach_hint(ctx, full, uid=VIEWER))
        assert "ceramics" in hint

        debrief = asyncio.run(practice_date.generate_debrief(ctx, full, uid=VIEWER))
        assert debrief["what_worked"] and debrief["suggested_next_lines"]
        assert debrief["avoid"]

        practice_date.end_session(db, VIEWER, session_id)
        stored = (
            db.collection("users")
            .document(VIEWER)
            .collection(practice_date.PRACTICE_SESSIONS_COLLECTION)
            .document(session_id)
            .get()
            .to_dict()
        )
        assert stored["ended_at"] is not None
    finally:
        practice_llm.clear_override()


def test_start_session_rejects_unsimulatable_target():
    with pytest.raises(ValueError):
        practice_date.start_session(_seeded_db(), VIEWER, "nobody_here")


# --- voice practice: the name-only coach context the agent worker rebuilds --- #
def test_persona_context_for_coach_is_name_only_and_carries_no_secrets():
    """The voice agent worker rebuilds the coach context from the persona name
    alone (it must never re-read the target's profile). It holds no never-load
    field, and nothing from the demo secrets."""
    ctx = practice_date.persona_context_for_coach("Maya", target_uid=MAYA)
    assert ctx.name == "Maya"
    assert ctx.age is None and ctx.location == "" and ctx.pages == []
    assert ctx.photo_count == 0
    block = ctx.to_prompt_block()
    entry = next(e for e in practice_seed.DEMO_PROFILES if e["uid"] == MAYA)
    for secret in entry["secrets"]:
        assert secret not in block


def test_voice_coach_and_debrief_run_on_the_name_only_context():
    """The voice path drives the live coach + debrief from the name-only
    context plus the running transcript — same reused ``coach_hint`` /
    ``generate_debrief`` as the text path, no persona pages needed."""
    _install_fake_llm()
    try:
        ctx = practice_date.persona_context_for_coach("Maya")
        turns = [
            {"role": practice_date.ROLE_USER, "text": "hey, love your pottery"},
            {"role": practice_date.ROLE_MATCH, "text": "haha thanks!"},
        ]
        hint = asyncio.run(practice_date.coach_hint(ctx, turns, uid=VIEWER))
        assert "ceramics" in hint
        debrief = asyncio.run(practice_date.generate_debrief(ctx, turns, uid=VIEWER))
        assert debrief["what_worked"] and debrief["suggested_next_lines"]
    finally:
        practice_llm.clear_override()


def test_coach_hint_never_raises_on_llm_failure():
    ctx = practice_date.build_persona_context(_seeded_db(), VIEWER, MAYA)

    async def boom(system, contents, schema, uid, feature):
        raise RuntimeError("model down")

    practice_llm.set_override(json=boom)
    try:
        assert asyncio.run(practice_date.coach_hint(ctx, [], uid=VIEWER)) == ""
    finally:
        practice_llm.clear_override()


# --- provider seam (consumes the shared per-surface provider) --------------- #
def test_practice_surface_defaults_to_gemini():
    from llm_provider import GeminiProvider, get_llm_provider

    # LLM_PROVIDER_PRACTICE is unset in tests → Gemini (runs tonight; flips to
    # Meta Muse Spark when the flag is set).
    assert isinstance(get_llm_provider(practice_llm.SURFACE), GeminiProvider)


def test_generate_text_delegates_to_practice_provider(monkeypatch):
    practice_llm.clear_override()
    seen = {}

    class _FakeReply:
        text = "delegated reply"

    class _FakeProvider:
        async def generate_reply(self, message, **kwargs):
            seen["message"] = message
            seen["feature"] = kwargs.get("feature")
            return _FakeReply()

    monkeypatch.setattr(practice_llm, "get_llm_provider", lambda surface: _FakeProvider())
    out = asyncio.run(practice_llm.generate_text("sys", "hello", uid="u1"))
    assert out == "delegated reply"
    assert seen["message"] == "hello"
    assert seen["feature"] == practice_llm.token_ledger.FEATURE_PRACTICE
