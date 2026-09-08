from datetime import datetime, timedelta, timezone

import chat_history

_T0 = datetime(2026, 1, 1, tzinfo=timezone.utc)


class _Doc:
    def __init__(self, data):
        self._data = data
        self.id = str(data.get("_id", "session-x"))

    def to_dict(self):
        return {k: v for k, v in self._data.items() if k != "_id"}


class _Query:
    """Replays a fixed row list; Firestore has already ordered/limited it."""

    def __init__(self, rows):
        self._rows = rows

    def order_by(self, field, direction=None):
        name = getattr(direction, "name", direction)
        return _Query(sorted(
            self._rows,
            key=lambda r: r.get(field) or _T0 - timedelta(days=3650),
            reverse=name == "DESCENDING",
        ))

    def where(self, _field, _op, value):
        return _Query([r for r in self._rows
                       if (r.get("created_at") or _T0) < value])

    def limit(self, n):
        return _Query(self._rows[:n])

    def stream(self):
        return [_Doc(r) for r in self._rows]


class _ChatMessages:
    def __init__(self):
        self.rows = []

    def add(self, payload):
        payload = dict(payload)
        payload["created_at"] = _T0 + timedelta(minutes=len(self.rows))
        self.rows.append(payload)

    def order_by(self, *a, **k):
        return _Query(list(self.rows)).order_by(*a, **k)


class _FakeDB:
    """collection("users").document(uid).collection("chat_messages" | "raw_turns")"""

    def __init__(self, *, chat_rows=None, raw_rows=None):
        self.cm = _ChatMessages()
        for r in (chat_rows or []):
            self.cm.rows.append(dict(r))
        self._raw = _Query(list(raw_rows or []))

    def collection(self, name):
        if name == "chat_messages":
            return self.cm
        if name == "raw_turns":
            return self._raw
        return self

    def document(self, _name):
        return self


def test_append_writes_role_text_and_image_path():
    db = _FakeDB()
    chat_history.append(
        db, "u1", "user", "  hi there  ", image_path="uploads/u1/x.jpg"
    )
    chat_history.append(db, "u1", "ayma", "hello")
    chat_history.append(db, "u1", "bogus", "dropped")
    chat_history.append(db, "u1", "user", "   ")
    assert [
        (r["role"], r["text"], r["image_path"]) for r in db.cm.rows
    ] == [
        ("user", "hi there", "uploads/u1/x.jpg"),
        ("ayma", "hello", ""),
    ]


def test_append_drops_a_shared_photo_placeholder_on_an_image_turn():
    db = _FakeDB()
    chat_history.append(
        db, "u1", "user", "(shared a photo)", image_path="uploads/u1/a.jpg"
    )
    chat_history.append(
        db, "u1", "user", "what's in this? [shared an image]",
        image_path="uploads/u1/b.jpg",
    )
    assert [(r["text"], r["image_path"]) for r in db.cm.rows] == [
        ("", "uploads/u1/a.jpg"),
        ("what's in this?", "uploads/u1/b.jpg"),
    ]


def test_recent_shows_the_image_not_the_placeholder_after_a_reload():
    # chat_messages has the real image row (no placeholder text); raw_turns
    # has the "(shared a photo)\n[shared a photo]" persisted version.
    db = _FakeDB(
        chat_rows=[
            {"role": "user", "text": "", "image_path": "uploads/u1/p.jpg",
             "created_at": _T0 + timedelta(minutes=1)},
        ],
        raw_rows=[
            {"turns": [{"role": "user",
                        "text": "(shared a photo)\n[shared a photo]"}],
             "updated_at": _T0 + timedelta(minutes=1)},
        ],
    )
    r = chat_history.recent(db, "u1", limit=40)
    assert [(m["text"], m["image_path"]) for m in r["messages"]] == [
        ("", "uploads/u1/p.jpg"),
    ]


def test_recent_returns_oldest_first_and_paginates():
    db = _FakeDB()
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


def test_recent_merges_raw_turns_voice_history_with_chat_messages():
    # chat_messages: one recent text turn (with an image). raw_turns: an older
    # voice session whose turns predate chat_messages -> both must show.
    db = _FakeDB(
        chat_rows=[
            {"role": "user", "text": "newest typed", "image_path": "uploads/u1/p.jpg",
             "created_at": _T0 + timedelta(hours=2)},
        ],
        raw_rows=[
            {"turns": [
                {"role": "user", "text": "hey"},
                {"role": "ayma", "text": "hi, what's up"},
                {"role": "user", "text": "just rambling out loud"},
             ], "updated_at": _T0 + timedelta(hours=1)},
        ],
    )
    r = chat_history.recent(db, "u1", limit=40)
    texts = [m["text"] for m in r["messages"]]
    assert texts == ["hey", "hi, what's up", "just rambling out loud", "newest typed"]
    # the image survives from chat_messages
    assert r["messages"][-1]["image_path"] == "uploads/u1/p.jpg"


def test_recent_excludes_dm_sourced_raw_turns():
    # DM ingest writes raw_turns/dm-{thread}-{msg}; those must not surface in
    # the Ayma chat transcript.
    db = _FakeDB(
        chat_rows=[
            {"role": "ayma", "text": "hey there", "image_path": "",
             "created_at": _T0 + timedelta(minutes=1)},
        ],
        raw_rows=[
            {"_id": "dm-aaa__bbb-msg1",
             "turns": [{"role": "user", "text": "hey boy what's upp"}],
             "updated_at": _T0 + timedelta(minutes=2)},
            {"_id": "01ABCSESSION",
             "turns": [{"role": "user", "text": "real ayma turn"}],
             "updated_at": _T0 + timedelta(minutes=3)},
        ],
    )
    texts = [m["text"] for m in chat_history.recent(db, "u1", limit=40)["messages"]]
    assert "hey boy what's upp" not in texts
    assert "real ayma turn" in texts
    assert "hey there" in texts


def test_recent_dedupes_a_turn_present_in_both_sources():
    db = _FakeDB(
        chat_rows=[
            {"role": "user", "text": "shared line", "image_path": "",
             "created_at": _T0 + timedelta(minutes=5)},
        ],
        raw_rows=[
            {"turns": [{"role": "user", "text": "shared line"},
                       {"role": "ayma", "text": "unique voice reply"}],
             "updated_at": _T0 + timedelta(minutes=6)},
        ],
    )
    r = chat_history.recent(db, "u1", limit=40)
    texts = [m["text"] for m in r["messages"]]
    assert texts.count("shared line") == 1
    assert "unique voice reply" in texts


def test_recent_cursor_when_more_history_exists():
    db = _FakeDB(
        raw_rows=[
            {"turns": [{"role": "user", "text": f"t{i}"} for i in range(6)],
             "updated_at": _T0 + timedelta(hours=1)},
        ],
    )
    page = chat_history.recent(db, "u1", limit=4)
    assert [m["text"] for m in page["messages"]] == ["t2", "t3", "t4", "t5"]
    assert page["next_before"] is not None  # t0/t1 still older
    older = chat_history.recent(
        db, "u1", before=datetime.fromisoformat(page["next_before"]), limit=4
    )
    assert [m["text"] for m in older["messages"]] == ["t0", "t1"]
