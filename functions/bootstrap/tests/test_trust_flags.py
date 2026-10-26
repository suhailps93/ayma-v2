from datetime import datetime, timezone

import trust_flags


class _Snap:
    def __init__(self, data):
        self._data = data

    def to_dict(self):
        return dict(self._data)


class _Ref:
    def __init__(self, store):
        self.store = store
        self.writes = 0

    def get(self):
        return _Snap(self.store)

    def set(self, payload, merge=False):
        self.writes += 1
        self.store.update(payload)


class _Db:
    def __init__(self, store=None):
        self._ref = _Ref(store if store is not None else {})

    def collection(self, _):
        return self

    def document(self, _):
        return self._ref


_OLD = datetime(2026, 9, 14, tzinfo=timezone.utc)


def test_sync_records_the_latest_run_and_dedupes():
    db = _Db()
    n = trust_flags.sync_self_contradictions(db, "u1", ["age", "age", "  ", "job"])
    assert n == 2
    flags = db._ref.store["trust_flags"]
    assert [(f["type"], f["detail"]) for f in flags] == [
        ("self_contradiction", "age"), ("self_contradiction", "job"),
    ]
    assert all("flagged_at" in f for f in flags)


def test_sync_replaces_reworded_copies_instead_of_piling_them_up():
    """Founder's account had nine self-contradiction flags: the nightly lint
    reworded the same three contradictions and every wording was appended,
    so matching charged the same issue again each night (score 41% -> 1%)."""
    reworded = [
        {"type": "self_contradiction", "detail": f"virgin vs has a son ({i})",
         "flagged_at": _OLD}
        for i in range(8)
    ]
    face = {"type": "face_mismatch", "detail": "new photo", "flagged_at": _OLD}
    db = _Db({"trust_flags": [*reworded, face]})

    n = trust_flags.sync_self_contradictions(db, "u1", ["virgin vs has a son (3)"])

    assert n == 1
    flags = db._ref.store["trust_flags"]
    assert face in flags
    contradictions = [f for f in flags if f["type"] == "self_contradiction"]
    # The surviving one keeps its original timestamp.
    assert contradictions == [reworded[3]]


def test_sync_clears_resolved_contradictions_and_skips_no_op_writes():
    db = _Db({"trust_flags": [
        {"type": "self_contradiction", "detail": "age", "flagged_at": _OLD},
    ]})
    assert trust_flags.sync_self_contradictions(db, "u1", []) == 0
    assert db._ref.store["trust_flags"] == []
    writes = db._ref.writes
    assert trust_flags.sync_self_contradictions(db, "u1", []) == 0
    assert db._ref.writes == writes
