import feedback_ops
import steering_ops


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


def test_record_submission_writes_a_product_row_into_feedback():
    db = _Db()
    fid = feedback_ops.record_submission(
        db, "u1", "bug", "Orb flickers", "the orb flickers on messages",
        source="chat_card",
        screenshot_paths=["uploads/u1/feedback_1.png", "", "uploads/u1/f2.png"],
        screen="messages", app_version="1.30.0", platform="android",
    )
    assert fid
    row = _row(db, "feedback")  # unified collection, tagged by source
    assert row["source"] == "chat_card"
    assert row["kind"] == "bug"
    assert row["title"] == "Orb flickers"
    assert row["body"] == "the orb flickers on messages"
    assert row["screenshot_paths"] == [
        "uploads/u1/feedback_1.png", "uploads/u1/f2.png",
    ]
    assert row["screenshot_url"] == "uploads/u1/feedback_1.png"
    assert row["screen"] == "messages"
    assert row["platform"] == "android"
    assert row["status"] == "new"


def test_record_submission_coerces_bad_kind_and_source_and_needs_content():
    db = _Db()
    assert feedback_ops.record_submission(
        db, "u1", "bug", "  ", "  ", source="chat_card"
    ) is None
    feedback_ops.record_submission(
        db, "u1", "rant", "", "something broke", source="hax",
    )
    row = _row(db, "feedback")
    assert row["kind"] == "feature"  # unknown kind → feature
    assert row["source"] == "chat_card"  # unknown source → chat_card
    assert row["title"] == "something broke"  # title falls back to body
    assert row["screenshot_url"] is None


# ---------------------------------------------------------------- #
# Admin triage read/write over the unified `feedback` collection.
# ---------------------------------------------------------------- #
class _QSnap:
    def __init__(self, sid, data):
        self.id, self._d = sid, data

    @property
    def exists(self):
        return self._d is not None

    def to_dict(self):
        return dict(self._d) if self._d is not None else None


class _QDocRef:
    def __init__(self, store, name, doc_id):
        self._store, self._name, self._id = store, name, doc_id

    @property
    def id(self):
        return self._id

    def get(self):
        return _QSnap(self._id, self._store.get(self._name, {}).get(self._id))

    def set(self, payload, merge=False):
        col = self._store.setdefault(self._name, {})
        cur = dict(col.get(self._id) or {}) if merge else {}
        cur.update(payload)
        col[self._id] = cur


class _Query:
    def __init__(self, rows):
        self._rows = rows

    def order_by(self, field, direction=None):
        return _Query(
            sorted(
                self._rows,
                key=lambda kv: kv[1].get(field) or "",
                reverse=True,
            )
        )

    def limit(self, n):
        return _Query(self._rows[:n])

    def stream(self):
        return [_QSnap(sid, data) for sid, data in self._rows]


class _QCol:
    def __init__(self, store, name):
        self._store, self._name = store, name

    def document(self, doc_id):
        return _QDocRef(self._store, self._name, doc_id)

    def order_by(self, field, direction=None):
        rows = list(self._store.get(self._name, {}).items())
        return _Query(rows).order_by(field, direction)


class _QDb:
    def __init__(self):
        self.store = {}

    def collection(self, name):
        return _QCol(self.store, name)


def test_list_submissions_returns_only_product_rows_newest_first():
    db = _QDb()
    db.store["feedback"] = {
        "a": {"source": "chat_card", "kind": "bug", "title": "A",
              "created_at": "2026-10-20T10:00:00"},
        "b": {"source": "ayma", "category": "tone",  # conduct row, excluded
              "created_at": "2026-10-21T10:00:00"},
        "c": {"source": "settings_form", "kind": "feature", "title": "C",
              "created_at": "2026-10-22T10:00:00"},
    }
    rows = feedback_ops.list_submissions(db, limit=50)
    ids = [r["id"] for r in rows]
    assert ids == ["c", "a"]  # newest first; conduct row 'b' filtered out


