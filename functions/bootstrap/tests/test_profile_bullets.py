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


def test_user_can_reverse_an_ai_only_bullet_in_the_bullet_editor():
    # The bullet editor is a full explicit editor: the user sees every bullet
    # (Ayma-only included) and controls each one. Moving an Ayma-only bullet
    # back to private/public must work — no cycle trap (the default hidden-span
    # loss-guard does not apply here).
    db = FakeDb()
    _page(
        db, "u1", "identity", page_type="identity", visibility="public",
        ai_body="Public line. {{ai_only}}Was Ayma-only, now surfaced.{{/ai_only}}",
    )
    out = profile_bullets.save_bullets(db, "u1", "identity", [
        {"text": "Public line.", "visibility": "public"},
        {"text": "Was Ayma-only, now surfaced.", "visibility": "private"},
    ])
    assert out["visibility"] == "public"
    body = _edits(db, "u1", "identity")
    # it is now a private bullet, no longer an ai_only span
    assert "{{private}}Was Ayma-only, now surfaced.{{/private}}" in body
    assert "{{ai_only}}" not in body
    # and the user may remove it entirely
    out2 = profile_bullets.save_bullets(db, "u1", "identity", [
        {"text": "Public line.", "visibility": "public"},
    ])
    assert "ai_only" not in _edits(db, "u1", "identity")


def test_get_bullets_dedupes_and_merges_duplicate_page_types():
    # Live staging Firestore fixture shape (e.g. demo-test1 Daniel Reyes has
    # 27 wiki pages with 7 duplicated page_types: dealbreakers x2, family x2,
    # interests x2, lifestyle x2, relationships x2, social_circle x2, values x2).
    # get_bullets() must return each canonical page_type exactly once, merging
    # the content of duplicate pages so all bullets are preserved in order.
    db = FakeDb()
    _page(
        db, "demo-test1", "dealbreakers",
        page_type="dealbreakers", title="Non-Negotiables", visibility="public",
        ai_body="Must love dogs. {{private}}Never smoke.{{/private}}",
    )
    _page(
        db, "demo-test1", "core-non-negotiables",
        page_type="dealbreakers", title="Core Non-Negotiables", visibility="private",
        ai_body="Must want children. {{ai_only}}Cannot tolerate dishonesty.{{/ai_only}}",
    )
    _page(
        db, "demo-test1", "family",
        page_type="family", title="Family", visibility="public",
        ai_body="Close with my parents.",
    )
    _page(
        db, "demo-test1", "family-2",
        page_type="family", title="Family Background", visibility="public",
        ai_body="I have an older brother in Chicago.",
    )

    res = profile_bullets.get_bullets(db, "demo-test1")
    sections = res["sections"]
    page_types = [s["page_type"] for s in sections]

    # Every canonical section appears exactly once — no duplicates
    assert len(page_types) == len(set(page_types))
    assert len(page_types) == len(question_tree.ordered_page_types())

    by_pt = {s["page_type"]: s for s in sections}

    # dealbreakers merged: both pages' bullets preserved in sensible order
    db_sec = by_pt["dealbreakers"]
    assert db_sec["page_id"] == "dealbreakers"
    bullet_texts = [b["text"] for b in db_sec["bullets"]]
    assert bullet_texts == [
        "Must want children.",
        "Cannot tolerate dishonesty.",
        "Must love dogs.",
        "Never smoke.",
    ]
    bullet_vis = [b["visibility"] for b in db_sec["bullets"]]
    assert bullet_vis == ["private", "ai_only", "public", "private"]
    assert db_sec["has_ai_only"] is True
    assert db_sec["empty"] is False

    # family merged: both bullets preserved
    fam_sec = by_pt["family"]
    assert fam_sec["page_id"] == "family"
    assert [b["text"] for b in fam_sec["bullets"]] == [
        "Close with my parents.",
        "I have an older brother in Chicago.",
    ]


def test_get_bullets_merges_and_dedupes_identical_bullet_texts():
    db = FakeDb()
    _page(
        db, "u1", "dealbreakers-1",
        page_type="dealbreakers", visibility="public",
        ai_body="No smokers.",
    )
    _page(
        db, "u1", "dealbreakers",
        page_type="dealbreakers", visibility="public",
        ai_body="No smokers. Must like outdoor hiking.",
    )
    res = profile_bullets.get_bullets(db, "u1")
    by_pt = {s["page_type"]: s for s in res["sections"]}
    db_sec = by_pt["dealbreakers"]
    assert db_sec["page_id"] == "dealbreakers"
    assert [b["text"] for b in db_sec["bullets"]] == [
        "No smokers.",
        "Must like outdoor hiking.",
    ]

