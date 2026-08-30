from pending_questions import add_followup_question


class _Doc:
    def __init__(self):
        self.written = None

    def set(self, payload):
        self.written = payload


class _Db:
    def __init__(self):
        self.doc = _Doc()
        self.path = []
        self._auto_id = "q-generated-1"

    def collection(self, name):
        self.path.append(name)
        return self

    def document(self, name=None):
        self.path.append(name or f"<auto:{self._auto_id}>")
        return self

    @property
    def id(self):
        return self._auto_id

    def set(self, payload):
        return self.doc.set(payload)


def test_add_followup_question_writes_a_pending_doc():
    db = _Db()
    qid = add_followup_question(
        db,
        "u1",
        "  What drew you to teaching?  ",
        "career",
        target_page="career",
    )
    assert qid == "q-generated-1"
    assert db.path == ["users", "u1", "pending_questions", "<auto:q-generated-1>"]
    w = db.doc.written
    assert w["question_text"] == "What drew you to teaching?"
    assert w["category"] == "career"
    assert w["source"] == "followup"
    assert w["status"] == "pending"
    assert w["target_page"] == "career"
    assert w["answered_at"] is None


def test_unknown_category_falls_back_to_misc_and_bad_source_normalises():
    db = _Db()
    add_followup_question(db, "u1", "q?", "not-a-type", source="weird")
    assert db.doc.written["category"] == "misc"
    assert db.doc.written["source"] == "followup"


def test_empty_inputs_are_a_noop():
    db = _Db()
    assert add_followup_question(db, "u1", "   ", "career") is None
    assert add_followup_question(db, "", "real question", "career") is None
    assert db.doc.written is None
