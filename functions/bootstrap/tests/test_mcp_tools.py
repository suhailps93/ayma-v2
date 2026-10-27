"""Server-side gates on every MCP tool (mcp_tools.py).

The connected agent is untrusted, so each tool re-enforces scope, the 18+ gate,
moderation, no-PII and per-user scoping. These tests assert those gates hold and
that no tool path spends an Ayma LLM (the one model call — DM moderation — is
monkeypatched, never a chat/reasoning call)."""

from __future__ import annotations

import asyncio

import pytest

import age_gate
import dm_moderation
import mcp_oauth
import mcp_tools
import profile_manual
import schema
import token_ledger
from firebase_admin import firestore
from mcp_tools import McpToolError
from tests.fake_firestore import SERVER_TIMESTAMP, FakeDb

UID = "user-1"
OTHER = "user-2"


def _principal(scopes=mcp_oauth.ALL_SCOPES):
    return mcp_oauth.Principal(
        uid=UID, scopes=frozenset(scopes), token_id="tok", client_id="claude"
    )


@pytest.fixture
def meter(monkeypatch):
    calls: list[str] = []
    monkeypatch.setattr(token_ledger, "record_mcp_tool_call", lambda uid, tool: calls.append(tool))
    return calls


@pytest.fixture(autouse=True)
def _setup(monkeypatch):
    monkeypatch.setattr(firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP, raising=False)
    age_gate.clear_cache()
    mcp_oauth.clear_cache()


def _db_with_adults():
    db = FakeDb()
    for uid in (UID, OTHER):
        db.docs[("users", uid, "profile", "main")] = {
            "name": "Alex" if uid == UID else "Sam",
            "birthdate": "1990-01-01",
            "gender": "Woman",
            "interested_in": ["Men"],
            "location": "San Jose",
        }
    return db


# ---- scope enforcement --------------------------------------------------- #


def test_every_tool_refuses_without_its_scope(meter):
    db = _db_with_adults()
    empty = _principal(scopes=())
    with pytest.raises(McpToolError) as e:
        mcp_tools.get_profile(db, empty)
    assert e.value.code == "forbidden_scope"
    with pytest.raises(McpToolError):
        mcp_tools.list_matches(db, empty)
    with pytest.raises(McpToolError):
        mcp_tools.list_threads(db, empty)
    with pytest.raises(McpToolError):
        mcp_tools.get_match(db, empty, OTHER)
    with pytest.raises(McpToolError):
        asyncio.run(mcp_tools.send_message(db, empty, OTHER, "hi"))
    with pytest.raises(McpToolError):
        mcp_tools.get_persona_context(db, empty, OTHER)
    assert meter == []  # nothing metered on a refused call


# ---- 18+ gate ------------------------------------------------------------ #


def test_age_gate_refusal_is_translated(monkeypatch, meter):
    # The shared 18+ gate (age_gate.enforce, its own tests in test_age_gate.py)
    # is globally stubbed to a no-op by conftest; here we assert that when it
    # DOES refuse, the MCP layer surfaces it as a clean `age` tool error.
    db = _db_with_adults()

    def _raise(*a, **k):
        raise age_gate.AgeGateError("underage", "You must be 18 or older to use Ayma.")

    monkeypatch.setattr(age_gate, "enforce", _raise)
    with pytest.raises(McpToolError) as e:
        mcp_tools.get_profile(db, _principal())
    assert e.value.code == "age"


# ---- get_profile --------------------------------------------------------- #


def test_get_profile_returns_own_structured_fields(meter):
    db = _db_with_adults()
    out = mcp_tools.get_profile(db, _principal())
    assert out["profile"]["name"] == "Alex"
    assert out["profile"]["interested_in"] == ["Men"]
    assert "story" in out
    assert meter == ["get_profile"]


# ---- update_profile ------------------------------------------------------ #


def test_update_profile_sets_a_structured_field(meter):
    db = _db_with_adults()
    out = asyncio.run(mcp_tools.update_profile(db, _principal(), {"name": "Alexandra"}))
    assert out["updated"]["name"] == "set name"
    assert db.docs[("users", UID, "profile", "main")]["name"] == "Alexandra"
    assert meter == ["update_profile"]


