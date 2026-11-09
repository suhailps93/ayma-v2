import bug_reports_ops


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


def test_record_writes_a_unified_feedback_row():
    db = _Db()
    rid = bug_reports_ops.record(db, "u1", "the app crashed on launch")
    assert rid
    row = _row(db, "feedback")
    assert row["uid"] == "u1"
    assert row["kind"] == "bug"
    assert row["source"] == "chat_card"
    assert row["body"] == "the app crashed on launch"
    # No title was supplied: the unified fallback derives it from the body,
    # exactly as for a chat card with a cleared title.
    assert row["title"] == "the app crashed on launch"
    assert row["screenshot_paths"] == []
    assert row["screenshot_url"] is None
    assert row["status"] == "new"
    assert "created_at" in row


def test_record_includes_image_path_as_screenshot_when_present():
    db = _Db()
    bug_reports_ops.record(
        db, "u1", "this button does nothing",
        image_path="uploads/u1/shot.png",
    )
    row = _row(db, "feedback")
    assert row["screenshot_paths"] == ["uploads/u1/shot.png"]
    assert row["screenshot_url"] == "uploads/u1/shot.png"


def test_record_has_no_screenshot_when_absent():
    db = _Db()
    bug_reports_ops.record(db, "u1", "lost my chat history")
    row = _row(db, "feedback")
    assert row["screenshot_paths"] == []
    assert row["screenshot_url"] is None


def test_record_is_noop_without_uid_or_description():
    db = _Db()
    assert bug_reports_ops.record(db, "", "the app crashed") is None
    assert bug_reports_ops.record(db, "u1", "   ") is None
    assert "feedback" not in db.store


def test_record_never_writes_to_the_retired_bug_reports_bucket():
    db = _Db()
    bug_reports_ops.record(db, "u1", "the app crashed")
    assert "bug_reports" not in db.store
    assert "product_feedback" not in db.store
