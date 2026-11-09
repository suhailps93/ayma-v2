"""Practice Date (hackathon deliverable B): persona building, query-level
privacy exclusion, prompt composition, the session flow, and the provider seam.

The headline privacy extraction test is in ``test_practice_extraction.py``."""

from __future__ import annotations

import asyncio
import json

import pytest

import llm_provider
import practice_core
import practice_date
import practice_llm
import practice_seed
from fake_firestore import FakeDb

VIEWER = "viewer_uid"
MAYA = "demo_practice_maya"
LEO = "demo_practice_leo"


def _seeded_db() -> FakeDb:
    db = FakeDb()
    practice_seed.seed(db)
    return db


# --- evaluation prompts: honest critique, no generalized praise ---------- #
# Bug fZO89mEdQhjuiELzrC6p: when the user said something inappropriate or
# explicit in practice, the debrief/coach must call it out directly
# instead of wrapping the evaluation in generalized praise.

def test_debrief_prompt_demands_direct_critique_of_inappropriate_messages():
    prompt = practice_core.compose_debrief_prompt().lower()
    assert "inappropriate or explicit" in prompt
    assert "inventing praise" in prompt
    assert "empty list" in prompt  # what_worked may be empty, never invented
    assert "first" in prompt and "avoid" in prompt


def test_coach_prompt_demands_direct_nudge_for_inappropriate_messages():
    prompt = practice_core.compose_coach_prompt().lower()
    assert "inappropriate or explicit" in prompt
    assert "crossed a line" in prompt


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


def test_persona_context_photo_url_is_null_for_photoless_demo_and_not_in_prompt():
    """FIX 4: ``photo_url`` is the primary public photo URL (or ``None``). The
    seeded demo profiles carry no photos, so it is ``None``; and it is never
    injected into the persona prompt block (it's avatar UI data, not knowledge)."""
    ctx = practice_date.build_persona_context(_seeded_db(), VIEWER, MAYA)
    assert ctx is not None
    assert ctx.photo_count == 0
    assert ctx.photo_url is None
    assert "photo_url" not in ctx.to_prompt_block()


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


def test_coach_transcript_labels_user_as_coachee_and_match_by_name():
    """The coach/debrief transcript labels the real USER as ``User:`` and the
    simulated match by name — so the coach critiques the user, not the persona
    (the bug this fixes had them reversed, labelling the match as "You")."""
    turns = [
        {"role": practice_date.ROLE_USER, "text": "hey, your pottery is gorgeous"},
        {"role": practice_date.ROLE_MATCH, "text": "aw thanks!"},
    ]
    convo = practice_core._format_transcript(turns, "Maya")
    assert "User: hey, your pottery is gorgeous" in convo
    assert "Maya: aw thanks!" in convo
    assert "You:" not in convo and "Them:" not in convo


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


# --- gender-matched voice + pronouns + voice-call framing ------------------- #
def test_persona_context_carries_gender_and_shows_in_prompt():
    """The persona's (viewer-visible) gender rides on the context and appears in
    the prompt block so the match stays consistent about who they are and the
    worker can pick a gender-matched voice."""
    ctx = practice_date.build_persona_context(_seeded_db(), VIEWER, MAYA)
    assert ctx is not None
    assert ctx.gender == "woman"
    assert "Gender: woman" in ctx.to_prompt_block()


def test_voice_for_gender_picks_a_gender_matched_preset():
    import voices

    female = voices.voice_for_gender("woman")
    male = voices.voice_for_gender("man")
    # Each maps to a real catalog preset, and to the matching lean.
    assert female in voices.VOICE_PRESETS and "feminine" in voices.VOICE_PRESETS[female]
    assert male in voices.VOICE_PRESETS and "masculine" in voices.VOICE_PRESETS[male]
    assert female != male
    # Aliases resolve the same way; unknown/non-binary/blank → "" (caller uses
    # its own default voice — never a wrong-gender guess).
    assert voices.voice_for_gender("female") == female
    assert voices.voice_for_gender("Male") == male
    assert voices.voice_for_gender("non-binary") == ""
    assert voices.voice_for_gender("") == ""
    assert voices.voice_for_gender(None) == ""


