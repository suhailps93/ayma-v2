"""Plan-a-date: trigger, planning, approvals, split pay, confirmation."""
from datetime import datetime, timezone

import pytest

import date_plan
import dm_ops
from paypal_client import StubPayPalClient
from tests.test_dm_ops import FakeDb

NOW = datetime(2026, 11, 7, 12, 0, tzinfo=timezone.utc)  # a Saturday


def _card(db, texts=("hi", "i love sushi", "friday at 8pm sounds good")):
    plan = date_plan.propose_plan(list(texts), now=NOW)
    mid = date_plan.post_date_plan_message(db, "a__b", ["a", "b"], plan)
    return mid, plan


def test_trigger_detection():
    assert date_plan.is_plan_trigger("@ayma plan a date")
    assert date_plan.is_plan_trigger("hey @Ayma, plan our date please")
    assert not date_plan.is_plan_trigger("plan a date sometime")
    assert not date_plan.is_plan_trigger("@ayma say hi")


def test_propose_reads_thread_for_food_and_time():
    plan = date_plan.propose_plan(
        ["we should get sushi", "friday at 8pm works"], now=NOW)
    assert plan["place_name"] == "Sakura Sushi"
    assert plan["total_cents"] == 5600
    assert plan["half_cents"] == 2800
    assert "Friday" in plan["time_label"]
    assert "8:00 PM" in plan["time_label"]
    assert plan["status"] == "proposed"
    assert plan["approvals"] == {}


def test_propose_default_when_thread_says_nothing():
    plan = date_plan.propose_plan(["hello"], now=NOW)
    assert plan["place_name"] == "The Garden Kitchen"
    assert "Saturday" in plan["time_label"]


def test_card_is_posted_as_ayma_message_in_thread():
    db = FakeDb()
    dm_ops.post_message(db, "a", "b", "text", "hi")
    mid, _ = _card(db)
    msg = db.docs[("dm_threads", "a__b", "messages", mid)]
    assert msg["type"] == "date_plan"
    assert msg["sender_uid"] == "ayma"
    assert msg["date_plan"]["place_name"] == "Sakura Sushi"


def test_both_approvals_create_two_half_orders():
    db = FakeDb()
    mid, plan = _card(db)
    client = StubPayPalClient()
    after_one = date_plan.approve(db, "a__b", mid, "a", client)
    assert after_one["status"] == "partially_approved"
    assert after_one["payments"] == {}
    after_both = date_plan.approve(db, "a__b", mid, "b", client)
    assert after_both["status"] == "paying"
    payments = after_both["payments"]
    assert set(payments) == {"a", "b"}
    assert sum(p["amount_cents"] for p in payments.values()) == 5600
    assert all(p["status"] == "pending" for p in payments.values())
    assert after_both["paypal_stubbed"] is True


def test_non_participant_cannot_approve():
    db = FakeDb()
    mid, _ = _card(db)
    with pytest.raises(PermissionError):
        date_plan.approve(db, "a__b", mid, "stranger", StubPayPalClient())


def test_suggestion_revises_and_resets_approvals():
    db = FakeDb()
    mid, _ = _card(db)
    date_plan.approve(db, "a__b", mid, "a", StubPayPalClient())
    revised = date_plan.suggest_change(
        db, "a__b", mid, "b", "can we do something cheaper on saturday?",
        now=NOW)
    assert revised["revision"] == 2
    assert revised["status"] == "proposed"
    assert revised["approvals"] == {}
    assert revised["payments"] == {}
    assert revised["total_cents"] < 5600
    assert revised["suggestions"][0]["text"].startswith("can we do")


def test_both_halves_paid_confirms_reservation_and_booking():
    db = FakeDb()
    mid, _ = _card(db)
    client = StubPayPalClient()
    date_plan.approve(db, "a__b", mid, "a", client)
    date_plan.approve(db, "a__b", mid, "b", client)
    after_one = date_plan.pay_half(db, "a__b", mid, "a", client)
    assert after_one["status"] == "paying"
    assert after_one["reservation"] == {}
    done = date_plan.pay_half(db, "a__b", mid, "b", client)
    assert done["status"] == "confirmed"
    confirmation = done["reservation"]["confirmation_number"]
    assert confirmation.startswith("AYMA-")
    booking = db.docs[("date_bookings", confirmation)]
    assert booking["place_name"] == "Sakura Sushi"
    assert booking["booked_for"] == ["a", "b"]
    assert all(p["status"] == "paid" for p in done["payments"].values())


def test_pay_before_both_approve_is_rejected():
    db = FakeDb()
    mid, _ = _card(db)
    date_plan.approve(db, "a__b", mid, "a", StubPayPalClient())
    with pytest.raises(ValueError):
        date_plan.pay_half(db, "a__b", mid, "a", StubPayPalClient())


def test_confirmed_plan_cannot_change():
    db = FakeDb()
    mid, _ = _card(db)
    client = StubPayPalClient()
    date_plan.approve(db, "a__b", mid, "a", client)
    date_plan.approve(db, "a__b", mid, "b", client)
    date_plan.pay_half(db, "a__b", mid, "a", client)
    date_plan.pay_half(db, "a__b", mid, "b", client)
    with pytest.raises(ValueError):
        date_plan.suggest_change(db, "a__b", mid, "a", "actually saturday")
