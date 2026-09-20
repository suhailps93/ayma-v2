import asyncio

import post_turn
import wiki_ingest
from post_turn import persist_and_ingest, persist_raw_turns
from transcript import Turn


def _run(coro):
    return asyncio.run(coro)


class _FakeDoc:
    def __init__(self):
        self.written = None
        self.merge = None

    def set(self, payload, merge=False):
        self.written = payload
        self.merge = merge


class _FakeDb:
    def __init__(self):
        self.doc = _FakeDoc()
        self.path = []

    def collection(self, name):
        self.path.append(name)
        return self

    def document(self, name):
        self.path.append(name)
        return self

    # after two collection/document pairs the chain resolves to the doc
    def set(self, *a, **k):
        return self.doc.set(*a, **k)


def test_persist_writes_one_merged_doc_at_the_session_path():
    db = _FakeDb()
    persist_raw_turns(
        db,
        "uid-1",
        "sess-1",
        [Turn("user", "hi"), Turn("ayma", "hello")],
    )
    assert db.path == ["users", "uid-1", "raw_turns", "sess-1"]
    assert db.doc.merge is True
    assert db.doc.written["turn_count"] == 2
    assert db.doc.written["turns"] == [
        {"role": "user", "text": "hi"},
        {"role": "ayma", "text": "hello"},
    ]


def test_persist_is_a_noop_for_empty_input():
    db = _FakeDb()
    persist_raw_turns(db, "uid-1", "sess-1", [])
    persist_raw_turns(db, "", "sess-1", [Turn("user", "x")])
    assert db.doc.written is None


# --- persist_and_ingest -------------------------------------------------
#
# This is the fix for a real production bug (uid iWhWjiWhEpU7iyu9B9vy7GlT0PD2,
# 2026-09-20): the voice agent worker's session-shutdown hook — the one hook
# guaranteed to run when a room closes, whether that's a clean hangup or the
# user running out of credits mid-call — used to call only
# `persist_raw_turns`. The transcript was saved, but nothing ever tried to
# fold it into the wiki, and a client `/post-turn` call (or an in-session
# `remember` tool call, which is rate-limited) is NOT guaranteed once a room
# disconnects abnormally. A real answer to a questionnaire question given
# right before the user's credits ran out was acknowledged in-session by Ayma
# but never written anywhere durable, so it read as unanswered again next
# session. `persist_and_ingest` bundles both halves of session-end
# persistence so any shutdown/disconnect hook that calls it gets the wiki
# write too, not just the raw transcript.


def test_persist_and_ingest_calls_both_persist_and_wiki_ingest(monkeypatch):
    db = _FakeDb()
    calls = []

    async def _fake_ingest_or_defer(_db, uid, session_id, turns):
        calls.append((uid, session_id, [t.text for t in turns]))
        return 1

    monkeypatch.setattr(wiki_ingest, "ingest_or_defer", _fake_ingest_or_defer)

    turns = [
        Turn(
            "ayma",
            "Is there a past relationship that taught you the most about "
            "what you're looking for now?",
        ),
        Turn("user", "No."),
        Turn("user", "I'm a virgin."),
    ]
    _run(persist_and_ingest(db, "uid-1", "sess-voice-1", turns))

    # The raw transcript is still durably persisted...
    assert db.path == ["users", "uid-1", "raw_turns", "sess-voice-1"]
    assert db.doc.written["turn_count"] == 3
    # ...and, unlike before the fix, the same session-end hook also attempts
    # a wiki write for the exact same window — including the answer that
    # previously vanished.
    assert len(calls) == 1
    uid, session_id, texts = calls[0]
    assert (uid, session_id) == ("uid-1", "sess-voice-1")
    assert "No." in texts and "I'm a virgin." in texts


def test_persist_and_ingest_is_a_noop_for_empty_turns(monkeypatch):
    db = _FakeDb()
    called = []
    monkeypatch.setattr(
        wiki_ingest, "ingest_or_defer",
        lambda *a, **k: called.append(1),
    )
    _run(persist_and_ingest(db, "uid-1", "sess-1", []))
    assert called == []


def test_persist_and_ingest_swallows_an_ingest_failure(monkeypatch):
    """A shutdown hook must never raise, even if the wiki write blows up for
    an unrelated reason (a Gemini call failing outright, say)."""
    db = _FakeDb()

    async def _boom(*a, **k):
        raise RuntimeError("gemini is down")

    monkeypatch.setattr(wiki_ingest, "ingest_or_defer", _boom)

    # Must not raise.
    _run(persist_and_ingest(db, "uid-1", "sess-1", [Turn("user", "hi")]))
    # The raw transcript still landed even though ingest failed.
    assert db.doc.written["turn_count"] == 1


def test_persist_and_ingest_swallows_a_raw_turns_persist_failure(monkeypatch):
    """Even if the raw_turns write itself fails, the wiki-ingest attempt
    still runs — the two halves are independent, not chained."""

    def _boom(*a, **k):
        raise RuntimeError("firestore is down")

    monkeypatch.setattr(post_turn, "persist_raw_turns", _boom)
    calls = []

    async def _fake_ingest_or_defer(_db, uid, session_id, turns):
        calls.append((uid, session_id))
        return 0

    monkeypatch.setattr(wiki_ingest, "ingest_or_defer", _fake_ingest_or_defer)

    _run(persist_and_ingest(object(), "uid-1", "sess-1", [Turn("user", "hi")]))
    assert calls == [("uid-1", "sess-1")]
