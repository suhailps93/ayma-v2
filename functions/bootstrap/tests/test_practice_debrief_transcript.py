"""Practice Date voice-debrief transcript integrity — regression tests.

Founder re-report on build 2350: the Practice Date voice feedback showed
random stuff, not about the conversation actually had. Root causes (verified
in staging code): (1) ``append_turns`` is a read-modify-write with no
transaction, so concurrent voice persists lose turns; (2) no end-of-call
drain, so the debrief is generated from a partial transcript; (3)
``generate_debrief`` runs on an empty transcript and hallucinates; (4) a
partial debrief cached by the voice-return greeting is reused verbatim
forever.

These tests FAIL on unmodified staging (demonstrated before the fix) and pass
after. The wait constants are monkeypatched short so the finalization-wait
tests stay fast.
"""

from __future__ import annotations

import asyncio
import threading

from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import main
import practice_core
import practice_date
import practice_seed
from fake_firestore import FakeDb

client = TestClient(main.app)

VIEWER = "viewer_uid"
MAYA = "demo_practice_maya"


def _seeded_db() -> FakeDb:
    db = FakeDb()
    practice_seed.seed(db)
    return db


def _auth(monkeypatch, uid=VIEWER):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer <redacted>"}


def _mock_db(monkeypatch, db=None):
    if db is None:
        db = _seeded_db()
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(practice_date, "get_db", lambda: db)
    return db


def _voice_session(db, sid="psess_voice", turns=None, **extra):
    data = {"target_uid": MAYA, "turns": turns or [], "modality": "voice"}
    data.update(extra)
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


def _short_wait(monkeypatch, total=0.3, poll=0.05):
    # raising=False: these constants do not exist on unmodified staging;
    # the tests must still reach their assertions there.
    monkeypatch.setattr(
        practice_date, "_DEBRIEF_FINAL_WAIT_SECONDS", total, raising=False
    )
    monkeypatch.setattr(
        practice_date, "_DEBRIEF_FINAL_POLL_SECONDS", poll, raising=False
    )


# --- (A) no lost voice turns ------------------------------------------------- #


def test_concurrent_appends_lose_no_turns(monkeypatch):
    """Interleaved voice persists (user turn + match turn racing) must not
    lose turns. The barrier forces every appender to load the same base list
    before any of them writes — the exact interleave the live coach produced
    (one fire-and-forget persist per turn, each doing load -> extend ->
    update). Each pair must survive whole and adjacent."""
    db = _seeded_db()
    sid = practice_core.start_or_resume_session(db, VIEWER, MAYA, modality="voice")
    pairs = [
        [
            {"role": "user", "text": f"user line {i}"},
            {"role": "match", "text": f"match line {i}"},
        ]
        for i in range(6)
    ]
    orig_load = practice_core._load_session
    barrier = threading.Barrier(len(pairs))

    def _loading_load(db_, uid, sid_):
        data = orig_load(db_, uid, sid_)
        barrier.wait(timeout=10)
        return data

    monkeypatch.setattr(practice_core, "_load_session", _loading_load)
    errors: list = []

    def _append(pair):
        try:
            practice_core.append_turns(db, VIEWER, sid, pair)
        except Exception as exc:  # noqa: BLE001 - collected, asserted below
            errors.append(exc)

    threads = [threading.Thread(target=_append, args=(p,)) for p in pairs]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=15)
    assert not errors, errors
    # Read the doc directly: _load_session is still barrier-patched above.
    stored = (
        db.collection("users")
        .document(VIEWER)
        .collection(practice_core.PRACTICE_SESSIONS_COLLECTION)
        .document(sid)
        .get()
        .to_dict()["turns"]
    )
    texts = [t["text"] for t in stored]
    expected = [text for pair in pairs for text in (pair[0]["text"], pair[1]["text"])]
    assert sorted(texts) == sorted(expected)
    for pair in pairs:
        i = texts.index(pair[0]["text"])
        assert texts[i + 1] == pair[1]["text"]


