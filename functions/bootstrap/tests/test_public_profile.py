import public_profile as pp
from pair_key import sorted_pair_key


class _Snap:
    def __init__(self, doc_id, data, reference=None):
        self.id = doc_id
        self._data = data
        self.reference = reference

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def get(self):
        return _Snap(self.key[-1], self.store.docs.get(self.key), reference=self)

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key
        self._filter = None
        self._limit = None

    def document(self, doc_id):
        return _DocRef(self.store, self.key + (doc_id,))

    def where(self, field, _op, value):
        self._filter = (field, value)
        return self

    def limit(self, n):
        self._limit = n
        return self

    def stream(self):
        d = len(self.key)
        n = 0
        for k, v in list(self.store.docs.items()):
            if len(k) == d + 1 and k[:d] == self.key and v is not None:
                if self._filter and v.get(self._filter[0]) != self._filter[1]:
                    continue
                if self._limit is not None and n >= self._limit:
                    break
                n += 1
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
    # No dm_threads doc at all for this pair -> never chatted, even though
    # thread_id (a bare deterministic pair key) is always present.
    assert v["has_chatted"] is False


def test_build_returns_deleted_placeholder_without_touching_shared_thread(
    monkeypatch,
):
    """Point 3 of the founder's 2026-09-20 account-deletion request: B's
    existing match/thread/messages with a since-deleted A must survive, but
    A's profile should render as a clearly-labeled "deleted user" rather
    than their old data or a bare None."""
    db = FakeDb()
    _setup(monkeypatch, db)
    # `her` account was fully deleted: no live profile, but a live shared
    # thread + tombstone, exactly what account_ops.soft_delete leaves behind.
    db.docs[("deleted_users", "her")] = {"deleted_at": 1}
    db.docs[("dm_threads", sorted_pair_key("me", "her"))] = {
        "participants": sorted(["me", "her"]),
    }
    db.docs[
        ("dm_threads", sorted_pair_key("me", "her"), "messages", "m1")
    ] = {"sender": "her", "text": "hey there"}

    v = pp.build(db, "me", "her")
    assert v["deleted"] is True
    assert v["name"] == "Deleted user"
    assert v["photos"] == []
    assert v["pages"] == []
    assert v["blocked"] is False
    # the shared thread itself is untouched and still discoverable
    assert v["thread_id"] == sorted_pair_key("me", "her")
    assert v["has_chatted"] is True
    assert db.docs[("dm_threads", sorted_pair_key("me", "her"), "messages", "m1")][
        "text"
    ] == "hey there"


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
    assert v["has_chatted"] is False


# --- _has_chatted --------------------------------------------------------
# Regression coverage for the false "already chatted" bug: `thread_id` is a
# bare deterministic sorted-pair id (shared with `matches`) that exists for
# any two uids regardless of whether they've ever spoken. The Chat button's
# highlighted state must come from `has_chatted` instead.

def test_has_chatted_is_false_with_no_thread_doc_at_all():
    db = FakeDb()
    assert pp._has_chatted(db, "me", "her") is False


def test_has_chatted_is_false_for_a_thread_doc_with_zero_messages():
    # e.g. some future code path that creates the thread doc eagerly without
    # ever posting a message — must still read as "never chatted".
    db = FakeDb()
    tid = sorted_pair_key("me", "her")
    db.docs[("dm_threads", tid)] = {"participants": ["her", "me"]}
    assert pp._has_chatted(db, "me", "her") is False


def test_has_chatted_is_true_once_a_real_message_exists():
    db = FakeDb()
    tid = sorted_pair_key("me", "her")
    db.docs[("dm_threads", tid)] = {"participants": ["her", "me"]}
    db.docs[("dm_threads", tid, "messages", "m1")] = {
        "sender_uid": "her", "type": "text", "body": "hey",
    }
    assert pp._has_chatted(db, "me", "her") is True
    assert pp._has_chatted(db, "her", "me") is True  # order-independent


# --- _viewing_profile_context ------------------------------------------
# Shared by text chat's /chat (`viewing_profile_uid`) and voice's
# `current_screen` tool (`skills/app_control.py`) — one briefing, not two.

def test_viewing_profile_context_includes_name_age_location_and_wiki():
    db = FakeDb()
    db.docs[("users", "her", "profile", "main")] = {
        "name": "Dillu Renee", "location": "Austin", "birthdate": "1994-01-01",
    }
    db.docs[("users", "her", "wiki_pages", "about")] = {
        "visibility": "public", "page_type": "about", "title": "About",
        "ai_body": "Grew up sailing on the coast.",
    }
    out = pp._viewing_profile_context(db, "me", "her")
    assert "Dillu Renee" in out
    assert "Austin" in out
    assert "[About] Grew up sailing on the coast." in out


def test_viewing_profile_context_includes_the_private_match_read():
    db = FakeDb()
    db.docs[("users", "her", "profile", "main")] = {"name": "Dana"}
    db.docs[("matches", sorted_pair_key("me", "her"))] = {
        "ai_explanation": "They value stability; you crave novelty.",
    }
    out = pp._viewing_profile_context(db, "me", "her")
    assert "They value stability; you crave novelty." in out


def test_viewing_profile_context_is_empty_for_self_or_blank():
    db = FakeDb()
    assert pp._viewing_profile_context(db, "me", "") == ""
    assert pp._viewing_profile_context(db, "me", "me") == ""


def test_viewing_profile_context_falls_back_sensibly_for_an_unknown_uid():
    db = FakeDb()
    out = pp._viewing_profile_context(db, "me", "u-ghost")
    assert out  # doesn't crash, says something
    assert "profile" in out
