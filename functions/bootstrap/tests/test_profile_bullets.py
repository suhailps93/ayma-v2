"""Service layer for the bullet editor (/profile/bullets)."""

import profile_bullets
import question_tree
import story


# --- fake Firestore (same shape as test_story.py) -------------------------


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

    @property
    def id(self):
        return self.key[-1]

    def get(self):
        return _Snap(self.key[-1], self.store.docs.get(self.key))

    def set(self, payload, merge=False):
        cur = dict(self.store.docs.get(self.key) or {}) if merge else {}
        cur.update(payload)
        self.store.docs[self.key] = cur

    def delete(self):
        self.store.docs.pop(self.key, None)

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store = store
        self.key = key
        self._filters = []

    def document(self, doc_id=None):
        if doc_id is None:
            self.store.counter += 1
            doc_id = f"auto{self.store.counter:04d}"
        return _DocRef(self.store, self.key + (doc_id,))

    def where(self, field, _op, value):
        self._filters.append((field, value))
        return self

    def stream(self):
        d = len(self.key)
        for k, v in list(self.store.docs.items()):
            if len(k) == d + 1 and k[:d] == self.key and v is not None:
                if all(v.get(f) == val for f, val in self._filters):
                    yield _Snap(k[-1], v)


class FakeDb:
    def __init__(self):
        self.docs = {}
        self.counter = 0

    def collection(self, name):
        return _CollRef(self, (name,))


def _page(db, uid, page_id, **data):
    db.docs[("users", uid, "wiki_pages", page_id)] = data


def _edits(db, uid, page_id):
    return db.docs[("users", uid, "wiki_pages", page_id)].get("user_edits")


# --- tests ----------------------------------------------------------------


def test_get_bullets_lists_every_canonical_section_even_empty():
    db = FakeDb()
    _page(
        db, "u1", "identity",
        page_type="identity", visibility="public",
        ai_body="I grew up in Lahore. {{private}}I had a tough divorce.{{/private}}",
    )
    res = profile_bullets.get_bullets(db, "u1")
    by_pt = {s["page_type"]: s for s in res["sections"]}
    # every canonical section is present...
    assert set(by_pt) == set(question_tree.ordered_page_types())
    # ...ordered by the canonical order, About Me first
    assert res["sections"][0]["page_type"] == "identity"
    # the seeded identity page is split into bullets with per-bullet visibility
    ident = by_pt["identity"]
    assert [b["text"] for b in ident["bullets"]] == [
        "I grew up in Lahore.",
        "I had a tough divorce.",
    ]
    assert [b["visibility"] for b in ident["bullets"]] == ["public", "private"]
    assert ident["page_id"] == "identity"
    assert ident["subtitle"]
    # an untouched section comes back empty with no page id (editor shows a "+")
    assert by_pt["career"]["empty"] is True
    assert by_pt["career"]["page_id"] == ""
    assert by_pt["career"]["title"] == "Career"


def test_save_bullets_composes_and_writes_user_edits():
    db = FakeDb()
    _page(db, "u1", "identity", page_type="identity", visibility="public",
          ai_body="Old body.")
    out = profile_bullets.save_bullets(db, "u1", "identity", [
        {"text": "I fly planes.", "visibility": "public"},
        {"text": "I am wealthy.", "visibility": "private"},
    ])
    assert out["visibility"] == "public"
    body = _edits(db, "u1", "identity")
    assert "I fly planes." in body
    assert "{{private}}I am wealthy.{{/private}}" in body


def test_save_all_private_makes_section_private_and_drops_from_public():
    db = FakeDb()
    _page(db, "u1", "relationships", page_type="relationships", visibility="public",
          ai_body="I was married once.")
    out = profile_bullets.save_bullets(db, "u1", "relationships", [
        {"text": "I was married once.", "visibility": "private"},
    ])
    assert out["visibility"] == "private"
    assert db.docs[("users", "u1", "wiki_pages", "relationships")]["visibility"] == "private"


def test_create_bullet_section_makes_a_kebab_page():
    db = FakeDb()
    out = profile_bullets.create_bullet_section(db, "u1", "social_circle", [
        {"text": "I have a tight group of college friends.", "visibility": "public"},
    ])
    assert out["page_id"] == "social-circle"
    page = db.docs[("users", "u1", "wiki_pages", "social-circle")]
    assert page["page_type"] == "social_circle"
    assert "tight group of college friends" in page["user_edits"]
    assert page["visibility"] == "public"


def test_create_rejects_unknown_section():
    db = FakeDb()
    try:
        profile_bullets.create_bullet_section(db, "u1", "not_a_section", [
            {"text": "x", "visibility": "public"},
        ])
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_deleting_an_ai_only_bullet_is_refused():
    # save_section's hidden-span guard protects Ayma-only content from loss.
    db = FakeDb()
    _page(
        db, "u1", "identity", page_type="identity", visibility="public",
        ai_body="Public line. {{ai_only}}Ayma note not to lose.{{/ai_only}}",
    )
    # editing but dropping the ai_only bullet must raise
    try:
        profile_bullets.save_bullets(db, "u1", "identity", [
            {"text": "Public line.", "visibility": "public"},
        ])
        assert False, "expected ValueError (hidden passage loss)"
    except ValueError:
        pass
    # keeping it round-trips fine
    out = profile_bullets.save_bullets(db, "u1", "identity", [
        {"text": "Public line.", "visibility": "public"},
        {"text": "Ayma note not to lose.", "visibility": "ai_only"},
    ])
    assert out["visibility"] == "public"