def test_pronouns_for_gender_never_defaults_to_him():
    assert practice_core.pronouns_for_gender("woman") == "she/her"
    assert practice_core.pronouns_for_gender("man") == "he/him"
    # The founder bug: unknown/non-binary must be they/them, NOT he/him.
    assert practice_core.pronouns_for_gender("non-binary") == "they/them"
    assert practice_core.pronouns_for_gender("") == "they/them"
    assert practice_core.pronouns_for_gender(None) == "they/them"


def test_voice_persona_prompt_is_a_phone_call_knows_caller_and_is_not_texting():
    """The voice persona prompt frames a LIVE phone call from the named caller,
    tells the match it already knows who's calling (never ask the name), and
    bans texting phrasing. The text path (voice=False) carries none of it."""
    ctx = practice_date.build_persona_context(_seeded_db(), VIEWER, MAYA)
    voice_prompt = practice_date.compose_persona_prompt(
        ctx, voice=True, user_name="Sam"
    )
    lowered = voice_prompt.lower()
    assert "voice call" in lowered or "phone call" in lowered
    assert "Sam" in voice_prompt  # the caller's first name is injected
    assert "never ask who it is" in lowered or "never ask" in lowered
    assert "do not use texting" in lowered or "not a text chat" in lowered
    assert "no emoji" in lowered
    # The text path is unchanged — no voice-call framing leaks into it.
    text_prompt = practice_date.compose_persona_prompt(ctx)
    assert "phone call" not in text_prompt.lower()
    assert "Sam" not in text_prompt


def test_voice_persona_prompt_falls_back_when_user_name_missing():
    ctx = practice_date.build_persona_context(_seeded_db(), VIEWER, MAYA)
    prompt = practice_date.compose_persona_prompt(ctx, voice=True, user_name="")
    # No raw token leaks, and a sensible stand-in is used instead of a blank.
    assert "{{USER_NAME}}" not in prompt
    assert "the person you matched with" in prompt.lower()


def test_coach_context_uses_personas_pronouns_not_him():
    """The coach hint is composed with the persona's pronouns, so a she/her
    persona is never framed as "him" (founder bug 2026-10-27)."""
    seen = {}

    async def capture(system, contents, schema, uid, feature):
        seen["system"] = system
        seen["contents"] = contents
        return {"hint": "nice, keep it light"}

    ctx = practice_core.persona_context_for_coach("Dillu", target_uid=MAYA, gender="woman")
    turns = [{"role": practice_core.ROLE_USER, "text": "hey!"}]
    practice_llm.set_override(json=capture)
    try:
        asyncio.run(practice_date.coach_hint(ctx, turns, uid=VIEWER))
    finally:
        practice_llm.clear_override()
    assert "she/her" in seen["contents"]
    # The wrong-gender framing the bug produced must not be present.
    assert "him" not in seen["contents"].lower()
    assert "he/him" not in seen["contents"]
    # The coach PROMPT itself instructs pronoun-faithfulness.
    assert "pronouns" in practice_date.compose_coach_prompt().lower()


def test_coach_context_defaults_to_they_them_when_gender_unknown():
    seen = {}

    async def capture(system, contents, schema, uid, feature):
        seen["contents"] = contents
        return {"hint": ""}

    ctx = practice_core.persona_context_for_coach("Alex", target_uid=MAYA, gender="")
    practice_llm.set_override(json=capture)
    try:
        asyncio.run(
            practice_date.coach_hint(
                ctx, [{"role": practice_core.ROLE_USER, "text": "hi"}], uid=VIEWER
            )
        )
    finally:
        practice_llm.clear_override()
    assert "they/them" in seen["contents"]


# --- provider seam (consumes the shared per-surface provider) --------------- #
def test_practice_surface_defaults_to_gemini():
    from llm_provider import GeminiProvider, get_llm_provider

    # LLM_PROVIDER_PRACTICE is unset in tests → Gemini (runs tonight; flips to
    # Meta Muse Spark when the flag is set).
    assert isinstance(get_llm_provider(practice_llm.SURFACE), GeminiProvider)


