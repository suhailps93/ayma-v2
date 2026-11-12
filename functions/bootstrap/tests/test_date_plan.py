"""Plan-a-date (payment-free): propose, approve, both-approved, suggest."""
import pytest

import date_plan
import dm_ops
from tests.test_dm_ops import FakeDb

PLACE = dict(place_name="Sakura Sushi", address="1 Main St, San Jose",
             lat=37.3382, lng=-121.8863, time_label="Friday at 8:00 PM",
             starts_at="2026-11-13T20:00:00+00:00")


def _card(db, proposer="a", parts=("a", "b")):
    plan = date_plan.propose_plan(proposer_uid=proposer, **PLACE)
    mid = date_plan.post_date_plan_message(db, "a__b", list(parts), plan)
    return mid, plan


def test_propose_requires_a_locatable_place():
    with pytest.raises(ValueError):
        date_plan.propose_plan(place_name="", address="x")
    with pytest.raises(ValueError):
        date_plan.propose_plan(place_name="Nowhere")  # no address, no coords
    # An address alone is locatable.
    plan = date_plan.propose_plan(place_name="Cafe", address="2 Oak Ave")
    assert plan["status"] == "proposed"
    assert plan["lat"] is None and plan["lng"] is None
    assert plan["approvals"] == {}
    assert plan["moment_fired"] is False


def test_propose_keeps_place_time_and_anchor():
    plan = date_plan.propose_plan(proposer_uid="a", **PLACE)
    assert plan["place_name"] == "Sakura Sushi"
    assert plan["address"] == "1 Main St, San Jose"
    assert plan["lat"] == 37.3382 and plan["lng"] == -121.8863
    assert "8:00 PM" in plan["time_label"]
    assert plan["proposer_uid"] == "a"
    # No payment fields leak into the payment-free model.
    for banned in ("total_cents", "half_cents", "payments", "reservation"):
        assert banned not in plan


def test_card_is_posted_as_ayma_message_in_thread():
    db = FakeDb()
    dm_ops.post_message(db, "a", "b", "text", "hi")
    mid, _ = _card(db)
    msg = db.docs[("dm_threads", "a__b", "messages", mid)]
    assert msg["type"] == "date_plan"
    assert msg["sender_uid"] == "ayma"
    assert msg["date_plan"]["place_name"] == "Sakura Sushi"


def test_both_approvals_reach_both_approved():
    db = FakeDb()
    mid, _ = _card(db)
    after_one = date_plan.approve(db, "a__b", mid, "a")
    assert after_one["status"] == "partially_approved"
    assert after_one["approvals"] == {"a": True}
    after_both = date_plan.approve(db, "a__b", mid, "b")
    assert after_both["status"] == "both_approved"
    assert after_both["approvals"] == {"a": True, "b": True}


def test_approve_is_idempotent_once_both_approved():
    db = FakeDb()
    mid, _ = _card(db)
    date_plan.approve(db, "a__b", mid, "a")
    date_plan.approve(db, "a__b", mid, "b")
    again = date_plan.approve(db, "a__b", mid, "a")
    assert again["status"] == "both_approved"


def test_non_participant_cannot_approve():
    db = FakeDb()
    mid, _ = _card(db)
    with pytest.raises(PermissionError):
        date_plan.approve(db, "a__b", mid, "stranger")


def test_suggestion_revises_and_resets_approvals():
    db = FakeDb()
    mid, _ = _card(db)
    date_plan.approve(db, "a__b", mid, "a")
    revised = date_plan.suggest_change(
        db, "a__b", mid, "b", place_name="Blue Door Coffee",
        address="9 Market St", lat=37.3, lng=-121.9,
        time_label="Saturday at 2:00 PM", starts_at="2026-11-14T14:00:00+00:00",
        note="can we do coffee instead?")
    assert revised["revision"] == 2
    assert revised["status"] == "proposed"
    assert revised["approvals"] == {}
    assert revised["place_name"] == "Blue Door Coffee"
    assert revised["suggestions"][0]["note"].startswith("can we do")


def test_suggestion_overrides_only_given_fields():
    db = FakeDb()
    mid, _ = _card(db)
    revised = date_plan.suggest_change(
        db, "a__b", mid, "a", time_label="Friday at 9:00 PM",
        starts_at="2026-11-13T21:00:00+00:00")
    assert revised["place_name"] == "Sakura Sushi"  # carried over
    assert revised["time_label"] == "Friday at 9:00 PM"
    assert revised["approvals"] == {}


def _active(db, uid):
    return db.docs.get(("users", uid, "active_date_plans", "a__b"))


def test_both_approved_writes_active_pointer_for_each_person():
    db = FakeDb()
    mid, _ = _card(db)
    date_plan.approve(db, "a__b", mid, "a")
    assert _active(db, "a") is None  # not yet both-approved
    date_plan.approve(db, "a__b", mid, "b")
    for uid in ("a", "b"):
        ptr = _active(db, uid)
        assert ptr is not None
        assert ptr["message_id"] == mid
        assert ptr["lat"] == 37.3382 and ptr["lng"] == -121.8863
        assert ptr["place_name"] == "Sakura Sushi"


def test_suggestion_clears_active_pointer():
    db = FakeDb()
    mid, _ = _card(db)
    date_plan.approve(db, "a__b", mid, "a")
    date_plan.approve(db, "a__b", mid, "b")
    assert _active(db, "a") is not None
    date_plan.suggest_change(db, "a__b", mid, "b", time_label="later")
    assert _active(db, "a") is None and _active(db, "b") is None
