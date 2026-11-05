"""Context parity between the voice seed and text chat (founder report,
2026-10-25: "after today's changes Ayma may have LOST context and re-asks
questions already answered").

The voice path (``POST /bootstrap`` -> room metadata) and the text path
(``POST /chat``) build their system prompt through the *same* shared helpers
(``compose_system_prompt`` + ``_interview_progress`` / ``_preferences_context``
/ ``_questionnaire_note``). Both LiveKit voice providers — Google and LiveKit
Inference — consume that one seeded ``system_prompt`` verbatim from the room
metadata (``agent._read_room_seed``), so a field that reaches the voice seed
reaches both providers.

These tests lock that parity: every profile / answered field the founder
listed must appear in the built prompt on BOTH the voice seed and the chat
turn, and an answered questionnaire topic must not be offered again.
"""

import json

import gemini
import main
import prompt as prompt_mod
import session_mode
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import livekit_token
import dataclasses
from config import CONFIG
from main import app

client = TestClient(app)

_SECRET = "test-livekit-secret-value-0123456789"
_KEY = "test-livekit-key"

# One interview-mode profile holding every field the founder enumerated: the
# core identity (name, birthdate, gender, interested_in, location) and the
# partner preferences that used to live in the unread ``users.matching_prefs``
# and now land on the ``qz_*`` mirror the prompt actually reads.
_PROFILE = {
    "name": "Dillu",
    "birthdate": "1996-06-16",
    "gender": "Man",
    "interested_in": ["Women"],
    "location": "San Jose, US",
    "photos": ["a.jpg"],
    "qz_partner_age_min": 26,
    "qz_partner_age_max": 38,
    "distance_pref": "50",
}

# The user's core identity (name, age/birthdate) reaches the prompt through the
# always-on ``identity`` wiki page (context_opt.CORE_PAGE_TYPES), not through
# the progress/preferences layers — so the parity tests seed a representative
# identity block and assert it survives.
_WIKI_IDENTITY = "## Identity\nDillu, 30, a software engineer living in San Jose."

# Substrings that prove each enumerated field made it into the built prompt.
# Name/age come from the wiki identity block; the rest from describe_preferences.
_EXPECTED = {
    "name": "Dillu",
    "age": "30",
    "location": "San Jose, US",
    "gender": "Man",
    "interested_in": "Women",
    "partner age range": "26 to 38",
    "distance": "within 50 miles",
}


class _Snap:
    exists = True

    def __init__(self, data):
        self._data = data

    def to_dict(self):
        return self._data


class _Ref:
    def __init__(self, data):
        self._data = data

    def get(self):
        return _Snap(self._data)


def _valid_auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid-123"}
    )
    return {"Authorization": "Bearer valid"}


def _interview_profile(monkeypatch, profile=None):
    """Put the fixture profile behind the shared helpers and force interview
    mode (where both the preboarding-progress and the saved-preferences layers
    fire), overriding the ``no_firestore`` conftest stubs."""
    data = _PROFILE if profile is None else profile
    monkeypatch.setattr(main, "_session_mode", lambda _caller: "interview")
    monkeypatch.setattr(main.schema, "profile_doc", lambda _db, _uid: _Ref(data))
    # The identity wiki page is where name/age live; conftest stubs the reader
    # to "" by default, so restore a representative block for these tests.
    monkeypatch.setattr(
        main, "read_wiki_context", lambda _db, _uid, *a, **k: _WIKI_IDENTITY
    )


def _livekit_env(monkeypatch):
    patched = dataclasses.replace(CONFIG, livekit_url="wss://test.livekit.cloud")
    monkeypatch.setattr(main, "CONFIG", patched)
    monkeypatch.setattr(livekit_token, "CONFIG", patched)
    monkeypatch.setenv("LIVEKIT_API_KEY", _KEY)
    monkeypatch.setenv("LIVEKIT_API_SECRET", _SECRET)
    seeds = []

    async def _fake_seed(room, seed_json, agent_name=None):
        seeds.append((room, seed_json))

    monkeypatch.setattr(main, "seed_room_context", _fake_seed)

    async def _fake_watch(_room):
        return False

    monkeypatch.setattr(main, "watch_hosted_dispatch", _fake_watch)
    return seeds


def test_voice_seed_carries_every_profile_field(monkeypatch):
    """The ``/bootstrap`` voice seed — the exact ``system_prompt`` both the
    Google and the LiveKit Inference agent read from room metadata."""
    _interview_profile(monkeypatch)
    seeds = _livekit_env(monkeypatch)
    resp = client.post(
        "/bootstrap",
        headers=_valid_auth(monkeypatch),
        json={"session_id": "s-voice", "recent_turns": []},
    )
    assert resp.status_code == 200
    seed = json.loads(seeds[0][1])
    sp = seed["system_prompt"]
    for field, needle in _EXPECTED.items():
        assert needle in sp, f"voice seed dropped {field!r} ({needle!r})"


