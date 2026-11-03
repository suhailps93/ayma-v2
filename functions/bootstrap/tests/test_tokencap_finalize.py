"""Regression test for TokenCap turn finalization.

Proves that when a chat turn exceeds the token cap (TokenCapExceeded):
(a) persists the usage-capped reply into chat history,
(b) closes the turn honestly in the session turns, and
(c) does not suppress the next conversation open (voice opener fires rather
    than being skipped for resumed_mid_user_turn).
"""
import asyncio
from unittest.mock import MagicMock

import post_turn
from fastapi.testclient import TestClient

import agent
from firebase_admin import auth as firebase_auth
import gemini
import main
import token_ledger
from tests.fake_firestore import FakeDb
from transcript import ROLE_AYMA, ROLE_USER, Turn


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    return {"Authorization": "Bearer valid"}


async def _drain_turns():
    while main._TURN_TASKS:
        await asyncio.gather(*list(main._TURN_TASKS), return_exceptions=True)


class _OpenerSession:
    def __init__(self):
        self._handlers = {}
        self.replies = []

    def on(self, event_name):
        def _dec(fn):
            self._handlers[event_name] = fn
            return fn
        return _dec

    async def generate_reply(self, instructions=None, chat_ctx=None, user_input=None):
        self.replies.append(instructions)


