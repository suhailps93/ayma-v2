import asyncio

import appearance
import token_ledger
from skills import make_session_tool_fns, session_tool_declarations


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def test_appearance_edit_tools_only_exposed_with_appearance_flag():
    base = {d["name"] for d in session_tool_declarations()}
    withapp = {d["name"] for d in session_tool_declarations(appearance=True)}
    added = withapp - base
    assert added == {"correct_appearance_item", "clear_appearance_item"}


def _bound(name, *, finding_id):
    ctx = {"finding_id": finding_id}
    return make_session_tool_fns(object(), "u1", appearance_ctx=ctx)[name]


# --- correct_appearance_item ---------------------------------------------------


def test_correct_appearance_item_calls_through(monkeypatch):
    calls = {}

    async def _correct(db, uid, finding_id, message):
        calls.update(uid=uid, finding_id=finding_id, message=message)
        return {"ok": True, "reply": "got it, updated your eye color"}

    monkeypatch.setattr(appearance, "correct_finding", _correct)
    fn = _bound("correct_appearance_item", finding_id="eye_color")
    assert _run(fn(feedback="my eyes are blue")) == "got it, updated your eye color"
    assert calls == {"uid": "u1", "finding_id": "eye_color", "message": "my eyes are blue"}


def test_correct_appearance_item_needs_focus():
    fn = _bound("correct_appearance_item", finding_id="")
    assert "no finding" in _run(fn(feedback="whatever"))


def test_correct_appearance_item_needs_feedback():
    fn = _bound("correct_appearance_item", finding_id="eye_color")
    assert "wrong" in _run(fn(feedback="   "))


def test_correct_appearance_item_unknown_finding(monkeypatch):
    async def _correct(*a, **k):
        raise KeyError("shoe_size")

    monkeypatch.setattr(appearance, "correct_finding", _correct)
    fn = _bound("correct_appearance_item", finding_id="shoe_size")
    assert "isn't on your report" in _run(fn(feedback="size 10"))


def test_correct_appearance_item_invalid_value_reply(monkeypatch):
    async def _correct(*a, **k):
        return {"ok": False, "reply": "that didn't look like a real color"}

    monkeypatch.setattr(appearance, "correct_finding", _correct)
    fn = _bound("correct_appearance_item", finding_id="eye_color")
    assert _run(fn(feedback="it's plaid")) == "that didn't look like a real color"


def test_correct_appearance_item_usage_capped(monkeypatch):
    async def _correct(*a, **k):
        raise token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(appearance, "correct_finding", _correct)
    fn = _bound("correct_appearance_item", finding_id="eye_color")
    # Routes through the shared out-of-credits copy (token_ledger.py) rather
    # than a hand-typed string, worded for this specific action.
    assert _run(fn(feedback="it's blue")) == token_ledger.out_of_credits_message(
        token_ledger.CONTEXT_CORRECTION
    )


# --- clear_appearance_item ------------------------------------------------------


def test_clear_appearance_item_calls_through(monkeypatch):
    calls = {}

    async def _clear(db, uid, finding_id):
        calls.update(uid=uid, finding_id=finding_id)
        return {"ok": True, "finding_id": finding_id}

    monkeypatch.setattr(appearance, "clear_finding", _clear)
    fn = _bound("clear_appearance_item", finding_id="eye_color")
    out = _run(fn())
    assert "cleared" in out
    assert calls == {"uid": "u1", "finding_id": "eye_color"}


def test_clear_appearance_item_needs_focus():
    fn = _bound("clear_appearance_item", finding_id="")
    assert "no finding" in _run(fn())


def test_clear_appearance_item_rejects_face_and_body():
    fn_face = _bound("clear_appearance_item", finding_id="face")
    fn_body = _bound("clear_appearance_item", finding_id="body")
    assert "can't be cleared" in _run(fn_face())
    assert "can't be cleared" in _run(fn_body())


def test_clear_appearance_item_unknown_finding(monkeypatch):
    async def _clear(*a, **k):
        raise KeyError("shoe_size")

    monkeypatch.setattr(appearance, "clear_finding", _clear)
    fn = _bound("clear_appearance_item", finding_id="shoe_size")
    assert "isn't on your report" in _run(fn())
