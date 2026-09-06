import feedback_ops


class _Doc:
    def __init__(self, store, col, doc_id):
        self._store, self._col, self._id = store, col, doc_id

    @property
    def id(self):
        return self._id

    def set(self, payload, merge=False):
        self._store.setdefault(self._col, {})[self._id] = dict(payload)


class _Col:
    def __init__(self, store, name):
        self._store, self._name = store, name
        self._n = 0

    def document(self, doc_id=None):
        if doc_id is None:
            self._n += 1
            doc_id = f"{self._name}-{self._n}"
        return _Doc(self._store, self._name, doc_id)


class _Db:
    def __init__(self):
        self.store = {}

    def collection(self, name):
        return _Col(self.store, name)


def _row(db, col):
    return next(iter(db.store[col].values()))


def test_record_writes_a_feedback_row():
    db = _Db()
    fid = feedback_ops.record(
        db, "u1", "repeated_question", "re-asked about her job",
        quote="you already asked me that", severity="medium", source="ayma",
    )
    assert fid
    row = _row(db, "feedback")
    assert row["uid"] == "u1"
    assert row["category"] == "repeated_question"
    assert row["quote"] == "you already asked me that"
    assert row["severity"] == "medium"
    assert row["source"] == "ayma"
    assert row["status"] == "new"


def test_record_coerces_unknown_category_source_severity():
    db = _Db()
    feedback_ops.record(db, "u1", "wat", "note", severity="nuclear",
                        source="martian")
    row = _row(db, "feedback")
    assert row["category"] == "other"
    assert row["severity"] == "low"
    assert row["source"] == "ayma"


def test_record_is_noop_without_uid_or_content():
    db = _Db()
    assert feedback_ops.record(db, "", "tone", "x") is None
    assert feedback_ops.record(db, "u1", "tone", "  ", quote="  ") is None
    assert "feedback" not in db.store


def test_record_product_writes_to_its_own_bucket_with_paths():
    db = _Db()
    fid = feedback_ops.record_product(
        db, "u1", "bug", "the orb flickers",
        ["uploads/u1/feedback_1.png", "", "uploads/u1/feedback_2.png"],
        app_version="1.2.3",
    )
    assert fid
    assert "feedback" not in db.store  # never crosses buckets
    row = _row(db, "product_feedback")
    assert row["kind"] == "bug"
    assert row["text"] == "the orb flickers"
    assert row["image_paths"] == [
        "uploads/u1/feedback_1.png", "uploads/u1/feedback_2.png",
    ]
    assert row["app_version"] == "1.2.3"


def test_record_product_defaults_bad_kind_to_bug_and_needs_text():
    db = _Db()
    assert feedback_ops.record_product(db, "u1", "bug", "  ") is None
    feedback_ops.record_product(db, "u1", "rant", "something")
    assert _row(db, "product_feedback")["kind"] == "bug"