def test_spark_debrief_payload_with_whitespace_keys_builds_complete_report(monkeypatch):
    """The Practice Date debrief uses the Meta JSON route without dropping
    fields when Muse Spark emits its known trailing-space key variant."""
    payload = {
        "what_worked ": ["You asked about Maya's ceramics."],
        "suggested_next_lines ": ["Which piece are you proudest of?"],
        "avoid ": ["Do not press for private details."],
    }

    class _Message:
        content = json.dumps(payload)

    class _Response:
        choices = [type("Choice", (), {"message": _Message()})()]
        usage = None

    class _Completions:
        async def create(self, **_kwargs):
            return _Response()

    class _Client:
        chat = type("Chat", (), {"completions": _Completions()})()

    monkeypatch.setattr(
        practice_llm,
        "get_llm_provider",
        lambda surface: llm_provider.MetaProvider(client=_Client()),
    )
    monkeypatch.setattr(practice_llm.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(practice_llm.token_ledger, "record", lambda *args, **kwargs: None)

    ctx = practice_core.persona_context_for_coach("Maya", target_uid=MAYA, gender="woman")
    report = asyncio.run(
        practice_date.generate_debrief(
            ctx,
            [{"role": practice_core.ROLE_USER, "text": "Your ceramics are beautiful."}],
            uid=VIEWER,
        )
    )

    assert report == {
        "what_worked": ["You asked about Maya's ceramics."],
        "suggested_next_lines": ["Which piece are you proudest of?"],
        "avoid": ["Do not press for private details."],
    }


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


# --- voice-start session resume (bug 44RwY05T4hgzkP4HtAU8) ----------------- #
# Every practice voice start used to mint a brand-new session, and the
# client re-runs the voice start on its automatic retries — so the
# debrief bound to the newest EMPTY session while the session holding
# the voice transcript was orphaned, and the "voice session feedback"
# came out about the text session instead.


def test_voice_resume_reuses_open_session_and_keeps_turns():
    db = _seeded_db()
    first = practice_core.start_or_resume_session(
        db, VIEWER, MAYA, modality="voice"
    )
    practice_core.append_turns(
        db,
        VIEWER,
        first,
        [
            {"role": practice_core.ROLE_USER, "text": "hi, ready when you are"},
            {"role": practice_core.ROLE_MATCH, "text": "hey! glad we are doing this"},
        ],
    )
    # The client's automatic retry re-runs the voice start, same target.
    second = practice_core.start_or_resume_session(
        db, VIEWER, MAYA, modality="voice"
    )
    assert second == first
    turns = practice_core._load_session(db, VIEWER, second)["turns"]
    assert [t["text"] for t in turns] == [
        "hi, ready when you are",
        "hey! glad we are doing this",
    ]
    # The debrief renders exactly this turns list — the voice lines are
    # what the feedback is generated from.
    convo = practice_core._format_transcript(turns, "Maya")
    assert "hi, ready when you are" in convo
    assert "glad we are doing this" in convo


def test_voice_resume_ignores_ended_session():
    db = _seeded_db()
    first = practice_core.start_or_resume_session(
        db, VIEWER, MAYA, modality="voice"
    )
    practice_core.end_session(db, VIEWER, first)
    second = practice_core.start_or_resume_session(
        db, VIEWER, MAYA, modality="voice"
    )
    assert second != first


def test_voice_resume_ignores_text_session():
    db = _seeded_db()
    text_sid = practice_date.start_session(db, VIEWER, MAYA)
    voice_sid = practice_core.start_or_resume_session(
        db, VIEWER, MAYA, modality="voice"
    )
    assert voice_sid != text_sid


def test_voice_resume_ignores_other_target():
    db = _seeded_db()
    first = practice_core.start_or_resume_session(
        db, VIEWER, MAYA, modality="voice"
    )
    other = practice_core.start_or_resume_session(
        db, VIEWER, LEO, modality="voice"
    )
    assert other != first


def test_voice_resume_ignores_stale_session():
    import time as _time

    db = _seeded_db()
    first = practice_core.start_or_resume_session(
        db, VIEWER, MAYA, modality="voice"
    )
    second = practice_core.start_or_resume_session(
        db, VIEWER, MAYA, modality="voice", now=_time.time() + 3600.0
    )
    assert second != first