def test_tokencap_chat_turn_finalizes_and_does_not_silence_opener(monkeypatch):
    """Proves the /chat endpoint on TokenCapExceeded:
    (a) persists the capped reply,
    (b) closes the turn in session history,
    (c) does not suppress the next conversation open.
    """
    import httpx
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main, "persist_raw_turns", post_turn.persist_raw_turns)
    headers = _auth(monkeypatch)

    async def _fail_cap(*_a, **_kw):
        raise token_ledger.TokenCapExceeded("out of credits (uid=test-uid)")

    monkeypatch.setattr(gemini, "generate_reply", _fail_cap)

    session_id = "session-tc-1"
    client_msg_id = "cm-tc-1"
    user_message = "What should I wear tonight?"

    async def run():
        transport = httpx.ASGITransport(app=main.app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as ac:
            resp = await ac.post(
                "/chat",
                json={
                    "message": user_message,
                    "session_id": session_id,
                    "client_msg_id": client_msg_id,
                },
                headers=headers,
            )
            assert resp.status_code == 200
            body = resp.json()
            assert body["usage_capped"] is True
            assert body["reply"] == main._USAGE_CAPPED_REPLY

            await _drain_turns()

            # (a) Persists the capped reply in chat_messages
            chat_docs = [
                doc.to_dict()
                for doc in db.collection("users").document("test-uid").collection("chat_messages").stream()
            ]
            roles = [d.get("role") for d in chat_docs]
            texts = [d.get("text") for d in chat_docs]
            assert "user" in roles
            assert user_message in texts
            assert "ayma" in roles
            assert main._USAGE_CAPPED_REPLY in texts

            # (b) Closes the turn in session turns (raw_turns)
            sess_doc = db.collection("users").document("test-uid").collection("raw_turns").document(session_id).get()
            assert sess_doc.exists
            sess_data = sess_doc.to_dict()
            turns_raw = sess_data.get("turns", [])
            assert len(turns_raw) >= 2
            assert turns_raw[-2]["role"] == ROLE_USER
            assert turns_raw[-2]["text"] == user_message
            assert turns_raw[-1]["role"] == ROLE_AYMA
            assert turns_raw[-1]["text"] == main._USAGE_CAPPED_REPLY

            # (c) Does not suppress the next conversation open
            session_turns = [Turn(role=t["role"], text=t["text"]) for t in turns_raw]
            opener_session = _OpenerSession()
            room_seed = agent.RoomSeed(
                uid="test-uid",
                session_id=session_id,
                seed_turns=session_turns,
                system_prompt="sp",
            )

            fired = await agent.maybe_open_conversation(
                opener_session,
                room_seed,
                window=list(session_turns),
                grace_seconds=0.05,
            )
            assert fired is True
            assert len(opener_session.replies) == 1

            # Contrast check (founder-ruled Nov 2, voice-opener option c): an orphaned user turn no longer stays silent — the opener fires and answers the dangling message
            orphan_turns = [Turn(role=ROLE_USER, text=user_message)]
            orphan_session = _OpenerSession()
            orphan_seed = agent.RoomSeed(
                uid="test-uid",
                session_id="orphan-sess",
                seed_turns=orphan_turns,
                system_prompt="sp",
            )
            fired_orphan = await agent.maybe_open_conversation(
                orphan_session,
                orphan_seed,
                window=list(orphan_turns),
                grace_seconds=0.05,
            )
            assert fired_orphan is True
            assert len(orphan_session.replies) == 1

    asyncio.run(run())


def test_tokencap_chat_stream_turn_finalizes_and_does_not_silence_opener(monkeypatch):
    """Proves the /chat/stream endpoint on TokenCapExceeded:
    (a) persists the capped reply,
    (b) closes the turn in session history,
    (c) does not suppress the next conversation open.
    """
    import httpx
    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(main, "persist_raw_turns", post_turn.persist_raw_turns)
    headers = _auth(monkeypatch)

    async def _fail_stream_cap(*_a, **_kw):
        if False:
            yield {}
        raise token_ledger.TokenCapExceeded("out of credits (uid=test-uid)")

    monkeypatch.setattr(gemini, "generate_reply_events", _fail_stream_cap)

    session_id = "session-tc-stream-1"
    client_msg_id = "cm-tc-stream-1"
    user_message = "Give me some travel tips"

    async def run():
        transport = httpx.ASGITransport(app=main.app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as ac:
            resp = await ac.post(
                "/chat/stream",
                json={
                    "message": user_message,
                    "session_id": session_id,
                    "client_msg_id": client_msg_id,
                },
                headers=headers,
            )
            assert resp.status_code == 200

            import json as _json
            events = [
                _json.loads(line[len("data: "):])
                for line in resp.text.splitlines()
                if line.startswith("data: ")
            ]
            reply_events = [e for e in events if e.get("type") == "reply"]
            assert len(reply_events) == 1
            assert reply_events[0]["usage_capped"] is True
            assert reply_events[0]["text"] == main._USAGE_CAPPED_REPLY

            await _drain_turns()

            # (a) Persists the capped reply in chat_messages
            chat_docs = [
                doc.to_dict()
                for doc in db.collection("users").document("test-uid").collection("chat_messages").stream()
            ]
            roles = [d.get("role") for d in chat_docs]
            texts = [d.get("text") for d in chat_docs]
            assert "user" in roles
            assert user_message in texts
            assert "ayma" in roles
            assert main._USAGE_CAPPED_REPLY in texts

            # (b) Closes the turn in session turns (raw_turns)
            sess_doc = db.collection("users").document("test-uid").collection("raw_turns").document(session_id).get()
            assert sess_doc.exists
            sess_data = sess_doc.to_dict()
            turns_raw = sess_data.get("turns", [])
            assert len(turns_raw) >= 2
            assert turns_raw[-2]["role"] == ROLE_USER
            assert turns_raw[-2]["text"] == user_message
            assert turns_raw[-1]["role"] == ROLE_AYMA
            assert turns_raw[-1]["text"] == main._USAGE_CAPPED_REPLY

            # (c) Does not suppress the next conversation open
            session_turns = [Turn(role=t["role"], text=t["text"]) for t in turns_raw]
            opener_session = _OpenerSession()
            room_seed = agent.RoomSeed(
                uid="test-uid",
                session_id=session_id,
                seed_turns=session_turns,
                system_prompt="sp",
            )

            fired = await agent.maybe_open_conversation(
                opener_session,
                room_seed,
                window=list(session_turns),
                grace_seconds=0.05,
            )
            assert fired is True
            assert len(opener_session.replies) == 1

    asyncio.run(run())