def test_chat_prompt_carries_every_profile_field(monkeypatch):
    """The ``/chat`` system prompt handed to Gemini for a text turn."""
    _interview_profile(monkeypatch)
    captured = {}

    async def _fake(_message, **kw):
        captured["sp"] = kw["system_prompt"]
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _fake)
    resp = client.post(
        "/chat", json={"message": "hi ayma"}, headers=_valid_auth(monkeypatch)
    )
    assert resp.status_code == 200
    sp = captured["sp"]
    for field, needle in _EXPECTED.items():
        assert needle in sp, f"chat prompt dropped {field!r} ({needle!r})"


def test_voice_and_chat_carry_the_same_fields(monkeypatch):
    """Belt and braces: the two paths agree field-for-field, so neither can
    regress without the other noticing."""
    _interview_profile(monkeypatch)
    seeds = _livekit_env(monkeypatch)
    client.post(
        "/bootstrap",
        headers=_valid_auth(monkeypatch),
        json={"session_id": "s-voice", "recent_turns": []},
    )
    voice_sp = json.loads(seeds[0][1])["system_prompt"]

    captured = {}

    async def _fake(_message, **kw):
        captured["sp"] = kw["system_prompt"]
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _fake)
    client.post("/chat", json={"message": "hi"}, headers=_valid_auth(monkeypatch))
    chat_sp = captured["sp"]

    for needle in _EXPECTED.values():
        assert (needle in voice_sp) == (needle in chat_sp) is True


def test_compose_carries_the_fields_in_both_persona_variants():
    """The shared builder keeps every field in the lean voice variant as well
    as the full text variant — the voice diet drops UI mechanics, never the
    user's own profile/preferences."""
    progress = session_mode.describe_progress(_PROFILE)
    prefs = session_mode.describe_preferences(_PROFILE)
    for variant in ("text", "voice"):
        composed = prompt_mod.compose_system_prompt(
            session_mode="interview",
            wiki_context=_WIKI_IDENTITY,
            profile_progress=progress,
            preferences_context=prefs,
            variant=variant,
        )
        for field, needle in _EXPECTED.items():
            assert needle in composed, f"{variant} variant dropped {field!r}"


def test_progress_marks_known_fields_do_not_ask():
    """The preboarding-progress layer tells Ayma the on-screen form already
    holds name/DOB/etc., so she confirms rather than re-asks."""
    progress = session_mode.describe_progress(_PROFILE)
    assert "do NOT ask for them again" in progress
    for label in ("name", "date of birth", "gender",
                  "who they're interested in", "where they live"):
        assert label in progress


def test_answered_partner_age_is_not_offered_again(monkeypatch):
    """The founder's exact bug: the partner age range was re-asked because it
    lived in a field nothing read. Once recorded it must drop out of
    ``next_questions`` so Ayma never re-asks it."""
    import skills
    from tests.test_questionnaire_skill import FakeDb, _PROF, _run

    db = FakeDb({_PROF: {}})
    fns = skills.make_session_tool_fns(db, "u1")

    fns["record_answer"]("partner_age_min", "26", "stated")
    fns["record_answer"]("partner_age_max", "38", "stated")
    after = json.loads(_run(fns["next_questions"]()))
    open_ids = {q["id"] for q in after["questions"]}
    assert "partner_age_min" not in open_ids
    assert "partner_age_max" not in open_ids
    # and it is persisted where the prompt reads it
    assert db.docs[_PROF]["qz_partner_age_min"] == 26
    assert db.docs[_PROF]["qz_partner_age_max"] == 38


def test_answered_topic_absent_from_the_questionnaire_note(monkeypatch):
    """The active-mode questionnaire note lists only still-open topics; an
    answered one is gone from it, so Ayma works the next gap instead of
    repeating herself."""
    monkeypatch.setattr(main, "_session_mode", lambda _caller: "active")
    profile = {
        "completeness": {
            "score": 40,
            "complete": False,
            "intent_set": True,
            "intent": "long_term",
            "next": [
                {"label": "Love languages", "ayma_prompt": "How do you show care?"},
                {"label": "Weekends", "ayma_prompt": "What does a good weekend look like?"},
            ],
            "tree_version": "v-current",
        }
    }
    monkeypatch.setattr(main.schema, "profile_doc", lambda _db, _uid: _Ref(profile))
    monkeypatch.setattr(main.completeness, "is_current", lambda _c: True)

    note = main._questionnaire_note("u1", "active")
    assert "Love languages" in note
    assert "Weekends" in note
    # an item the user already answered is simply not in `next`, so it is not
    # named for re-asking
    assert "Partner age range" not in note
