"""Live world-state refresh (``skills.world_state``) — the per-turn
context-freshness fix for the founder's 2026-11-03 live-call defect: Ayma
answered from the screen the call STARTED on and kept saying "let's see
when the match report comes through" about a sim that had already
finished, because her context was only ever refreshed when the model
happened to call the ``current_screen`` tool.

Covered here:
(a) after a navigation, the standing context reflects the NEW screen with
    no "read the screen" prompt and no ``current_screen`` tool call;
(b) a sim flipping running -> done mid-conversation puts the FINISHED
    state (score + ready report) into the context the next answer is
    generated from;
(c) the refresher is silent (never speaks / generates a reply) and
    change-gated (an unchanged world never rewrites the context).
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

from livekit.agents import llm

import pair_key
from skills import world_state


def _run(coro):
    # Private loop, same pattern as test_app_control.py (leaves the global
    # loop untouched for legacy tests that still use it).
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


# --- fake Firestore (the test_app_control.py shape) -----------------------

class _Snap:
    def __init__(self, data):
        self._data = data
        self.exists = data is not None
        self.id = ""

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _Doc:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def collection(self, name):
        return _Col(self.store, (*self.key, name) if self.key else (name,))

    def get(self):
        return _Snap(self.store.get(self.key))

    def set(self, patch, merge=False):
        cur = self.store.get(self.key) if merge else None
        self.store[self.key] = {**(cur or {}), **patch}

    def delete(self):
        self.store.pop(self.key, None)


class _Col:
    def __init__(self, store, key):
        self.store, self.key = store, key
        self._filter = None

    def document(self, doc_id):
        return _Doc(self.store, (*self.key, doc_id))

    def where(self, field, op, value):
        self._filter = (field, op, value)
        return self

    def stream(self):
        seen = []
        d = len(self.key)
        for k in list(self.store):
            if len(k) == d + 1 and k[:d] == self.key:
                data = self.store[k] or {}
                if self._filter:
                    field, op, value = self._filter
                    actual = data.get(field)
                    if op == "array_contains":
                        if not isinstance(actual, list) or value not in actual:
                            continue
                    elif actual != value:
                        continue
                s = _Snap(data)
                s.id = k[-1]
                seen.append(s)
        return iter(seen)


class _Db:
    def __init__(self, store=None):
        self.store = {} if store is None else store

    def collection(self, name):
        return _Col(self.store, (name,))


# --- stub agent ------------------------------------------------------------

class _StubAgent:
    """The slice of ``livekit.agents.Agent`` the refresher touches:
    ``chat_ctx`` + ``update_chat_ctx``. ``say``/``generate_reply`` are
    tripwires — the refresher must never call them."""

    def __init__(self, items=()):
        self._ctx = llm.ChatContext(list(items))
        self.update_calls: list[llm.ChatContext] = []
        self.spoken: list = []

    @property
    def chat_ctx(self):
        return self._ctx

    async def update_chat_ctx(self, chat_ctx, **kwargs):
        self.update_calls.append(chat_ctx)
        self._ctx = chat_ctx

    def say(self, *args, **kwargs):  # pragma: no cover - tripwire
        self.spoken.append(("say", args))

    async def generate_reply(self, *args, **kwargs):  # pragma: no cover
        self.spoken.append(("generate_reply", args))


def _state_texts(agent: _StubAgent) -> list[str]:
    return [
        it.text_content for it in agent.chat_ctx.items
        if world_state.is_state_item(it)
    ]


def _now():
    return datetime.now(timezone.utc)


def _mirror(db: _Db, **fields):
    doc = {"updated_at": _now()}
    doc.update(fields)
    db.store[("users", "me", "voice_context", "current")] = doc


def _refresher(db: _Db, agent: _StubAgent) -> world_state.WorldStateRefresher:
    return world_state.WorldStateRefresher(
        db_factory=lambda: db, uid="me", get_agent=lambda: agent
    )


# --- (a) screen freshness ---------------------------------------------------

def test_context_reflects_new_screen_after_navigation_without_a_read_prompt():
    db = _Db()
    _mirror(db, screen="explore")
    user_item = llm.ChatMessage(role="user", content=["what am I looking at?"])
    agent = _StubAgent(items=[user_item])
    refresher = _refresher(db, agent)

    # First turn: the note lands in the context the answer is built from —
    # no current_screen tool call, no "read it" prompt anywhere.
    assert _run(refresher.refresh_once()) is True
    states = _state_texts(agent)
    assert len(states) == 1
    assert "Explore screen" in states[0]
    # The user's own turn survived the replacement untouched.
    assert user_item in list(agent.chat_ctx.items)

    # The user navigates (here: taps into Matches). Next turn's context
    # names the NEW screen and no longer carries the old one — the item
    # was replaced, not appended to.
    _mirror(db, screen="matches")
    assert _run(refresher.refresh_once()) is True
    states = _state_texts(agent)
    assert len(states) == 1
    assert "new matches" in states[0]
    assert "Explore screen" not in states[0]


def test_stale_mirror_removes_the_state_item():
    db = _Db()
    _mirror(db, screen="explore")
    agent = _StubAgent()
    refresher = _refresher(db, agent)
    assert _run(refresher.refresh_once()) is True
    assert len(_state_texts(agent)) == 1

    # The mirror ages past the freshness window (call over / app closed):
    # stale state must not stand — the item is removed, once.
    _mirror(db, screen="explore",
            updated_at=_now() - timedelta(seconds=3600))
    assert _run(refresher.refresh_once()) is True
    assert _state_texts(agent) == []
    assert _run(refresher.refresh_once()) is False


# --- (b) async completions ----------------------------------------------------

def test_sim_completion_lands_in_context_mid_conversation():
    db = _Db()
    sim_key = ("users", "me", "date_sims", "sim1")
    db.store[sim_key] = {
        "status": "running",
        "other_uid": "u-sofia",
        "persona": {"name": "Sofia Marino"},
        "created_at": _now() - timedelta(minutes=6),
    }
    agent = _StubAgent()
    refresher = _refresher(db, agent)

    assert _run(refresher.refresh_once()) is True
    assert "still running" in _state_texts(agent)[0]

    # The sim finishes while the call continues. The very next refresh —
    # i.e. the context her next answer is generated from — carries the
    # completed state, so she cannot say "let's see when it comes through"
    # about it.
    db.store[sim_key] = {
        **db.store[sim_key],
        "status": "done",
        "verdict": {
            "score": 92,
            "summary": "Easy banter, shared obsession with ceramics.",
        },
        "completed_at": _now(),
    }
    assert _run(refresher.refresh_once()) is True
    state = _state_texts(agent)[0]
    assert "FINISHED" in state
    assert "92/100" in state
    assert "match report" in state and "ready" in state
    assert "still running" not in state


def test_subject_match_report_ready_line_and_no_duplicate_with_sim():
    db = _Db()
    _mirror(db, screen="profile", subject_uid="u-sofia",
            subject_name="Sofia Marino")
    key = pair_key.sorted_pair_key("me", "u-sofia")
    db.store[("matches", key)] = {
        "score": 88,
        "structured_score": {"overall": 88},
        "method": "full_scorer",
        "names_in_narrative": True,
    }
    text = world_state.build_world_state_text(db, "me")
    assert text is not None
    assert "Match report for Sofia Marino: ready (score 88/100)" in text

    # A lite (score-only) doc is NOT a finished report — no ready line.
    db.store[("matches", key)] = {"score": 88}
    text = world_state.build_world_state_text(db, "me")
    assert text is None or "ready" not in text

    # When the finished-sim line already covers Sofia, the report line
    # does not repeat her.
    db.store[("matches", key)] = {
        "score": 88,
        "structured_score": {"overall": 88},
        "method": "full_scorer",
        "names_in_narrative": True,
    }
    db.store[("users", "me", "date_sims", "sim9")] = {
        "status": "done",
        "other_uid": "u-sofia",
        "persona": {"name": "Sofia Marino"},
        "verdict": {"score": 91, "summary": ""},
        "created_at": _now() - timedelta(minutes=3),
    }
    text = world_state.build_world_state_text(db, "me")
    assert text is not None
    assert "FINISHED" in text
    assert "Match report for Sofia Marino: ready" not in text


def test_old_finished_sim_ages_out_of_the_note():
    db = _Db()
    db.store[("users", "me", "date_sims", "sim-old")] = {
        "status": "done",
        "other_uid": "u-leo",
        "persona": {"name": "Leo Park"},
        "verdict": {"score": 40, "summary": ""},
        "created_at": _now() - timedelta(days=3),
    }
    assert world_state.build_world_state_text(db, "me") is None


# --- (c) silence + change gating ----------------------------------------------

def test_refresher_never_speaks_and_skips_unchanged_worlds():
    db = _Db()
    _mirror(db, screen="explore")
    agent = _StubAgent()
    refresher = _refresher(db, agent)

    assert _run(refresher.refresh_once()) is True
    # Unchanged world: no second context rewrite, however often we poke.
    assert _run(refresher.refresh_once()) is False
    assert _run(refresher.refresh_once()) is False
    assert len(agent.update_calls) == 1
    # The freshness mechanism itself emitted no speech of any kind.
    assert agent.spoken == []


def test_poke_applies_the_refresh_asynchronously():
    db = _Db()
    _mirror(db, screen="matches")
    agent = _StubAgent()
    refresher = _refresher(db, agent)

    async def _go():
        refresher.poke()
        refresher.poke()  # a burst coalesces; must not corrupt or duplicate
        for _ in range(50):
            if _state_texts(agent):
                break
            await asyncio.sleep(0.02)

    _run(_go())
    states = _state_texts(agent)
    assert len(states) == 1
    assert "new matches" in states[0]
    assert agent.spoken == []
