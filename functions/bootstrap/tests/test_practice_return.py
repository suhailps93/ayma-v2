"""Practice-voice return (founder rule, 2026-11-06).

When voice mode was on and a Practice Date voice call displaced Ayma's
session, the app restarts Ayma's session at the end of the practice call
with ``practice_return_session_id`` on /bootstrap. Bootstrap then seeds the
new room with greeting instructions that open the debrief ("How did it
go?"), composed server-side from the practice session and its debrief.
"""

import asyncio
import dataclasses
import json

import main
import practice_date
import practice_llm
import practice_seed
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import livekit_token
from config import CONFIG
from fake_firestore import FakeDb

client = TestClient(main.app)

VIEWER = "viewer_uid"
MAYA = "demo_practice_maya"
_SECRET = "test-livekit-" + "secret"
_KEY = "test-livekit-key"


def _auth(monkeypatch, uid=VIEWER):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer <redacted>"}


def _mock_db(monkeypatch):
    db = FakeDb()
    practice_seed.seed(db)
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(practice_date, "get_db", lambda: db)
    return db


def _practice_session(db, sid="psess_1", turns=None, debrief=None):
    data = {"target_uid": MAYA, "turns": turns or []}
    if debrief is not None:
        data["debrief"] = debrief
    (
        db.collection("users")
        .document(VIEWER)
        .collection("practice_sessions")
        .document(sid)
        .set(data)
    )
    return sid


def _session_doc(db, sid):
    return (
        db.collection("users")
        .document(VIEWER)
        .collection("practice_sessions")
        .document(sid)
        .get()
        .to_dict()
    )


def _install_fake_llm():
    async def fake_text(system, message, uid, feature, session_id):
        return f"I like that, {message} — tell me more"

    async def fake_json(system, contents, schema, uid, feature):
        props = (schema or {}).get("properties", {})
        if "hint" in props:
            return {"hint": "You're on the right track, keep it light"}
        return {
            "what_worked": ["Good energy and tone"],
            "suggested_next_lines": ["Ask about her weekend plans"],
            "avoid": ["Never ask for personal details too early"],
        }

    practice_llm.set_override(text=fake_text, json=fake_json)


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


# --------------------------------------------------------------------------- #
# The greeting composition
# --------------------------------------------------------------------------- #


def test_greeting_opens_the_debrief_and_caches_it(monkeypatch):
    db = _mock_db(monkeypatch)
    _install_fake_llm()
    try:
        sid = _practice_session(
            db,
            turns=[
                {"role": "user", "text": "hi Maya"},
                {"role": "match", "text": "hey!"},
            ],
        )
        greeting = asyncio.run(main._practice_return_greeting(VIEWER, sid))
        assert "SPEAK FIRST" in greeting
        assert "how did it go" in greeting.lower()
        assert "Maya" in greeting
        # The debrief rides along (the fake LLM's deterministic debrief).
        assert "Good energy and tone" in greeting
        assert "Never ask for personal details too early" in greeting
        # ...and is cached on the session doc for /practice/debrief to reuse.
        stored = _session_doc(db, sid)
        assert stored["debrief"]["what_worked"] == ["Good energy and tone"]
    finally:
        practice_llm.clear_override()


def test_greeting_unknown_session_is_empty(monkeypatch):
    _mock_db(monkeypatch)
    assert asyncio.run(main._practice_return_greeting(VIEWER, "nope")) == ""


def test_greeting_without_a_transcript_still_asks_how_it_went(monkeypatch):
    db = _mock_db(monkeypatch)
    sid = _practice_session(db, turns=[])
    greeting = asyncio.run(main._practice_return_greeting(VIEWER, sid))
    assert "how did it go" in greeting.lower()
    assert "Maya" in greeting


# --------------------------------------------------------------------------- #
# /bootstrap wiring
# --------------------------------------------------------------------------- #


def test_bootstrap_seeds_the_greeting_for_a_practice_return(monkeypatch):
    seeds = _livekit_env(monkeypatch)

    async def _greet(uid, sid):
        assert (uid, sid) == (VIEWER, "psess_9")
        return "SENTINEL GREETING"

    monkeypatch.setattr(main, "_practice_return_greeting", _greet)
    resp = client.post(
        "/bootstrap",
        json={
            "session_id": "s-return",
            "recent_turns": [],
            "practice_return_session_id": "psess_9",
        },
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    assert seeds, "expected the room to be seeded"
    seed = json.loads(seeds[-1][1])
    assert seed["greeting_instructions"] == "SENTINEL GREETING"


def test_bootstrap_without_a_practice_return_seeds_no_greeting(monkeypatch):
    seeds = _livekit_env(monkeypatch)
    resp = client.post(
        "/bootstrap",
        json={"session_id": "s-plain", "recent_turns": []},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    assert seeds, "expected the room to be seeded"
    seed = json.loads(seeds[-1][1])
    assert seed["greeting_instructions"] == ""


# --------------------------------------------------------------------------- #
# /practice/debrief reuses the cached debrief
# --------------------------------------------------------------------------- #


def test_debrief_endpoint_reuses_the_cached_debrief(monkeypatch):
    db = _mock_db(monkeypatch)
    cached = {
        "what_worked": ["Cached win"],
        "suggested_next_lines": ["Cached line"],
        "avoid": ["Cached avoid"],
    }
    sid = _practice_session(
        db, turns=[{"role": "user", "text": "hi"}], debrief=cached
    )

    def _boom(*args, **kwargs):
        raise AssertionError("generate_debrief must not run for a cached debrief")

    monkeypatch.setattr(practice_date, "generate_debrief", _boom)
    resp = client.post(
        "/practice/debrief",
        json={"session_id": sid},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["what_worked"] == ["Cached win"]
    assert body["suggested_next_lines"] == ["Cached line"]
    assert body["avoid"] == ["Cached avoid"]
