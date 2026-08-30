import trust_flags


class _Snap:
    def __init__(self, data):
        self._data = data

    def to_dict(self):
        return dict(self._data)


class _Ref:
    def __init__(self, store):
        self.store = store

    def get(self):
        return _Snap(self.store)

    def set(self, payload, merge=False):
        self.store.update(payload)


class _Db:
    def __init__(self, store=None):
        self._ref = _Ref(store if store is not None else {})

    def collection(self, _):
        return self

    def document(self, _):
        return self._ref


def test_adds_and_dedupes():
    db = _Db()
    assert trust_flags.add_trust_flag(db, "u1", "self_contradiction", "age") is True
    assert trust_flags.add_trust_flag(db, "u1", "self_contradiction", "age") is False
    assert trust_flags.add_trust_flag(db, "u1", "face_mismatch", "new photo") is True
    flags = db._ref.store["trust_flags"]
    assert [f["type"] for f in flags] == ["self_contradiction", "face_mismatch"]
    assert all("flagged_at" in f for f in flags)


def test_rejects_unknown_type_or_empty_detail():
    db = _Db()
    assert trust_flags.add_trust_flag(db, "u1", "vibes", "x") is False
    assert trust_flags.add_trust_flag(db, "u1", "face_mismatch", "  ") is False
    assert "trust_flags" not in db._ref.store