def test_persist_queue_preserves_event_order_and_marks_final():
    """The voice worker's ordered persist queue drains turns in event order
    and marks the transcript final on close, so the debrief endpoint can
    tell a complete transcript from a still-draining one."""
    db = _seeded_db()
    sid = practice_core.start_or_resume_session(db, VIEWER, MAYA, modality="voice")
    turns = [{"role": "user", "text": f"line {i}"} for i in range(5)]

    async def _run():
        queue = practice_core.PracticePersistQueue(db, VIEWER, sid)
        queue.start()
        first = queue.enqueue(turns[0])
        await first  # the future resolves only once the turn is persisted
        assert practice_core._load_session(db, VIEWER, sid)["turns"]
        for turn in turns[1:]:
            queue.enqueue(turn)
        await queue.drain()
        stored = practice_core._load_session(db, VIEWER, sid)["turns"]
        assert [t["text"] for t in stored] == [t["text"] for t in turns]
        await queue.close()
        assert practice_core._load_session(db, VIEWER, sid).get(
            "transcript_final_at"
        )

    asyncio.run(_run())


# --- (C) no hallucinated debriefs -------------------------------------------- #


def test_empty_voice_debrief_never_calls_llm_and_caches_nothing(monkeypatch):
    """A voice session with no captured transcript gets an honest empty
    outcome — the model is never asked to invent feedback from nothing, and
    nothing is cached for a later consumer to reuse."""
    db = _mock_db(monkeypatch)
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)
    _short_wait(monkeypatch)
    sid = _voice_session(db, turns=[])

    async def _boom(*args, **kwargs):
        raise AssertionError("generate_debrief must not run on an empty transcript")

    monkeypatch.setattr(practice_date, "generate_debrief", _boom)
    resp = client.post(
        "/practice/debrief", json={"session_id": sid}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["empty"] is True
    assert body["what_worked"] == []
    assert body["suggested_next_lines"] == []
    assert body["avoid"] == []
    stored = _session_doc(db, sid)
    assert "debrief" not in stored
    assert stored["ended_at"] is not None


def test_debrief_waits_for_finalization_then_uses_final_transcript(monkeypatch):
    """The debrief endpoint waits (bounded) for a voice session's transcript
    to finalize, then generates from the FINAL transcript — not the partial
    one that was visible when the request arrived."""
    db = _mock_db(monkeypatch)
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)
    monkeypatch.setattr(
        practice_date, "_DEBRIEF_FINAL_WAIT_SECONDS", 2.0, raising=False
    )
    monkeypatch.setattr(
        practice_date, "_DEBRIEF_FINAL_POLL_SECONDS", 0.05, raising=False
    )
    sid = _voice_session(db, turns=[])
    seen: dict = {}

    async def _capture(ctx, turns, *, uid):
        seen["turns"] = list(turns)
        return {
            "what_worked": ["final win"],
            "suggested_next_lines": ["final line"],
            "avoid": [],
        }

    monkeypatch.setattr(practice_date, "generate_debrief", _capture)

    def _land_final():
        threading.Event().wait(0.2)
        practice_core.append_turns(
            db,
            VIEWER,
            sid,
            [
                {"role": "user", "text": "final user words"},
                {"role": "match", "text": "final match words"},
            ],
        )
        practice_core.mark_transcript_final(db, VIEWER, sid)

    t = threading.Thread(target=_land_final)
    t.start()
    try:
        resp = client.post(
            "/practice/debrief", json={"session_id": sid}, headers=_auth(monkeypatch)
        )
    finally:
        t.join(timeout=5)
    assert resp.status_code == 200
    assert [x["text"] for x in seen["turns"]] == [
        "final user words",
        "final match words",
    ]
    assert resp.json()["what_worked"] == ["final win"]


# --- (D) cache integrity ------------------------------------------------------ #


