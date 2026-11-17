"""LinkedIn-URL helpers in career_timeline.py (the timeline subsystem was
removed Nov 16 2026 — see career_timeline.py). Only the LinkedIn storage
remains; these pin it."""

import career_timeline

class _Snap:
    def __init__(self, doc_id, data):
        self.id = doc_id
        self._data = None if data is None else dict(data)

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store = store
        self.key = key

    def get(self):
        return _Snap(self.key[-1], self.store.docs.get(self.key))

    def set(self, payload, merge=False):
        cur = dict(self.store.docs.get(self.key) or {}) if merge else {}
        cur.update(payload)
        self.store.docs[self.key] = cur

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store = store
        self.key = key

    def document(self, doc_id=None):
        if doc_id is None:
            self.store.counter += 1
            doc_id = f"auto{self.store.counter:04d}"
        return _DocRef(self.store, self.key + (doc_id,))

    def stream(self):
        d = len(self.key)
        for k, v in list(self.store.docs.items()):
            if len(k) == d + 1 and k[:d] == self.key and v is not None:
                yield _Snap(k[-1], v)


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.counter = 0

    def collection(self, name):
        return _CollRef(self, (name,))


def test_is_linkedin_url_accepts_only_linkedin_links():
    assert career_timeline.is_linkedin_url("https://www.linkedin.com/in/jane-doe/")
    assert career_timeline.is_linkedin_url("https://linkedin.com/in/jane-doe/")
    assert not career_timeline.is_linkedin_url("https://example.com/in/jane-doe/")
    assert not career_timeline.is_linkedin_url("")


def test_set_linkedin_url_rejects_a_non_linkedin_link():
    db = FakeDb()
    try:
        career_timeline.set_linkedin_url(db, "u1", "https://example.com/x")
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_set_and_get_linkedin_url_round_trip():
    db = FakeDb()
    url = career_timeline.set_linkedin_url(
        db, "u1", "https://www.linkedin.com/in/jane-doe/"
    )
    assert url == "https://www.linkedin.com/in/jane-doe/"
    assert career_timeline.get_linkedin_url(db, "u1") == url


def test_get_linkedin_url_defaults_to_empty():
    db = FakeDb()
    assert career_timeline.get_linkedin_url(db, "u1") == ""


def test_get_linkedin_url_falls_back_to_user_doc():
    db = FakeDb()
    db.docs[("users", "u1")] = {"linkedin_url": "https://www.linkedin.com/in/from-user-doc"}
    assert career_timeline.get_linkedin_url(db, "u1") == "https://www.linkedin.com/in/from-user-doc"
    assert db.docs[("users", "u1", "profile", "main")]["linkedin_url"] == "https://www.linkedin.com/in/from-user-doc"


def test_get_linkedin_url_falls_back_to_supplemental():
    db = FakeDb()
    db.docs[("users", "u1", "questionnaire_supplemental", "linkedin-profile")] = {
        "topic": "LinkedIn profile",
        "value": "https://www.linkedin.com/in/daniel-reyes-ux",
    }
    assert career_timeline.get_linkedin_url(db, "u1") == "https://www.linkedin.com/in/daniel-reyes-ux"
    assert db.docs[("users", "u1", "profile", "main")]["linkedin_url"] == "https://www.linkedin.com/in/daniel-reyes-ux"


def test_set_linkedin_url_never_overwrites_present_url_with_none_or_empty():
    db = FakeDb()
    initial_url = "https://www.linkedin.com/in/daniel-reyes-ux"
    career_timeline.set_linkedin_url(db, "u1", initial_url)
    assert career_timeline.get_linkedin_url(db, "u1") == initial_url

    # Attempt to overwrite with None
    res_none = career_timeline.set_linkedin_url(db, "u1", None)
    assert res_none == initial_url
    assert career_timeline.get_linkedin_url(db, "u1") == initial_url
    assert db.docs[("users", "u1", "profile", "main")]["linkedin_url"] == initial_url

    # Attempt to overwrite with empty string
    res_empty = career_timeline.set_linkedin_url(db, "u1", "")
    assert res_empty == initial_url
    assert career_timeline.get_linkedin_url(db, "u1") == initial_url
    assert db.docs[("users", "u1", "profile", "main")]["linkedin_url"] == initial_url

    # Attempt to overwrite with invalid URL
    res_invalid = career_timeline.set_linkedin_url(db, "u1", "https://not-linkedin.com/user")
    assert res_invalid == initial_url
    assert career_timeline.get_linkedin_url(db, "u1") == initial_url
    assert db.docs[("users", "u1", "profile", "main")]["linkedin_url"] == initial_url

    # Valid new LinkedIn URL DOES update
    new_url = "https://www.linkedin.com/in/new-profile"
    res_new = career_timeline.set_linkedin_url(db, "u1", new_url)
    assert res_new == new_url
    assert career_timeline.get_linkedin_url(db, "u1") == new_url
    assert db.docs[("users", "u1", "profile", "main")]["linkedin_url"] == new_url
