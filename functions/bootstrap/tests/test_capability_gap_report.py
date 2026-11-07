"""Capability-gap auto-report (founder rule, 2026-11-07).

When a user asks Ayma for something she cannot do because she lacks the
capability, she answers honestly AND silently files ONE report of the
gap — through the existing ``report_bug`` tool into ``bug_reports`` via
``bug_reports_ops`` (verified: ``report_bug`` is in ``skills._REGISTRY``,
always-on, bound in both ``make_session_tool_fns`` (text) and
``make_livekit_tools`` (voice); ``record_feedback`` is the wrong bucket —
it writes conversational-conduct feedback + a steering rule — and
``submit_feedback`` is text-only and drafts a card the user must send,
so it can never file silently).

Cases proved here:
(a) a capability-gap ask files exactly one report carrying the ask and
    the missing capability;
(b) prohibited asks (two of the six user-only exclusions) decline with
    zero reports;
(c) a doable ask is done by its own tool with zero reports;
(d) the same gap asked twice in one session files one report total.

Plus: the instruction is present in both the text and voice system
prompts, and a plain (non-gap) ``report_bug`` call is unchanged.
"""

from __future__ import annotations

import asyncio

import pytest

import bug_reports_ops
import capability_gap
import prompt as prompt_mod
import skills


@pytest.fixture(autouse=True)
def _clean_gap_state():
    capability_gap.reset_seen_for_tests()
    yield
    capability_gap.reset_seen_for_tests()


@pytest.fixture()
def recorded(monkeypatch):
    """Capture every bug_reports_ops.record call; return the call list."""
    calls = []

    def _record(db, uid, description, **kw):
        calls.append(
            {"uid": uid, "description": description, **kw}
        )
        return f"gap-{len(calls)}"

    monkeypatch.setattr(bug_reports_ops, "record", _record)
    return calls


def _fns(uid="u-cap", session_id="s-cap"):
    return skills.make_session_tool_fns(
        object(),
        uid,
        session_ctx={"session_id": session_id, "turn_index": 0, "turns": []},
    )


_GAP = (
    "Capability gap: user asked me to turn off my smart lights; "
    "missing capability: smart-home device control"
)


# --- (a) capability-gap ask -> exactly one report -------------------------

def test_gap_ask_files_exactly_one_report_with_ask_and_capability(recorded):
    fn = _fns()["report_bug"]
    out = fn(_GAP)
    assert out == "logged (gap-1)"
    assert len(recorded) == 1
    assert recorded[0]["uid"] == "u-cap"
    assert "turn off my smart lights" in recorded[0]["description"]
    assert "smart-home device control" in recorded[0]["description"]


# --- (b) prohibited asks -> decline, zero reports -------------------------

@pytest.mark.parametrize(
    "description",
    [
        # Exclusion 1: Delete account.
        "Capability gap: user asked me to delete my account; "
        "missing capability: deleting accounts",
        # Exclusion 2: Subscribe / any purchase.
        "Capability gap: user asked me to subscribe them to Premium; "
        "missing capability: subscriptions",
    ],
)
def test_prohibited_ask_files_no_report(recorded, description):
    fn = _fns()["report_bug"]
    out = fn(description)
    assert out.startswith("not filed")
    assert recorded == []


# --- (c) doable ask -> done, zero reports ---------------------------------

# Minimal Firestore fake with a healthy client that acks app commands
# immediately — the same pattern as tests/test_app_control.py.

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

    def document(self, doc_id=None):
        return _Doc(self.store, (*self.key, doc_id) if doc_id else self.key)


class _Db:
    def __init__(self, store=None):
        self.store = {} if store is None else store

    def collection(self, name):
        return _Col(self.store, (name,))


_PENDING = ("users", "u-cap", "app_commands", "pending")
_ACK = ("users", "u-cap", "app_commands", "ack")


class _AckStore(dict):
    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if key == _PENDING and isinstance(value, dict) and value.get("id"):
            super().__setitem__(_ACK, {"id": value["id"], "ok": True})


def _run(coro):
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def test_doable_ask_is_done_with_zero_reports(recorded):
    db = _Db(_AckStore())
    fns = skills.make_session_tool_fns(
        db,
        "u-cap",
        session_ctx={"session_id": "s-cap", "turn_index": 0, "turns": []},
    )
    out = _run(fns["open_screen"]("matches"))
    assert "navigated" in out
    assert recorded == []


# --- (d) same gap twice in one session -> one report -----------------------

def test_same_gap_twice_in_one_session_files_once(recorded):
    fn = _fns()["report_bug"]
    assert fn(_GAP) == "logged (gap-1)"
    second = fn(_GAP)
    assert "already filed" in second
    assert len(recorded) == 1


def test_rephrased_gap_in_one_session_files_once(recorded):
    fn = _fns()["report_bug"]
    assert fn(_GAP) == "logged (gap-1)"
    rephrased = (
        "Capability gap: user asked me to turn off my smart lights; "
        "missing capability: controlling smart-home devices"
    )
    assert "already filed" in fn(rephrased)
    assert len(recorded) == 1


def test_same_gap_in_a_new_session_files_again(recorded):
    assert _fns(session_id="s-one")["report_bug"](_GAP) == "logged (gap-1)"
    assert _fns(session_id="s-two")["report_bug"](_GAP) == "logged (gap-2)"
    assert len(recorded) == 2


# --- the instruction reaches both surfaces ---------------------------------

@pytest.mark.parametrize("variant", ["text", "voice"])
def test_instruction_present_in_both_system_prompts(variant):
    text = prompt_mod.compose_system_prompt(variant=variant)
    assert "Capability gaps — report them yourself" in text
    assert "Capability gap:" in text
    assert "report_bug" in text
    # The hard exceptions ride along, not just the filing rule.
    assert "must refuse anyway" in text
    assert "clarifying question" in text
    assert "One report per distinct missing capability" in text


def test_report_bug_still_always_on_and_in_voice():
    base = {d["name"] for d in skills.session_tool_declarations()}
    assert "report_bug" in base
    try:
        tools = skills.make_livekit_tools(object(), "u1", session_id="s-v")
    except ModuleNotFoundError:
        return  # livekit-agents only present in the voice venv
    names = {getattr(t, "name", getattr(t, "__name__", "")) for t in tools}
    assert "report_bug" in names


# --- regression: a plain bug report is unchanged ---------------------------

def test_plain_bug_report_still_files_normally(recorded):
    fn = _fns()["report_bug"]
    out = fn("the app crashed when I opened my profile")
    assert out == "logged (gap-1)"
    assert len(recorded) == 1
    assert recorded[0]["image_path"] == ""
