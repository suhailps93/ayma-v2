from post_turn import persist_raw_turns
from transcript import Turn


class _FakeDoc:
    def __init__(self):
        self.written = None
        self.merge = None

    def set(self, payload, merge=False):
        self.written = payload
        self.merge = merge


class _FakeDb:
    def __init__(self):
        self.doc = _FakeDoc()
        self.path = []

    def collection(self, name):
        self.path.append(name)
        return self

    def document(self, name):
        self.path.append(name)
        return self

    # after two collection/document pairs the chain resolves to the doc
    def set(self, *a, **k):
        return self.doc.set(*a, **k)


def test_persist_writes_one_merged_doc_at_the_session_path():
    db = _FakeDb()
    persist_raw_turns(
        db,
        "uid-1",
        "sess-1",
        [Turn("user", "hi"), Turn("ayma", "hello")],
    )
    assert db.path == ["users", "uid-1", "raw_turns", "sess-1"]
    assert db.doc.merge is True
    assert db.doc.written["turn_count"] == 2
    assert db.doc.written["turns"] == [
        {"role": "user", "text": "hi"},
        {"role": "ayma", "text": "hello"},
    ]


def test_persist_is_a_noop_for_empty_input():
    db = _FakeDb()
    persist_raw_turns(db, "uid-1", "sess-1", [])
    persist_raw_turns(db, "", "sess-1", [Turn("user", "x")])
    assert db.doc.written is None
