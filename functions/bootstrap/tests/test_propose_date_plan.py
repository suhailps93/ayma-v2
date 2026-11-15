"""``propose_date_plan`` — the chat/voice trigger for the date-plan card.

Founder feedback zVnQBIG0HGvSpx8Egwei (2026-11-14): asking Ayma in chat
to plan a date never produced a card, because the brain had no date-plan
tool — the only card-posting path was the DM thread attach sheet. These
tests pin the fix: a chat ask posts the SAME card the attach sheet posts
(same write path as ``POST /dm/{thread_id}/date-plan/propose``), into the
caller's own thread only, and every failure mode says so plainly with no
card claimed.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone

import pytest

import date_plan
import places_client
from skills import propose_date_plan as pdp
from tests.fake_firestore import FakeDb

_ME = "me"
_SOFIA = "u-sofia"
_THREAD = "me__u-sofia"  # sorted_pair_key(_ME, _SOFIA)


def _run(coro):
    # Private loop, like tests/test_app_control.py: asyncio.run() unsets
    # the global loop other test files still rely on.
    loop = asyncio.new_event_loop()
    try:
        return loop.run_until_complete(coro)
    finally:
        loop.close()


def _seeded_db(with_thread=True) -> FakeDb:
    seed = {
        ("users", _ME, "profile", "main"): {"name": "Me"},
        ("users", _SOFIA, "profile", "main"): {"name": "Sofia Marino"},
    }
    if with_thread:
        seed[("dm_threads", _THREAD)] = {
            "participants": [_ME, _SOFIA],
            "last_message_at": datetime(2026, 11, 14, 12, 0,
                                        tzinfo=timezone.utc),
            "unread": {},
        }
    return FakeDb(seed)


def _resolve_ok(monkeypatch):
    monkeypatch.setattr(
        places_client, "resolve_place",
        lambda q: {"place_name": q, "place_kind": "restaurant",
                   "lat": 37.3382, "lng": -121.8863})


def _cards(db) -> list[dict]:
    return [doc for key, doc in db.docs.items()
            if key[:3] == ("dm_threads", _THREAD, "messages")
            and doc.get("type") == "date_plan"]


def _ask(db, **kw):
    return _run(pdp.SKILL.bind(db, _ME)(**kw))


def test_chat_ask_posts_the_card_in_the_thread(monkeypatch):
    _resolve_ok(monkeypatch)
    db = _seeded_db()
    out = _ask(db, person="Sofia", place_name="Sakura Sushi",
               time_label="Friday at 8 PM",
               starts_at="2026-11-20T20:00:00-08:00")
    assert out.startswith(pdp.SUCCESS_PREFIX)
    assert "Sofia Marino" in out
    cards = _cards(db)
    assert len(cards) == 1
    card = cards[0]
    # The identical shape the attach sheet's endpoint posts: an Ayma
    # message carrying the plan, in the pair's own thread.
    assert card["sender_uid"] == "ayma"
    assert card["participants"] == [_ME, _SOFIA]
    plan = card["date_plan"]
    assert plan["place_name"] == "Sakura Sushi"
    assert plan["status"] == "proposed"
    assert plan["proposer_uid"] == _ME
    assert plan["lat"] == 37.3382 and plan["lng"] == -121.8863
    assert plan["place_kind"] == "restaurant"
    assert "8 PM" in plan["time_label"]


def test_no_dm_thread_context_fails_honestly(monkeypatch):
    # The person exists, but the caller has no conversation with them:
    # there is nowhere honest to put the card, so none is posted and the
    # reply says so instead of describing a plan that never appears.
    _resolve_ok(monkeypatch)
    db = _seeded_db(with_thread=False)
    out = _ask(db, person="Sofia", place_name="Sakura Sushi",
               time_label="Friday at 8 PM")
    assert not out.startswith(pdp.SUCCESS_PREFIX)
    assert "no existing" in out and "conversation" in out
    assert _cards(db) == []
    assert not any(k[0] == "dm_threads" for k in db.docs)


def test_unknown_person_fails_honestly(monkeypatch):
    _resolve_ok(monkeypatch)
    db = _seeded_db()
    out = _ask(db, person="Nobody", place_name="Sakura Sushi")
    assert not out.startswith(pdp.SUCCESS_PREFIX)
    assert _cards(db) == []


def test_no_person_named_asks_who(monkeypatch):
    _resolve_ok(monkeypatch)
    db = _seeded_db()
    out = _ask(db, person="", place_name="Sakura Sushi")
    assert "Who" in out and "date with" in out
    assert _cards(db) == []


def test_no_place_named_asks_where(monkeypatch):
    _resolve_ok(monkeypatch)
    db = _seeded_db()
    out = _ask(db, person="Sofia", place_name="")
    assert "Where" in out
    assert _cards(db) == []


def test_ambiguous_name_asks_which_and_posts_nothing(monkeypatch):
    _resolve_ok(monkeypatch)
    db = _seeded_db()
    db.docs[("users", "u-sofia2", "profile", "main")] = {
        "name": "Sofia Reyes"}
    db.docs[("dm_threads", "me__u-sofia2")] = {
        "participants": [_ME, "u-sofia2"],
        "last_message_at": datetime(2026, 11, 14, 12, 0,
                                    tzinfo=timezone.utc),
        "unread": {},
    }
    out = _ask(db, person="Sofia", place_name="Sakura Sushi")
    assert "more than one conversation" in out
    assert _cards(db) == []
    assert not any(k[0] == "dm_threads" and k[2] == "messages"
                   for k in db.docs if len(k) > 2)


def test_unlocatable_place_fails_honestly(monkeypatch):
    # Places lookup fails closed (returns None) and no address was
    # given: no card, and the reply names the problem plainly.
    monkeypatch.setattr(places_client, "resolve_place", lambda q: None)
    db = _seeded_db()
    out = _ask(db, person="Sofia", place_name="Somewhere Obscure",
               time_label="Friday at 8 PM")
    assert not out.startswith(pdp.SUCCESS_PREFIX)
    assert "pin down" in out
    assert _cards(db) == []


def test_address_alone_makes_the_place_locatable(monkeypatch):
    monkeypatch.setattr(places_client, "resolve_place", lambda q: None)
    db = _seeded_db()
    out = _ask(db, person="Sofia", place_name="Sakura Sushi",
               address="1 Main St, San Jose",
               time_label="Friday at 8 PM")
    assert out.startswith(pdp.SUCCESS_PREFIX)
    plan = _cards(db)[0]["date_plan"]
    assert plan["address"] == "1 Main St, San Jose"
    assert plan["lat"] is None and plan["lng"] is None


def test_past_time_is_refused_and_no_card_posted(monkeypatch):
    # The past-time guard lives in date_plan.propose_plan
    # (fleet/date-plan-past-time): it raises ValueError with the
    # user-ready line. The tool's contract is to relay that reason
    # plainly and post nothing — simulated here at the guard's seam.
    _resolve_ok(monkeypatch)

    def _guard(*a, **kw):
        raise ValueError(
            "That time has already passed. Pick a time in the future.")

    monkeypatch.setattr(date_plan, "propose_plan", _guard)
    db = _seeded_db()
    out = _ask(db, person="Sofia", place_name="Sakura Sushi",
               time_label="Yesterday at 8 PM",
               starts_at="2026-11-13T20:00:00-08:00")
    assert not out.startswith(pdp.SUCCESS_PREFIX)
    assert "already passed" in out
    assert _cards(db) == []


def test_card_lands_only_in_the_callers_own_thread(monkeypatch):
    # Self-only: the caller is always a participant of the thread the
    # card lands in — there is no way to name a pair the caller isn't in.
    _resolve_ok(monkeypatch)
    db = _seeded_db()
    _ask(db, person="Sofia", place_name="Sakura Sushi",
         time_label="Friday at 8 PM")
    message_threads = {k[1] for k in db.docs
                       if k[0] == "dm_threads" and len(k) > 2}
    assert message_threads == {_THREAD}
    assert _cards(db)[0]["participants"] == sorted((_ME, _SOFIA))


def test_past_time_label_only_is_refused_and_no_card_posted(monkeypatch):
    # Scout NOTE 214 Defect B (the real repro): the model posts only a human
    # time_label and leaves starts_at EMPTY — which is why the 2438
    # starts_at-only guard never fired and a "yesterday at 7pm" card went live.
    # This drives the REAL guard (no stub): it resolves the label and refuses.
    _resolve_ok(monkeypatch)
    db = _seeded_db()
    out = _ask(db, person="Sofia", place_name="Blue Bottle Coffee",
               time_label="yesterday at 7pm", starts_at="")
    assert not out.startswith(pdp.SUCCESS_PREFIX)
    assert "That time has already passed. Pick a time in the future." in out
    assert _cards(db) == []  # nothing written to the thread


def test_future_time_label_only_still_posts(monkeypatch):
    # The guard must not over-refuse: a valid future plan with only a
    # time_label (no starts_at) still posts normally.
    _resolve_ok(monkeypatch)
    db = _seeded_db()
    out = _ask(db, person="Sofia", place_name="Blue Bottle Coffee",
               time_label="tomorrow at 7pm", starts_at="")
    assert out.startswith(pdp.SUCCESS_PREFIX)
    assert len(_cards(db)) == 1