def test_stale_turn_count_debrief_is_regenerated(monkeypatch):
    """A stored debrief generated from fewer turns than the session now
    holds is stale — the endpoint regenerates from the current transcript
    and re-caches with the new count instead of serving the partial one."""
    db = _mock_db(monkeypatch)
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)
    _short_wait(monkeypatch)
    stale = {
        "what_worked": ["stale win"],
        "suggested_next_lines": ["stale line"],
        "avoid": [],
    }
    sid = _voice_session(
        db,
        turns=[
            {"role": "user", "text": "first"},
            {"role": "match", "text": "second"},
        ],
        debrief=stale,
        debrief_turn_count=1,
    )
    seen: dict = {}

    async def _capture(ctx, turns, *, uid):
        seen["turns"] = list(turns)
        return {
            "what_worked": ["fresh win"],
            "suggested_next_lines": ["fresh line"],
            "avoid": ["fresh avoid"],
        }

    monkeypatch.setattr(practice_date, "generate_debrief", _capture)
    resp = client.post(
        "/practice/debrief", json={"session_id": sid}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert resp.json()["what_worked"] == ["fresh win"]
    assert len(seen["turns"]) == 2
    stored = _session_doc(db, sid)
    assert stored["debrief"]["what_worked"] == ["fresh win"]
    assert stored["debrief_turn_count"] == 2


def test_matching_turn_count_debrief_is_reused_without_llm(monkeypatch):
    """A stored debrief whose turn count matches the session is reused —
    no second model call."""
    db = _mock_db(monkeypatch)
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)
    _short_wait(monkeypatch)
    cached = {
        "what_worked": ["cached win"],
        "suggested_next_lines": ["cached line"],
        "avoid": ["cached avoid"],
    }
    sid = _voice_session(
        db,
        turns=[
            {"role": "user", "text": "first"},
            {"role": "match", "text": "second"},
        ],
        debrief=cached,
        debrief_turn_count=2,
    )

    async def _boom(*args, **kwargs):
        raise AssertionError("generate_debrief must not run for a matching cache")

    monkeypatch.setattr(practice_date, "generate_debrief", _boom)
    resp = client.post(
        "/practice/debrief", json={"session_id": sid}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert resp.json()["what_worked"] == ["cached win"]
    assert resp.json()["suggested_next_lines"] == ["cached line"]
    assert resp.json()["avoid"] == ["cached avoid"]


def _counting_debrief(monkeypatch):
    calls: list = []

    async def _counting(ctx, turns, *, uid):
        calls.append(len(turns))
        return {
            "what_worked": [f"turns-{len(turns)}"],
            "suggested_next_lines": [],
            "avoid": [],
        }

    monkeypatch.setattr(practice_core, "generate_debrief", _counting)
    return calls


def test_greeting_regenerates_when_turns_grew(monkeypatch):
    """The voice-return greeting caches a debrief with the turn count it was
    generated from; when more turns land, the next greeting regenerates
    instead of reciting the partial one."""
    db = _mock_db(monkeypatch)
    calls = _counting_debrief(monkeypatch)
    sid = _voice_session(db, turns=[{"role": "user", "text": "hi Maya"}])
    g1 = asyncio.run(main._practice_return_greeting(VIEWER, sid))
    assert "turns-1" in g1
    practice_core.append_turns(
        db, VIEWER, sid, [{"role": "match", "text": "hey there"}]
    )
    g2 = asyncio.run(main._practice_return_greeting(VIEWER, sid))
    assert "turns-2" in g2
    assert calls == [1, 2]


def test_greeting_reuses_matching_count_without_second_call(monkeypatch):
    """With no new turns, the greeting reuses the cached debrief — one model
    call total, not one per greeting."""
    db = _mock_db(monkeypatch)
    calls = _counting_debrief(monkeypatch)
    sid = _voice_session(db, turns=[{"role": "user", "text": "hi Maya"}])
    g1 = asyncio.run(main._practice_return_greeting(VIEWER, sid))
    g2 = asyncio.run(main._practice_return_greeting(VIEWER, sid))
    assert "turns-1" in g1 and "turns-1" in g2
    assert calls == [1]


# --- (E) faithful transaction: text & voice turn saves reach store and debrief - #


def test_practice_text_turn_save_lands_and_debrief_sees_turns(monkeypatch):
    """A practice text turn save through append_turns must land in the session
    store against a faithful Firestore transaction, and POST /practice/debrief
    must load those turns and debrief them."""
    db = _mock_db(monkeypatch)
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)
    sid = practice_core.start_or_resume_session(db, VIEWER, MAYA, modality="text")

    saved = practice_core.append_turns(
        db,
        VIEWER,
        sid,
        [
            {"role": "user", "text": "What do you like to do on weekends?"},
            {"role": "match", "text": "I love hiking and exploring coffee shops."},
        ],
    )
    assert len(saved) == 2

    stored = _session_doc(db, sid)
    assert [t["text"] for t in stored["turns"]] == [
        "What do you like to do on weekends?",
        "I love hiking and exploring coffee shops.",
    ]

    seen_turns: list = []

    async def _capture_debrief(ctx, turns, *, uid):
        seen_turns.extend(turns)
        return {
            "what_worked": ["great opening question"],
            "suggested_next_lines": ["ask about favorite trail"],
            "avoid": [],
        }

    monkeypatch.setattr(practice_date, "generate_debrief", _capture_debrief)
    resp = client.post(
        "/practice/debrief", json={"session_id": sid}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    data = resp.json()
    assert not data.get("empty")
    assert data["what_worked"] == ["great opening question"]
    assert len(seen_turns) == 2
    assert [t["text"] for t in seen_turns] == [
        "What do you like to do on weekends?",
        "I love hiking and exploring coffee shops.",
    ]


def test_practice_voice_turn_save_lands_and_debrief_sees_turns(monkeypatch):
    """A practice voice turn save through PracticePersistQueue and append_turns
    must land in the session store against a faithful Firestore transaction, and
    POST /practice/debrief must load those turns and debrief them."""
    db = _mock_db(monkeypatch)
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)
    sid = practice_core.start_or_resume_session(db, VIEWER, MAYA, modality="voice")

    async def _run():
        queue = practice_core.PracticePersistQueue(db, VIEWER, sid)
        queue.start()
        await queue.enqueue({"role": "user", "text": "Hey Maya, how is your day?"})
        await queue.enqueue({"role": "match", "text": "Hey! It is going really well."})
        await queue.close()

    asyncio.run(_run())

    stored = _session_doc(db, sid)
    assert [t["text"] for t in stored["turns"]] == [
        "Hey Maya, how is your day?",
        "Hey! It is going really well.",
    ]
    assert stored.get("transcript_final_at") is not None

    seen_turns: list = []

    async def _capture_debrief(ctx, turns, *, uid):
        seen_turns.extend(turns)
        return {
            "what_worked": ["friendly tone"],
            "suggested_next_lines": [],
            "avoid": [],
        }

    monkeypatch.setattr(practice_date, "generate_debrief", _capture_debrief)
    resp = client.post(
        "/practice/debrief", json={"session_id": sid}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    data = resp.json()
    assert not data.get("empty")
    assert data["what_worked"] == ["friendly tone"]
    assert len(seen_turns) == 2


def test_practice_persist_queue_does_not_certify_final_on_append_failure(
    monkeypatch, caplog
):
    """If queued appends failed, PracticePersistQueue must NOT mark the
    transcript final, must emit an error-level log, and the debrief must return
    honest-empty without certifying/caching."""
    db = _mock_db(monkeypatch)
    monkeypatch.setattr(main.token_ledger, "check", lambda uid: None)
    _short_wait(monkeypatch)
    sid = practice_core.start_or_resume_session(db, VIEWER, MAYA, modality="voice")

    def _broken_append(*args, **kwargs):
        raise RuntimeError("simulated firestore append failure")

    monkeypatch.setattr(practice_core, "append_turns", _broken_append)

    import logging

    with caplog.at_level(logging.ERROR, logger="ayma.practice_date"):

        async def _run():
            queue = practice_core.PracticePersistQueue(db, VIEWER, sid)
            queue.start()
            await queue.enqueue({"role": "user", "text": "hello?"})
            await queue.close()

        asyncio.run(_run())

    stored = _session_doc(db, sid)
    assert not stored.get("turns")
    assert stored.get("transcript_final_at") is None
    # Error log verified
    error_logs = [r for r in caplog.records if r.levelno >= logging.ERROR]
    assert any("failed" in r.message.lower() for r in error_logs)

    # Debrief remains honest-empty
    resp = client.post(
        "/practice/debrief", json={"session_id": sid}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert resp.json()["empty"] is True


def test_fake_transaction_requires_in_progress_like_real_firestore():
    """FakeTransaction must raise ValueError when used without being started
    via firestore.transactional — exactly as google-cloud-firestore 2.x does."""
    import pytest
    from google.cloud import firestore

    db = FakeDb({("test_coll", "doc1"): {"count": 1}})
    ref = db.collection("test_coll").document("doc1")

    txn = db.transaction()

    with pytest.raises(
        ValueError,
        match="Transaction not in progress, cannot be used in API requests.",
    ):
        ref.get(transaction=txn)

    with pytest.raises(
        ValueError,
        match="Transaction not in progress, cannot be used in API requests.",
    ):
        txn.get(ref)

    with pytest.raises(
        ValueError,
        match="Transaction not in progress, cannot be used in API requests.",
    ):
        txn.update(ref, {"count": 2})

    with pytest.raises(
        ValueError,
        match="Transaction not in progress, cannot be used in API requests.",
    ):
        txn.commit()

    @firestore.transactional
    def _increment(transaction):
        snap = ref.get(transaction=transaction)
        val = snap.to_dict()["count"]
        transaction.update(ref, {"count": val + 1})
        return val + 1

    result = _increment(db.transaction())
    assert result == 2
    assert ref.get().to_dict()["count"] == 2


