"""``propose_dm_message`` / ``send_dm_message`` (skills/dm_outreach.py) — the
two-step confirm for Ayma sending a DM to another real person on the user's
behalf. See the module docstring for the full shape/why.
"""

from __future__ import annotations

import asyncio

from firebase_admin import firestore as fb_firestore

import skills
from skills import dm_outreach


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# --- a minimal Firestore double, same shape as tests/test_dm_ops.py's -------

class _Snap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data or {})


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    @property
    def id(self):
        return self.key[-1]

    def get(self):
        return _Snap(self.store.docs.get(self.key))

    def set(self, data, merge=False):
        cur = dict(self.store.docs.get(self.key) or {}) if merge else {}
        for k, v in data.items():
            if v is fb_firestore.DELETE_FIELD:
                cur.pop(k, None)
            else:
                cur[k] = v
        self.store.docs[self.key] = cur

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key
        self._auto = 0

    def document(self, doc_id=None):
        if doc_id is None:
            self._auto += 1
            doc_id = f"auto{self._auto}"
        return _DocRef(self.store, self.key + (doc_id,))


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def _messages(db: FakeDb, a: str, b: str) -> list[dict]:
    tid = "__".join(sorted((a, b)))
    return [
        v
        for k, v in db.docs.items()
        if len(k) == 4 and k[:2] == ("dm_threads", tid) and k[2] == "messages"
    ]


def _tools(db, uid="u1", session_id="s1"):
    return skills.make_session_tool_fns(
        db, uid, session_ctx={"session_id": session_id, "turn_index": 0, "turns": []}
    )


def _mock_explore(monkeypatch, cards):
    monkeypatch.setattr(dm_outreach.explore, "explore", lambda *a, **k: cards)


async def _unflagged(_text):
    return {"flagged": False, "reason": "", "categories": []}


def test_registered_in_the_shared_registry():
    names = {s.name for s in skills.all_skills()}
    assert "propose_dm_message" in names
    assert "send_dm_message" in names


# --- propose_dm_message: draft only, no side effect on the recipient -------

def test_propose_returns_draft_and_sends_nothing(monkeypatch):
    _mock_explore(monkeypatch, [{"uid": "other1", "name": "Jordan", "self": False}])
    db = FakeDb()
    tools = _tools(db)

    result = tools["propose_dm_message"]("Jordan", "hey! how was your trip?")

    assert "Jordan" in result
    assert "hey! how was your trip?" in result
    assert "?" in result  # asks for confirmation
    # No DM thread/message exists anywhere — proposing has no effect the
    # recipient (or anyone but this same conversation) could ever see.
    assert not _messages(db, "u1", "other1")
    assert ("dm_threads", "other1__u1") not in {k[:2] for k in db.docs}

    # The only write is this conversation's own pending-draft note.
    draft = db.docs[("users", "u1", "sessions", "s1")]["pending_dm"]
    assert draft["other_uid"] == "other1"
    assert draft["body"] == "hey! how was your trip?"


def test_propose_unknown_person_finds_nobody(monkeypatch):
    _mock_explore(monkeypatch, [{"uid": "other1", "name": "Jordan", "self": False}])
    db = FakeDb()
    tools = _tools(db)
    result = tools["propose_dm_message"]("Nobody Here", "hi")
    assert "couldn't find" in result
    assert not db.docs


def test_propose_excludes_self_card(monkeypatch):
    _mock_explore(
        monkeypatch,
        [{"uid": "u1", "name": "Me", "self": True}],
    )
    db = FakeDb()
    tools = _tools(db)
    assert "couldn't find" in tools["propose_dm_message"]("Me", "hi")


# --- send_dm_message: only fires after a real propose call -----------------

def test_send_refuses_with_no_prior_propose(monkeypatch):
    db = FakeDb()
    tools = _tools(db)
    result = _run(tools["send_dm_message"]())
    assert "nothing drafted" in result
    assert not _messages(db, "u1", "other1")


def test_send_requires_the_same_conversation(monkeypatch):
    """A draft proposed in one session_id must not be sendable from a
    different one — 'established this conversation' is enforced by session,
    not just by uid."""
    _mock_explore(monkeypatch, [{"uid": "other1", "name": "Jordan", "self": False}])
    db = FakeDb()
    _tools(db, session_id="s1")["propose_dm_message"]("Jordan", "hi Jordan")

    other_session_tools = _tools(db, session_id="s2")
    result = _run(other_session_tools["send_dm_message"]())
    assert "nothing drafted" in result
    assert not _messages(db, "u1", "other1")


def test_propose_then_confirm_sends_exactly_the_drafted_text(monkeypatch):
    _mock_explore(monkeypatch, [{"uid": "other1", "name": "Jordan", "self": False}])
    monkeypatch.setattr(dm_outreach.dm_moderation, "moderate", _unflagged)
    db = FakeDb()
    tools = _tools(db)

    tools["propose_dm_message"]("Jordan", "hey! how was your trip?")
    result = _run(tools["send_dm_message"]("Jordan"))

    assert "sent" in result.lower()
    msgs = _messages(db, "u1", "other1")
    assert len(msgs) == 1
    assert msgs[0]["body"] == "hey! how was your trip?"
    assert msgs[0]["sender_uid"] == "u1"
    assert msgs[0]["type"] == "text"
    assert "moderated" not in msgs[0]

    # The pending draft is cleared after sending.
    assert "pending_dm" not in db.docs[("users", "u1", "sessions", "s1")]


def test_send_follows_the_same_flag_but_always_deliver_moderation_policy(
    monkeypatch,
):
    """Founder's existing DM-moderation policy (dm_moderation.py): flag it,
    never block it. An Ayma-sent message gets no special pass or extra
    scrutiny — same path, same outcome as a user-typed DM."""
    _mock_explore(monkeypatch, [{"uid": "other1", "name": "Jordan", "self": False}])

    async def _flagged(_text):
        return {"flagged": True, "reason": "harassment", "categories": ["harassment"]}

    monkeypatch.setattr(dm_outreach.dm_moderation, "moderate", _flagged)
    db = FakeDb()
    tools = _tools(db)
    tools["propose_dm_message"]("Jordan", "nasty stuff")
    result = _run(tools["send_dm_message"]())

    assert "sent" in result.lower()
    msgs = _messages(db, "u1", "other1")
    assert len(msgs) == 1
    assert msgs[0]["body"] == "nasty stuff"  # delivered in full, never redacted
    assert msgs[0]["moderated"] is True
    assert msgs[0]["moderation_reason"] == "harassment"


def test_send_blocked_pair_refuses_and_clears_draft(monkeypatch):
    _mock_explore(monkeypatch, [{"uid": "other1", "name": "Jordan", "self": False}])
    monkeypatch.setattr(dm_outreach.dm_moderation, "moderate", _unflagged)
    db = FakeDb()
    db.docs[("blocks", "other1_u1")] = {}
    tools = _tools(db)
    tools["propose_dm_message"]("Jordan", "hi")
    result = _run(tools["send_dm_message"]())
    assert "couldn't send" in result
    assert not _messages(db, "u1", "other1")
