from datetime import datetime, timedelta, timezone

import chat_history

_T0 = datetime(2026, 1, 1, tzinfo=timezone.utc)


class _Doc:
    def __init__(self, data):
        self._data = data

    def to_dict(self):
        return dict(self._data)


class _Query:
    def __init__(self, rows):
        self._rows = rows

    def order_by(self, _field, direction=None):
        name = getattr(direction, "name", direction)
        return _Query(sorted(self._rows, key=lambda r: r["created_at"],
                             reverse=name == "DESCENDING"))

    def where(self, _field, op, value):
        assert op == "<"
        return _Query([r for r in self._rows if r["created_at"] < value])

    def limit(self, n):
        return _Query(self._rows[:n])

    def stream(self):
        return [_Doc(r) for r in self._rows]


class _Collection:
    """Stands in for users/{uid}/chat_messages."""

    def __init__(self):
        self.rows = []

    def add(self, payload):
        payload = dict(payload)
        # firestore.SERVER_TIMESTAMP sentinel -> deterministic clock
        payload["created_at"] = _T0 + timedelta(minutes=len(self.rows))
        self.rows.append(payload)

    def order_by(self, *a, **k):
        return _Query(list(self.rows)).order_by(*a, **k)


class _FakeDB:
    def __init__(self):
        self.col = _Collection()

    def collection(self, _name):
        return self

    def document(self, _name):
        return self

    # chat_history._col() ends the chain on .collection("chat_messages")
    # -> return the real collection object the last time.
    def __getattr__(self, _name):  # pragma: no cover - not hit
        raise AttributeError(_name)


def _db():
    db = _FakeDB()
    db.collection = lambda name: db.col if name == "chat_messages" else db
    return db


def test_append_writes_role_text_and_image_path():
    db = _db()
    chat_history.append(
        db, "u1", "user", "  hi there  ", image_path="uploads/u1/x.jpg"
    )
    chat_history.append(db, "u1", "ayma", "hello")
    chat_history.append(db, "u1", "bogus", "dropped")
    chat_history.append(db, "u1", "user", "   ")  # empty + no image -> dropped
    assert [
        (r["role"], r["text"], r["image_path"]) for r in db.col.rows
    ] == [
        ("user", "hi there", "uploads/u1/x.jpg"),
        ("ayma", "hello", ""),
    ]


def test_recent_returns_oldest_first_and_paginates():
    db = _db()
    for i in range(5):
        chat_history.append(db, "u1", "user", f"m{i}")

    page1 = chat_history.recent(db, "u1", limit=2)
    assert [m["text"] for m in page1["messages"]] == ["m3", "m4"]
    assert page1["next_before"] is not None

    page2 = chat_history.recent(
        db, "u1", before=datetime.fromisoformat(page1["next_before"]), limit=2
    )
    assert [m["text"] for m in page2["messages"]] == ["m1", "m2"]

    page3 = chat_history.recent(
        db, "u1", before=datetime.fromisoformat(page2["next_before"]), limit=2
    )
    assert [m["text"] for m in page3["messages"]] == ["m0"]
    assert page3["next_before"] is None