def test_set_submission_status_updates_a_product_row():
    db = _QDb()
    db.store["feedback"] = {"a": {"source": "chat_card", "status": "new"}}
    assert feedback_ops.set_submission_status(db, "a", "triaged") is True
    assert db.store["feedback"]["a"]["status"] == "triaged"


def test_set_submission_status_refuses_bad_status_and_conduct_rows():
    db = _QDb()
    db.store["feedback"] = {
        "a": {"source": "chat_card", "status": "new"},
        "b": {"source": "ayma", "category": "tone"},
    }
    assert feedback_ops.set_submission_status(db, "a", "wat") is False
    assert feedback_ops.set_submission_status(db, "b", "done") is False
    assert feedback_ops.set_submission_status(db, "missing", "done") is False


# ---------------------------------------------------------------- #
# Real-time per-user steering write (§15 Part A). A generic path-keyed fake
# that supports both the flat `feedback` collection and the nested
# `users/{uid}/wiki_pages/{page}` path `steering_ops.add_rule` writes to.
# ---------------------------------------------------------------- #
class _Snap:
    def __init__(self, sid, data):
        self.id = sid
        self._d = data

    @property
    def exists(self):
        return self._d is not None

    def to_dict(self):
        return dict(self._d) if self._d is not None else None


class _DocRef:
    def __init__(self, store, path):
        self._store, self._path = store, path

    @property
    def id(self):
        return self._path[-1]

    def get(self):
        return _Snap(self._path[-1], self._store.get(self._path))

    def set(self, payload, merge=False):
        cur = dict(self._store.get(self._path) or {}) if merge else {}
        cur.update(payload)
        self._store[self._path] = cur

    def collection(self, name):
        return _ColRef(self._store, self._path + (name,))


class _ColRef:
    def __init__(self, store, path):
        self._store, self._path, self._n = store, path, 0

    def document(self, doc_id=None):
        if doc_id is None:
            self._n += 1
            doc_id = f"auto-{self._n}"
        return _DocRef(self._store, self._path + (doc_id,))


class _PathDb:
    def __init__(self):
        self.store = {}

    def collection(self, name):
        return _ColRef(self.store, (name,))


def _steering_body(db):
    doc = db.store.get(("users", "u1", "wiki_pages", "steering"))
    return (doc or {}).get("ai_body", "")


def test_record_writes_a_real_time_steering_rule_for_a_known_category():
    db = _PathDb()
    feedback_ops.record(
        db, "u1", "repeated_question", "re-asked her job", source="ayma",
    )
    body = _steering_body(db)
    assert "Don't ask the same question twice" in body


def test_record_falls_back_to_the_note_for_an_uncategorised_feedback():
    db = _PathDb()
    feedback_ops.record(db, "u1", "other", "kept calling me by the wrong name")
    assert "kept calling me by the wrong name" in _steering_body(db)


def test_record_does_not_duplicate_the_steering_rule_on_repeat_feedback():
    db = _PathDb()
    feedback_ops.record(db, "u1", "rambling", "talked in circles")
    feedback_ops.record(db, "u1", "rambling", "went on forever again")
    body = _steering_body(db)
    assert body.lower().count("don't ramble or run long") == 1


def test_record_steering_write_reuses_steering_ops_cap(monkeypatch):
    db = _PathDb()
    monkeypatch.setattr(steering_ops, "_MAX_RULES", 2)
    feedback_ops.record(db, "u1", "tone", "too flat")
    feedback_ops.record(db, "u1", "pacing", "too rushed")
    feedback_ops.record(db, "u1", "off_script", "went off topic")
    body = _steering_body(db)
    # capped at 2 rules — the oldest ("tone") rolled off
    assert body.count("\n- ") == 2
    assert "Watch your tone with me" not in body
    assert "Watch your pacing with me" in body


def test_record_still_writes_the_feedback_row_even_though_steering_updates():
    db = _PathDb()
    fid = feedback_ops.record(db, "u1", "tone", "too flat")
    assert fid
    assert db.store[("feedback", fid)]["category"] == "tone"
