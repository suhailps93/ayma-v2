import public_profile as pp


class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def get(self):
        return _Snap(self.key[-1], self.store.docs.get(self.key))

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key
        self._filter = None

    def document(self, doc_id):
        return _DocRef(self.store, self.key + (doc_id,))

    def where(self, field, _op, value):
        self._filter = (field, value)
        return self

    def stream(self):
        d = len(self.key)
        for k, v in list(self.store.docs.items()):
            if len(k) == d + 1 and k[:d] == self.key and v is not None:
                if self._filter and v.get(self._filter[0]) != self._filter[1]:
                    continue
                yield _Snap(k[-1], v)


class FakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _CollRef(self, (name,))


def _setup(monkeypatch, db):
    monkeypatch.setattr(pp, "_photo_url", lambda sp: f"https://cdn/{sp}" if sp else None)
    monkeypatch.setattr(pp, "_score_for", lambda db, a, b: 0.82)


def test_build_returns_public_view_with_photos_pages_and_caller_state(monkeypatch):
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "her", "profile", "main")] = {
        "name": "Dana", "location": "Lisbon", "birthdate": "1994-01-01",
        "photos": [{"media_id": "m2", "order": 1}, {"media_id": "m1", "order": 0}],
    }
    db.docs[("users", "her", "user_media", "m1")] = {"storage_path": "uploads/her/a.jpg"}
    db.docs[("users", "her", "user_media", "m2")] = {"storage_path": "uploads/her/b.jpg"}
    # public: effective body (user_edits wins) with {{private}} spans stripped
    db.docs[("users", "her", "wiki_pages", "about")] = {
        "visibility": "public", "page_type": "about",
        "ai_body": "old narrative",
        "user_edits": "Grew up sailing. {{private}}Bad breakup.{{/private}}",
    }
    db.docs[("users", "her", "wiki_pages", "secret")] = {
        "visibility": "private", "page_type": "family", "ai_body": "hidden",
    }
    db.docs[("users", "her", "wiki_pages", "pulled")] = {
        "visibility": "public", "page_type": "work", "ai_body": "x",
        "user_hidden": True,
    }
    db.docs[("users", "me", "likes", "her")] = {"liked_at": 1}

    v = pp.build(db, "me", "her")
    assert v["name"] == "Dana" and v["location"] == "Lisbon"
    assert v["photos"] == ["https://cdn/uploads/her/a.jpg", "https://cdn/uploads/her/b.jpg"]
    assert [p["body"] for p in v["pages"]] == ["Grew up sailing."]  # span stripped
    assert v["liked"] is True
    assert v["score"] == 0.82
    assert v["self"] is False
    assert v["thread_id"]  # sorted-pair id present


def test_build_is_none_for_a_nameless_or_missing_profile(monkeypatch):
    db = FakeDb()
    _setup(monkeypatch, db)
    assert pp.build(db, "me", "ghost") is None
    db.docs[("users", "blank", "profile", "main")] = {"location": "X", "name": "  "}
    assert pp.build(db, "me", "blank") is None


def test_build_marks_self(monkeypatch):
    db = FakeDb()
    _setup(monkeypatch, db)
    db.docs[("users", "me", "profile", "main")] = {"name": "Me"}
    v = pp.build(db, "me", "me")
    assert v["self"] is True and v["score"] is None and v["thread_id"] is None