def test_update_profile_refuses_underage_birthdate(meter):
    db = _db_with_adults()
    out = asyncio.run(
        mcp_tools.update_profile(db, _principal(), {"birthdate": "2015-01-01"})
    )
    # set_profile_field returns a refusal string; the stored value is unchanged.
    assert "under 18" in out["updated"]["birthdate"]
    assert db.docs[("users", UID, "profile", "main")]["birthdate"] == "1990-01-01"


def test_update_profile_public_text_runs_the_failclosed_path(monkeypatch, meter):
    db = _db_with_adults()
    saved = {}

    async def _fake_save(_db, _uid, text, base_version):
        saved["text"] = text
        return {"ok": True}

    monkeypatch.setattr(profile_manual, "get_text", lambda _db, _uid: {"version": "v0"})
    monkeypatch.setattr(profile_manual, "save_text", _fake_save)
    out = asyncio.run(
        mcp_tools.update_profile(db, _principal(), {"public_text": "I love hiking."})
    )
    assert out["updated"]["public_text"] == "saved"
    assert saved["text"] == "I love hiking."


def test_update_profile_public_text_moderation_refusal_propagates(monkeypatch, meter):
    db = _db_with_adults()

    async def _reject(_db, _uid, text, base_version):
        raise profile_manual.ProfileTextError("moderation", "nope")

    monkeypatch.setattr(profile_manual, "get_text", lambda _db, _uid: {"version": "v0"})
    monkeypatch.setattr(profile_manual, "save_text", _reject)
    with pytest.raises(McpToolError) as e:
        asyncio.run(mcp_tools.update_profile(db, _principal(), {"public_text": "x"}))
    assert e.value.code == "moderation"


# ---- matches ------------------------------------------------------------- #


def test_list_matches_returns_only_own_and_never_ai_explanation(meter):
    db = _db_with_adults()
    from pair_key import sorted_pair_key

    mid = sorted_pair_key(UID, OTHER)
    db.docs[("matches", mid)] = {
        "uids": sorted([UID, OTHER]),
        "score": 0.82,
        "structured_score": 81.0,
        "status": "scored",
        "user_explanation": {UID: "You both value family.", OTHER: "secret-for-them"},
        "ai_explanation": "PRIVATE ai reasoning",
        "shared": ["family"],
    }
    # A match the caller is not part of must never appear.
    db.docs[("matches", "zzz__yyy")] = {"uids": ["zzz", "yyy"], "score": 0.9}
    out = mcp_tools.list_matches(db, _principal())
    assert len(out["matches"]) == 1
    row = out["matches"][0]
    assert row["other_uid"] == OTHER
    assert row["your_explanation"] == "You both value family."
    blob = str(out)
    assert "PRIVATE ai reasoning" not in blob
    assert "secret-for-them" not in blob
    assert meter == ["list_matches"]


def test_get_match_refuses_when_unscored_and_never_triggers_scoring(meter):
    db = _db_with_adults()
    with pytest.raises(McpToolError) as e:
        mcp_tools.get_match(db, _principal(), OTHER)
    assert e.value.code == "not_found"
    # No match doc was created (no scoring was triggered).
    assert not any(k[0] == "matches" for k in db.docs)


def test_get_match_returns_detail_without_ai_explanation(meter):
    db = _db_with_adults()
    from pair_key import sorted_pair_key

    mid = sorted_pair_key(UID, OTHER)
    db.docs[("matches", mid)] = {
        "uids": sorted([UID, OTHER]),
        "score": 0.7,
        "status": "scored",
        "user_explanation": {UID: "mine", OTHER: "theirs"},
        "ai_explanation": "PRIVATE",
        "dimensions": [{"key": "values", "score": 0.8}],
    }
    out = mcp_tools.get_match(db, _principal(), OTHER)
    assert out["your_explanation"] == "mine"
    assert "PRIVATE" not in str(out) and "theirs" not in str(out)


# ---- DMs ----------------------------------------------------------------- #


def test_get_thread_can_only_read_the_callers_own_conversation(meter):
    db = _db_with_adults()
    from pair_key import sorted_pair_key

    tid = sorted_pair_key(UID, OTHER)
    db.docs[("dm_threads", tid)] = {"participants": sorted([UID, OTHER])}
    db.docs[("dm_threads", tid, "messages", "m1")] = {
        "sender_uid": UID, "type": "text", "body": "hey", "created_at": "2026-01-01T00:00:00+00:00"
    }
    db.docs[("dm_threads", tid, "messages", "m2")] = {
        "sender_uid": OTHER, "type": "text", "body": "hi back", "created_at": "2026-01-02T00:00:00+00:00"
    }
    out = mcp_tools.get_thread(db, _principal(), OTHER)
    assert [m["from"] for m in out["messages"]] == ["me", "them"]
    assert out["messages"][-1]["body"] == "hi back"


