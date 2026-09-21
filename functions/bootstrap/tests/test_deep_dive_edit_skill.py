import asyncio

import deep_dive
import pytest
import token_ledger
from skills import make_session_tool_fns, session_tool_declarations


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def test_deep_dive_edit_tools_only_exposed_with_deep_dive_flag():
    base = {d["name"] for d in session_tool_declarations()}
    withdd = {d["name"] for d in session_tool_declarations(deep_dive=True)}
    added = withdd - base
    assert added == {"correct_deep_dive_item", "remove_deep_dive_item"}


def _bound(name, *, report_id, target):
    ctx = {"report_id": report_id, "target": target}
    return make_session_tool_fns(object(), "u1", deep_dive_ctx=ctx)[name]


# --- correct_deep_dive_item ---------------------------------------------------


def test_correct_deep_dive_item_calls_through_with_report_id_and_target(monkeypatch):
    calls = {}

    async def _correct(db, uid, report_id, *, target, feedback):
        calls.update(uid=uid, report_id=report_id, target=target, feedback=feedback)
        return {"reply": "updated that claim"}

    monkeypatch.setattr(deep_dive, "correct_finding", _correct)
    fn = _bound("correct_deep_dive_item", report_id="r1", target="fact:aaa111")
    assert _run(fn(feedback="not mine, revise it")) == "updated that claim"
    assert calls == {
        "uid": "u1", "report_id": "r1", "target": "fact:aaa111",
        "feedback": "not mine, revise it",
    }


def test_correct_deep_dive_item_needs_focus():
    fn = _bound("correct_deep_dive_item", report_id="", target="")
    assert "no finding" in _run(fn(feedback="whatever"))


def test_correct_deep_dive_item_needs_feedback():
    fn = _bound("correct_deep_dive_item", report_id="r1", target="summary")
    assert "wrong" in _run(fn(feedback="  "))


def test_correct_deep_dive_item_reports_missing_finding(monkeypatch):
    async def _correct(*a, **k):
        return None

    monkeypatch.setattr(deep_dive, "correct_finding", _correct)
    fn = _bound("correct_deep_dive_item", report_id="r1", target="fact:gone")
    assert "gone" in _run(fn(feedback="fix this"))


def test_correct_deep_dive_item_permission_error(monkeypatch):
    async def _correct(*a, **k):
        raise PermissionError("nope")

    monkeypatch.setattr(deep_dive, "correct_finding", _correct)
    fn = _bound("correct_deep_dive_item", report_id="r1", target="summary")
    assert "own report" in _run(fn(feedback="fix this"))


def test_correct_deep_dive_item_usage_capped(monkeypatch):
    async def _correct(*a, **k):
        raise token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(deep_dive, "correct_finding", _correct)
    fn = _bound("correct_deep_dive_item", report_id="r1", target="summary")
    assert "credits" in _run(fn(feedback="fix this"))


# --- remove_deep_dive_item -----------------------------------------------------


def test_remove_deep_dive_item_fact_calls_dispute_fact(monkeypatch):
    calls = {}

    def _dispute(db, uid, report_id, target_fact_id):
        calls.update(uid=uid, report_id=report_id, target_fact_id=target_fact_id)
        return {"digest": {}}

    monkeypatch.setattr(deep_dive, "dispute_fact", _dispute)
    fn = _bound("remove_deep_dive_item", report_id="r1", target="fact:aaa111")
    out = fn()
    assert "off your report" in out
    assert calls == {"uid": "u1", "report_id": "r1", "target_fact_id": "aaa111"}


def test_remove_deep_dive_item_social_calls_dispute_social_link(monkeypatch):
    calls = {}

    def _dispute(db, uid, report_id, url):
        calls.update(uid=uid, report_id=report_id, url=url)
        return {"digest": {}}

    monkeypatch.setattr(deep_dive, "dispute_social_link", _dispute)
    fn = _bound(
        "remove_deep_dive_item", report_id="r1",
        target="social:https://instagram.com/dana",
    )
    out = fn()
    assert "off your report" in out
    assert calls == {
        "uid": "u1", "report_id": "r1", "url": "https://instagram.com/dana",
    }


def test_remove_deep_dive_item_photo_calls_dispute_web_image(monkeypatch):
    calls = {}

    def _dispute(db, uid, report_id, url):
        calls.update(uid=uid, report_id=report_id, url=url)
        return {"digest": {}}

    monkeypatch.setattr(deep_dive, "dispute_web_image", _dispute)
    fn = _bound(
        "remove_deep_dive_item", report_id="r1",
        target="photo:https://example.com/a.jpg",
    )
    out = fn()
    assert "off your report" in out
    assert calls == {
        "uid": "u1", "report_id": "r1", "url": "https://example.com/a.jpg",
    }


def test_remove_deep_dive_item_summary_cannot_be_removed():
    fn = _bound("remove_deep_dive_item", report_id="r1", target="summary")
    out = fn()
    assert "can't be deleted" in out


def test_remove_deep_dive_item_needs_focus():
    fn = _bound("remove_deep_dive_item", report_id="", target="")
    assert "no finding" in fn()


def test_remove_deep_dive_item_reports_missing_finding(monkeypatch):
    monkeypatch.setattr(deep_dive, "dispute_fact", lambda *a, **k: None)
    fn = _bound("remove_deep_dive_item", report_id="r1", target="fact:gone")
    assert "gone" in fn()


def test_remove_deep_dive_item_permission_error(monkeypatch):
    def _boom(*a, **k):
        raise PermissionError("nope")

    monkeypatch.setattr(deep_dive, "dispute_fact", _boom)
    fn = _bound("remove_deep_dive_item", report_id="r1", target="fact:aaa111")
    assert "own report" in fn()
