"""Proactive routine outreach: matches a learned routine, caps, templates."""
from datetime import datetime, timezone

import proactive
from tests.test_location_log import FakeDb, _enable_log
import location_log


def _seed_routine(db, uid, kind="trailhead"):
    # Three Sunday-morning visits -> both a "Sunday <activity>" and a
    # "morning <activity>" routine.
    for d in (1, 8, 15):
        location_log.log_visit(
            db, uid, 37.0, -121.0,
            timestamp=datetime(2026, 11, d, 9, 0, tzinfo=timezone.utc),
            classifier=lambda *a, k=kind: {"place_kind": k})


def test_matching_routine_pure():
    patterns = [{"label": "morning walks", "place_kind": "park", "count": 3}]
    sunday_morning = datetime(2026, 11, 15, 9, 0, tzinfo=timezone.utc)
    assert proactive.matching_routine(patterns, "park", sunday_morning) \
        == "morning walks"
    # Wrong kind -> no match.
    assert proactive.matching_routine(patterns, "bar", sunday_morning) is None
    # Wrong time of day -> no match.
    evening = datetime(2026, 11, 15, 20, 0, tzinfo=timezone.utc)
    assert proactive.matching_routine(patterns, "park", evening) is None


def test_compose_is_template_with_place():
    msg = proactive.compose_routine_message("morning walks", "Alum Rock Park")
    assert "morning walks" in msg
    assert "Alum Rock Park" in msg


def test_fire_posts_chat_and_caps_once_per_day():
    db = FakeDb()
    _enable_log(db, "u1")
    _seed_routine(db, "u1")
    sunday_morning = datetime(2026, 11, 22, 9, 0, tzinfo=timezone.utc)
    text = proactive.maybe_fire_routine(
        db, "u1", "trailhead", "Mission Peak", now=sunday_morning)
    assert text and "Mission Peak" in text
    # The in-app chat message was posted.
    chat = [k for k in db.docs if k[:3] == ("users", "u1", "chat_messages")]
    assert chat
    # Same routine again the same day -> capped, no second send.
    again = proactive.maybe_fire_routine(
        db, "u1", "trailhead", "Mission Peak", now=sunday_morning)
    assert again is None


def test_fire_none_when_no_routine_match():
    db = FakeDb()
    _enable_log(db, "u1")
    _seed_routine(db, "u1")
    # A place kind the user has no routine for.
    assert proactive.maybe_fire_routine(
        db, "u1", "gym", "Gold's",
        now=datetime(2026, 11, 22, 9, 0, tzinfo=timezone.utc)) is None


def test_daily_total_cap():
    db = FakeDb()
    _enable_log(db, "u1")
    # Seed several distinct routines (morning walk, Sunday walk, evening drinks,
    # Friday drinks, afternoon coffee, Saturday coffee ...).
    for kind in ("trailhead", "bar", "cafe", "park"):
        for d in (1, 8, 15):
            location_log.log_visit(
                db, "u1", 37.0, -121.0,
                timestamp=datetime(2026, 11, d, 9, 0, tzinfo=timezone.utc),
                classifier=lambda *a, k=kind: {"place_kind": k})
    now = datetime(2026, 11, 22, 9, 0, tzinfo=timezone.utc)
    sent = 0
    for kind in ("trailhead", "cafe", "park"):
        # Each distinct routine can send once, but the daily total caps it.
        if proactive.maybe_fire_routine(db, "u1", kind, "", now=now):
            sent += 1
    assert sent <= proactive.MAX_PER_DAY