def test_list_threads_omits_blocked(monkeypatch, meter):
    db = _db_with_adults()
    from pair_key import sorted_pair_key

    tid = sorted_pair_key(UID, OTHER)
    db.docs[("dm_threads", tid)] = {
        "participants": sorted([UID, OTHER]),
        "last_message_at": "2026-01-02T00:00:00+00:00",
    }
    import dm_ops

    monkeypatch.setattr(dm_ops, "blocked_between", lambda _db, a, b: True)
    out = mcp_tools.list_threads(db, _principal())
    assert out["threads"] == []


def test_send_message_blocks_contact_info(meter):
    db = _db_with_adults()
    with pytest.raises(McpToolError) as e:
        asyncio.run(mcp_tools.send_message(db, _principal(), OTHER, "call me 415-555-1212"))
    assert e.value.code == "contact_info"
    assert not any(k[0] == "dm_threads" for k in db.docs)  # nothing sent


def test_send_message_fails_closed_on_flagged_moderation(monkeypatch, meter):
    db = _db_with_adults()

    async def _flagged(_text):
        return {"flagged": True, "reason": "harassment", "categories": ["harassment"]}

    monkeypatch.setattr(dm_moderation, "moderate", _flagged)
    with pytest.raises(McpToolError) as e:
        asyncio.run(mcp_tools.send_message(db, _principal(), OTHER, "something nasty"))
    assert e.value.code == "moderation"
    assert not any(k[0] == "dm_threads" for k in db.docs)


def test_send_message_sends_when_clean(monkeypatch, meter):
    db = _db_with_adults()

    async def _clean(_text):
        return {"flagged": False, "reason": "", "categories": []}

    monkeypatch.setattr(dm_moderation, "moderate", _clean)
    out = asyncio.run(mcp_tools.send_message(db, _principal(), OTHER, "Hi, want to grab coffee?"))
    assert out["ok"] is True and out["message_id"]
    assert any(k[0] == "dm_threads" and k[-2] == "messages" for k in db.docs)
    assert meter == ["send_message"]


# ---- persona context ----------------------------------------------------- #


def test_get_persona_context_uses_the_privacy_boundary(monkeypatch, meter):
    db = _db_with_adults()
    import practice_core

    sentinel = practice_core.PersonaContext(
        target_uid=OTHER, name="Sam", age=30, location="San Jose",
        pages=[{"title": "About", "body": "loves jazz"}], photo_count=2,
    )
    captured = {}

    def _build(_db, viewer, target):
        captured["viewer"], captured["target"] = viewer, target
        return sentinel

    monkeypatch.setattr(practice_core, "build_persona_context", _build)
    out = mcp_tools.get_persona_context(db, _principal(), OTHER)
    assert captured == {"viewer": UID, "target": OTHER}
    assert out["name"] == "Sam"
    assert "persona_prompt" in out and "Name: Sam" in out["persona_prompt"]


def test_get_persona_context_refuses_when_unavailable(monkeypatch, meter):
    db = _db_with_adults()
    import practice_core

    monkeypatch.setattr(practice_core, "build_persona_context", lambda *_: None)
    with pytest.raises(McpToolError) as e:
        mcp_tools.get_persona_context(db, _principal(), OTHER)
    assert e.value.code == "not_found"


# ---- metering writes ----------------------------------------------------- #


def test_record_mcp_tool_call_is_cost_free(monkeypatch):
    db = FakeDb()
    monkeypatch.setattr(firestore, "SERVER_TIMESTAMP", SERVER_TIMESTAMP, raising=False)
    monkeypatch.setattr(token_ledger, "get_db", lambda: db)
    token_ledger.record_mcp_tool_call(UID, "get_profile")
    doc = db.docs[("users", UID)]
    # It writes a SEPARATE counter — never token_usage / credits.
    assert "mcp_usage" in doc
    assert "token_usage" not in doc
