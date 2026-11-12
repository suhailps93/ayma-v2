"""Opt-in location log: gating, deterministic patterns, and wipe coverage."""
from datetime import datetime, timezone

import location_log
import schema


# --- A compact Firestore fake: nested collections, doc(path), limit/stream ---
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


class _Coll:
    def __init__(self, store, key):
        self.store, self.key = store, key
        self._limit = None

    def document(self, doc_id=None):
        if doc_id is None:
            self.store.auto += 1
            doc_id = f"auto{self.store.auto}"
        return _Doc(self.store, self.key + (doc_id,))

    def limit(self, n):
        self._limit = n
        return self

    def stream(self):
        hits = [
            _Snap(k, data)
            for k, data in self.store.docs.items()
            if len(k) == len(self.key) + 1 and k[:-1] == self.key
        ]
        return iter(hits if self._limit is None else hits[: self._limit])


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.auto = 0

    def collection(self, name):
        return _Coll(self, (name,))

    def document(self, path):
        return _Doc(self, tuple(path.split("/")))


def _enable_log(db, uid, on=True):
    db.document(f"users/{uid}/profile/main").set(
        {"location_log_enabled": on}, merge=True)


def test_log_visit_skipped_when_opt_out():
    db = FakeDb()  # no toggle set -> default off
    entry_id = location_log.log_visit(
        db, "u1", 37.3, -121.8, classifier=lambda *a: {"place_kind": "cafe"})
    assert entry_id is None
    assert not any("location_log" in k for k in db.docs)


def test_log_visit_stored_when_opted_in():
    db = FakeDb()
    _enable_log(db, "u1")
    ts = datetime(2026, 11, 15, 10, 0, tzinfo=timezone.utc)
    entry_id = location_log.log_visit(
        db, "u1", 37.3, -121.8, timestamp=ts,
        classifier=lambda *a: {"place_name": "Bean There", "place_kind": "cafe"})
    assert entry_id is not None
    stored = db.docs[("users", "u1", "location_log", entry_id)]
    assert stored["place_kind"] == "cafe"
    assert stored["place_name"] == "Bean There"
    assert stored["lat"] == 37.3


def test_log_visit_unknown_kind_when_places_unconfigured():
    db = FakeDb()
    _enable_log(db, "u1")
    # Classifier fails closed to None (no Places key) -> coords kept, unknown.
    entry_id = location_log.log_visit(
        db, "u1", 1.0, 2.0, timestamp=datetime.now(timezone.utc),
        classifier=lambda *a: None)
    stored = db.docs[("users", "u1", "location_log", entry_id)]
    assert stored["place_kind"] == "unknown"
    assert stored["place_name"] == ""


def _mk(kind, dt):
    return {"place_kind": kind, "timestamp": dt}


def test_derive_patterns_weekday_and_time_of_week():
    # Three Sunday hikes (2026-11 Sundays: 1, 8, 15), morning.
    entries = [
        _mk("trailhead", datetime(2026, 11, d, 9, 0, tzinfo=timezone.utc))
        for d in (1, 8, 15)
    ]
    # Two late weeknight bars (Tue 10th, Wed 11th at 22:00).
    entries += [
        _mk("bar", datetime(2026, 11, d, 22, 0, tzinfo=timezone.utc))
        for d in (10, 11)
    ]
    labels = [p["label"] for p in location_log.derive_patterns(entries)]
    assert "Sunday hikes" in labels
    assert "late-weeknight bars" in labels


def test_derive_patterns_needs_recurrence():
    one = [_mk("cafe", datetime(2026, 11, 2, 9, 0, tzinfo=timezone.utc))]
    assert location_log.derive_patterns(one) == []


def test_derive_patterns_ignores_unknown_kind():
    noise = [
        _mk("unknown", datetime(2026, 11, d, 9, 0, tzinfo=timezone.utc))
        for d in (1, 8, 15)
    ]
    assert location_log.derive_patterns(noise) == []


def test_patterns_for_reads_log_live():
    db = FakeDb()
    _enable_log(db, "u1")
    for d in (1, 8, 15):
        location_log.log_visit(
            db, "u1", 37.0, -121.0,
            timestamp=datetime(2026, 11, d, 9, 0, tzinfo=timezone.utc),
            classifier=lambda *a: {"place_kind": "trailhead"})
    labels = [p["label"] for p in location_log.patterns_for(db, "u1")]
    assert "Sunday hikes" in labels


def test_location_log_is_wiped_and_in_account():
    # The knowledge wipe + account archive both include the log subcollection,
    # so wiping "what Ayma has learned" clears it (and the live-derived
    # patterns with it).
    assert schema.LOCATION_LOG in schema.KNOWLEDGE_SUBCOLLECTIONS
    assert schema.LOCATION_LOG in schema.ACCOUNT_SUBCOLLECTIONS
