"""The date step-in: fires exactly once, only when approved + in-window."""
from datetime import datetime, timedelta, timezone

import pytest

import date_moments
import date_plan


# A small Firestore fake that supports nested set/get PLUS where/stream, which
# the step-in's sim-summary read uses (the shared FakeDb in test_dm_ops has no
# query support). Docs are keyed by their full path tuple.
class _Snap:
    def __init__(self, key, data):
        self._key, self._data = key, data

    @property
    def exists(self):
        return self._data is not None

    @property
    def id(self):
        return self._key[-1]

    def to_dict(self):
        return dict(self._data or {})


class _Doc:
    def __init__(self, store, key):
        self.store, self.key = store, key

    @property
    def id(self):
        return self.key[-1]

    def get(self):
        return _Snap(self.key, self.store.docs.get(self.key))

    def set(self, data, merge=False):
        cur = dict(self.store.docs.get(self.key) or {}) if merge else {}
        cur.update(data)
        self.store.docs[self.key] = cur

    def delete(self):
        self.store.docs.pop(self.key, None)

    def collection(self, name):
        return _Coll(self.store, self.key + (name,))


class _Query:
    def __init__(self, store, key, field, value):
        self.store, self.key, self.field, self.value = store, key, field, value

    def stream(self):
        for k, data in self.store.docs.items():
            if len(k) == len(self.key) + 1 and k[:-1] == self.key:
                if data.get(self.field) == self.value:
                    yield _Snap(k, data)


class _Coll:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id=None):
        if doc_id is None:
            self.store.auto += 1
            doc_id = f"auto{self.store.auto}"
        return _Doc(self.store, self.key + (doc_id,))

    def where(self, field, _op, value):
        return _Query(self.store, self.key, field, value)

    def stream(self):
        for k, data in self.store.docs.items():
            if len(k) == len(self.key) + 1 and k[:-1] == self.key:
                yield _Snap(k, data)


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.auto = 0

    def collection(self, name):
        return _Coll(self, (name,))

START = "2026-11-13T20:00:00+00:00"
AT_TIME = datetime(2026, 11, 13, 20, 10, tzinfo=timezone.utc)
PLACE = dict(place_name="Sakura Sushi", address="1 Main St",
             lat=37.3382, lng=-121.8863, time_label="Friday at 8:00 PM",
             starts_at=START)


def _approved_card(db, parts=("a", "b")):
    plan = date_plan.propose_plan(proposer_uid="a", **PLACE)
    mid = date_plan.post_date_plan_message(db, "a__b", list(parts), plan)
    date_plan.approve(db, "a__b", mid, "a")
    date_plan.approve(db, "a__b", mid, "b")
    return mid


def test_haversine_zero_and_known_distance():
    assert date_moments.haversine_meters(37.0, -121.0, 37.0, -121.0) == 0.0
    # ~111m for 0.001 degree of latitude.
    d = date_moments.haversine_meters(37.0, -121.0, 37.001, -121.0)
    assert 100 < d < 120


def test_within_time_window():
    plan = {"starts_at": START}
    assert date_moments.within_time_window(plan, AT_TIME)
    assert not date_moments.within_time_window(
        plan, AT_TIME + timedelta(hours=3))


def test_at_place_radius():
    plan = {"lat": 37.3382, "lng": -121.8863}
    assert date_moments.at_place(plan, 37.3382, -121.8863)
    assert not date_moments.at_place(plan, 37.5, -121.8863)
    assert not date_moments.at_place({"lat": None, "lng": None}, 37.0, -121.0)


def test_fires_once_for_approved_in_window():
    db = FakeDb()
    mid = _approved_card(db)
    result = date_moments.fire_moment(db, "a__b", mid, "a", "Sofia", AT_TIME)
    assert result is not None
    posted = db.docs[("dm_threads", "a__b", "messages", result["message_id"])]
    assert posted["sender_uid"] == "ayma"
    assert posted["private_to"] == "a"  # only the arriving user sees it
    assert "Sofia" in posted["body"]
    assert "Sakura Sushi" in posted["body"]
    # Fired flag persisted; a second arrival never re-posts.
    plan = db.docs[("dm_threads", "a__b", "messages", mid)]["date_plan"]
    assert plan["moment_fired"] is True
    assert date_moments.fire_moment(db, "a__b", mid, "a", "Sofia", AT_TIME) is None


def test_fire_clears_active_pointer():
    db = FakeDb()
    mid = _approved_card(db)
    # Both-approved wrote the arrival pointer for each person.
    assert db.docs.get(("users", "a", "active_date_plans", "a__b")) is not None
    date_moments.fire_moment(db, "a__b", mid, "a", "Sofia", AT_TIME)
    # Firing drops it so the background geofence stops watching.
    assert db.docs.get(("users", "a", "active_date_plans", "a__b")) is None
    assert db.docs.get(("users", "b", "active_date_plans", "a__b")) is None


def test_does_not_fire_when_not_approved():
    db = FakeDb()
    plan = date_plan.propose_plan(proposer_uid="a", **PLACE)
    mid = date_plan.post_date_plan_message(db, "a__b", ["a", "b"], plan)
    date_plan.approve(db, "a__b", mid, "a")  # only one approval
    assert date_moments.fire_moment(db, "a__b", mid, "a", "Sofia", AT_TIME) is None


def test_does_not_fire_outside_time_window():
    db = FakeDb()
    mid = _approved_card(db)
    far = AT_TIME + timedelta(hours=5)
    assert date_moments.fire_moment(db, "a__b", mid, "a", "Sofia", far) is None


def test_includes_existing_sim_summary_no_regeneration():
    db = FakeDb()
    mid = _approved_card(db)
    # A finished date-sim the user already has for this pair.
    db.collection("users").document("a").collection("date_sims").document(
        "s1").set({
            "other_uid": "b",
            "status": "done",
            "completed_at": AT_TIME,
            "verdict": {"summary": "Easy rapport over food and travel."},
        })
    result = date_moments.fire_moment(db, "a__b", mid, "a", "Sofia", AT_TIME)
    assert "Easy rapport over food and travel." in result["body"]


def test_non_participant_cannot_fire():
    db = FakeDb()
    mid = _approved_card(db)
    with pytest.raises(PermissionError):
        date_moments.fire_moment(db, "a__b", mid, "stranger", "Sofia", AT_TIME)
