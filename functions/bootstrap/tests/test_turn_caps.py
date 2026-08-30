import turn_caps


class _UserRef:
    def __init__(self, store):
        self._store = store

    def get(self):
        return _Snap(self._store)

    def set(self, payload, merge=False):
        self._store.update(payload)


class _Snap:
    def __init__(self, store):
        self._store = store

    @property
    def exists(self):
        return bool(self._store)

    def to_dict(self):
        return dict(self._store)


class _Db:
    def __init__(self, store=None):
        self.store = store or {}

    def collection(self, _name):
        return self

    def document(self, _name):
        return _UserRef(self.store)


def _run(mode, start_count, *, marketing_cap=3, interview_cap=3, monkeypatch):
    from config import CONFIG
    import dataclasses

    monkeypatch.setattr(
        turn_caps,
        "CONFIG",
        dataclasses.replace(
            CONFIG,
            cap_marketing_turns=marketing_cap,
            cap_interview_turns=interview_cap,
        ),
    )
    field = turn_caps._FIELD[mode]
    db = _Db({field: start_count} if start_count else {})
    result = turn_caps.evaluate(db, "u1", mode)
    return result, db.store.get(field, 0)


def test_marketing_under_cap_allows_and_increments(monkeypatch):
    r, count = _run("marketing", 1, marketing_cap=3, monkeypatch=monkeypatch)
    assert r.allowed is True and r.canned_reply is None
    assert count == 2


def test_marketing_at_cap_nudges_once(monkeypatch):
    r, count = _run("marketing", 3, marketing_cap=3, monkeypatch=monkeypatch)
    assert r.allowed is False
    assert "get started" in r.canned_reply
    assert r.fallback_form is False
    assert count == 4  # counter still advanced past the cap


def test_marketing_over_cap_hard_refuses_and_freezes(monkeypatch):
    r, count = _run("marketing", 5, marketing_cap=3, monkeypatch=monkeypatch)
    assert r.allowed is False
    assert count == 5  # frozen


def test_interview_at_cap_triggers_the_fallback_form(monkeypatch):
    r, count = _run("interview", 3, interview_cap=3, monkeypatch=monkeypatch)
    assert r.allowed is False
    assert r.fallback_form is True
    assert count == 4


def test_active_mode_is_uncapped(monkeypatch):
    from config import CONFIG

    db = _Db()
    r = turn_caps.evaluate(db, "u1", "active")
    assert r.allowed is True
    assert db.store == {}  # no counter written


def test_peek_is_read_only(monkeypatch):
    import dataclasses

    from config import CONFIG

    monkeypatch.setattr(
        turn_caps, "CONFIG", dataclasses.replace(CONFIG, cap_marketing_turns=3)
    )
    db = _Db({"marketing_turn_count": 3})
    state = turn_caps.peek(db, "u1", "marketing")
    assert state == {
        "mode": "marketing",
        "count": 3,
        "cap": 3,
        "reached": True,
    }
    assert db.store == {"marketing_turn_count": 3}  # untouched
