import asyncio

import photo_notes
import pytest


class _Doc:
    def __init__(self, store, doc_id):
        self._store = store
        self._id = doc_id

    @property
    def id(self):
        return self._id

    def get(self):
        return self

    def to_dict(self):
        return dict(self._store.get(self._id) or {})

    def set(self, data, merge=False):
        cur = dict(self._store.get(self._id) or {}) if merge else {}
        cur.update(data)
        self._store[self._id] = cur


class _Query:
    def __init__(self, docs, field=None, op=None, value=None):
        self._docs = docs
        self._field = field
        self._value = value

    def where(self, field, op, value):
        return _Query(self._docs, field, op, value)

    def limit(self, _n):
        return self

    def stream(self):
        if self._field is None:
            return iter(self._docs.values())
        return iter(
            d for d in self._docs.values()
            if getattr(d, "_row", {}).get(self._field) == self._value
        )


class _MediaDoc(_Doc):
    """A user_media doc — carries its row data for the `where` filter above."""

    def to_dict(self):
        return dict(self._store.get(self._id) or {})

    @property
    def _row(self):
        return self._store.get(self._id) or {}


class _Col:
    def __init__(self, store, doc_cls=_Doc):
        self._store = store
        self._doc_cls = doc_cls

    def document(self, doc_id=None):
        doc_id = doc_id or f"auto{len(self._store)}"
        return self._doc_cls(self._store, doc_id)

    def where(self, field, op, value):
        return _Query({k: self._doc_cls(self._store, k) for k in self._store},
                       field, op, value)

    def stream(self):
        return iter(self._doc_cls(self._store, k) for k in self._store)


class _UserRef:
    def __init__(self, notes, media):
        self._notes = notes
        self._media = media

    def collection(self, name):
        if name == "photo_notes":
            return _Col(self._notes)
        if name == "user_media":
            return _Col(self._media, _MediaDoc)
        raise AssertionError(name)


class _Db:
    def __init__(self, notes=None, media=None):
        self.notes = notes if notes is not None else {}
        self.media = media if media is not None else {}

    def collection(self, name):
        assert name == "users"
        db = self

        class _Users:
            def document(self_, _uid):
                return _UserRef(db.notes, db.media)

        return _Users()


def test_photo_id_is_stable_and_url_safe():
    a = photo_notes.photo_id("https://x/1.jpg")
    b = photo_notes.photo_id("https://x/1.jpg")
    c = photo_notes.photo_id("https://x/2.jpg")
    assert a == b
    assert a != c
    assert a.isalnum()


def test_set_context_then_get_note_round_trips():
    db = _Db()
    photo_notes.set_context(db, "u1", "https://x/1.jpg", context="my grad photo",
                             is_user="yes")
    note = photo_notes.get_note(db, "u1", "https://x/1.jpg")
    assert note == {"context": "my grad photo", "is_user": "yes", "hidden": False}


def test_set_context_rejects_bad_is_user():
    db = _Db()
    with pytest.raises(ValueError):
        photo_notes.set_context(db, "u1", "https://x/1.jpg", is_user="maybe")


def test_all_notes_reads_every_doc_in_one_query():
    db = _Db(notes={
        "a": {"context": "one", "is_user": "", "status": ""},
        "b": {"context": "", "is_user": "no", "status": "deleted"},
        # a pre-status-field document (old boolean `hidden`) still maps
        # through the backward-compat fallback in `_status()`.
        "c": {"context": "", "is_user": "", "hidden": True},
    })
    notes = photo_notes.all_notes(db, "u1")
    assert notes["a"]["context"] == "one"
    assert notes["a"]["status"] == ""
    assert notes["b"]["status"] == "deleted"
    assert notes["c"]["status"] == "deleted"
    assert "hidden" not in notes["a"]


def test_resolve_storage_path_only_matches_our_own_bucket(monkeypatch):
    import dataclasses
    import config
    monkeypatch.setattr(
        photo_notes, "CONFIG",
        dataclasses.replace(config.CONFIG, storage_bucket="ayma-test.appspot.com"),
    )
    ours = (
        "https://firebasestorage.googleapis.com/v0/b/ayma-test.appspot.com/"
        "o/uploads%2Fu1%2Fphoto.jpg?alt=media&token=abc"
    )
    assert photo_notes.resolve_storage_path(ours) == "uploads/u1/photo.jpg"
    assert photo_notes.resolve_storage_path("https://web.example/pic.jpg") is None
    assert photo_notes.resolve_storage_path("") is None


def test_hide_photo_marks_hidden_and_removes_from_grid_for_profile_source(
    monkeypatch,
):
    import dataclasses
    import config
    monkeypatch.setattr(
        photo_notes, "CONFIG",
        dataclasses.replace(config.CONFIG, storage_bucket="ayma-test.appspot.com"),
    )
    url = (
        "https://firebasestorage.googleapis.com/v0/b/ayma-test.appspot.com/"
        "o/uploads%2Fu1%2Fphoto.jpg?alt=media&token=abc"
    )
    db = _Db(media={"m1": {"storage_path": "uploads/u1/photo.jpg"}})
    removed = []
    import photo_ops
    monkeypatch.setattr(photo_ops, "remove_photo",
                         lambda _db, _uid, media_id: removed.append(media_id))

    photo_notes.hide_photo(db, "u1", url, source="profile")

    assert removed == ["m1"]
    assert photo_notes.get_note(db, "u1", url)["hidden"] is True


def test_hide_photo_on_a_chat_or_web_photo_only_sets_the_note():
    db = _Db()
    photo_notes.hide_photo(db, "u1", "https://cdn/chat-1.jpg", source="chat")
    assert photo_notes.get_note(db, "u1", "https://cdn/chat-1.jpg")["hidden"] is True


def test_publish_photo_is_a_noop_for_an_already_public_profile_photo():
    db = _Db()
    result = asyncio.run(
        photo_notes.publish_photo(db, "u1", "https://cdn/p.jpg", source="profile")
    )
    assert result == {"published": True, "already_public": True}


def test_publish_photo_runs_the_pipeline_and_adds_to_the_grid(monkeypatch):
    import dataclasses
    import config

    monkeypatch.setattr(
        photo_notes, "CONFIG",
        dataclasses.replace(config.CONFIG, storage_bucket="ayma-test.appspot.com"),
    )
    url = (
        "https://firebasestorage.googleapis.com/v0/b/ayma-test.appspot.com/"
        "o/uploads%2Fu1%2Fchat.jpg?alt=media&token=abc"
    )
    db = _Db()

    async def _fake_process(_db, _uid, storage_path, source, **kw):
        assert storage_path == "uploads/u1/chat.jpg"
        assert source == "profile"
        return {"media_id": "m9", "published": True}

    import photo_pipeline
    monkeypatch.setattr(photo_pipeline, "process", _fake_process)

    added = []
    import photo_ops
    monkeypatch.setattr(photo_ops, "add_photo",
                         lambda _db, _uid, media_id: added.append(media_id))

    result = asyncio.run(photo_notes.publish_photo(db, "u1", url, source="chat"))
    assert result == {"published": True, "media_id": "m9"}
    assert added == ["m9"]
    note = photo_notes.get_note(db, "u1", url)
    # "superseded" isn't a client-visible "deleted" state — the original copy
    # just disappears from the gallery (see classify_and_dedupe /
    # _ai_view_photos), it's not shown as "deleted by you".
    assert note["hidden"] is False
    assert note["is_user"] == "yes"
    raw = db.notes[photo_notes.photo_id(url)]
    assert raw["status"] == "superseded"


def test_profile_photo_media_returns_url_and_embedding_pairs(monkeypatch):
    import public_profile
    monkeypatch.setattr(public_profile, "_photo_url", lambda path: f"https://cdn/{path}")

    db = _Db(media={"m1": {"storage_path": "uploads/u1/a.jpg", "embedding": [1.0, 0.0]}})
    prof = {"photos": [{"media_id": "m1", "order": 0}]}

    out = photo_notes.profile_photo_media(db, "u1", prof)

    assert out == [{"url": "https://cdn/uploads/u1/a.jpg", "embedding": [1.0, 0.0]}]


def test_profile_photo_media_none_embedding_for_legacy_inline_entry(monkeypatch):
    import public_profile
    monkeypatch.setattr(public_profile, "_photo_url", lambda path: f"https://cdn/{path}")

    db = _Db()  # no user_media docs at all — legacy entry carries its own path
    prof = {"photos": [{"storage_path": "uploads/u1/legacy.jpg", "order": 0}]}

    out = photo_notes.profile_photo_media(db, "u1", prof)

    assert out == [{"url": "https://cdn/uploads/u1/legacy.jpg", "embedding": None}]


def test_classify_and_dedupe_computes_and_caches_a_verdict_for_an_unclassified_chat_photo(
    monkeypatch,
):
    import dataclasses
    import config
    monkeypatch.setattr(
        photo_notes, "CONFIG",
        dataclasses.replace(config.CONFIG, storage_bucket="ayma-test.appspot.com"),
    )
    url = (
        "https://firebasestorage.googleapis.com/v0/b/ayma-test.appspot.com/"
        "o/uploads%2Fu1%2Fchat.jpg?alt=media&token=abc"
    )
    db = _Db()

    import biometric_consent
    monkeypatch.setattr(
        biometric_consent, "has_consent_fresh", lambda _db, _uid: True
    )

    import face_match

    async def _classify(*_a, **_k):
        return {"verdict": "self", "confidence": "high",
                "face_visible": True, "reason": "Matches reference."}

    monkeypatch.setattr(face_match, "classify_photo", _classify)

    candidates = [{"id": "1", "url": url, "source": "chat", "is_user": "",
                   "context": "", "deleted": False, "_embedding": None}]
    out = photo_notes.classify_and_dedupe(db, "u1", candidates)

    assert len(out) == 1
    assert out[0]["is_user"] == "yes"
    raw = db.notes[photo_notes.photo_id(url)]
    assert raw["is_user"] == "yes"
    # No embedding is cached any more — the verdict is the cached fact.
    assert "embedding" not in raw


def test_classify_and_dedupe_drops_a_chat_photo_matching_a_kept_profile_photo(
    monkeypatch,
):
    candidates = [
        {"id": "p", "url": "https://cdn/profile.jpg", "source": "profile",
         "is_user": "", "context": "", "deleted": False, "_embedding": [1.0, 0.0]},
        {"id": "c", "url": "https://cdn/chat-same.jpg", "source": "chat",
         "is_user": "", "context": "", "deleted": False, "_embedding": [1.0, 0.0]},
    ]
    out = photo_notes.classify_and_dedupe(_Db(), "u1", candidates)

    assert [p["id"] for p in out] == ["p"]


def test_classify_and_dedupe_defaults_profile_and_web_is_user_without_network_work(
    monkeypatch,
):
    import face_match

    async def _boom(*_a, **_kw):
        raise AssertionError("should not need to face-match profile or web photos")

    monkeypatch.setattr(face_match, "classify_photo", _boom)

    candidates = [
        {"id": "p", "url": "https://cdn/profile.jpg", "source": "profile",
         "is_user": "", "context": "", "deleted": False, "_embedding": None},
        {"id": "w", "url": "https://web.example/found.jpg", "source": "web",
         "is_user": "", "context": "", "deleted": False, "_embedding": None},
    ]
    out = photo_notes.classify_and_dedupe(_Db(), "u1", candidates)

    assert {p["id"]: p["is_user"] for p in out} == {"p": "yes", "w": "yes"}


def test_classify_and_dedupe_respects_the_per_call_face_match_budget(monkeypatch):
    import dataclasses
    import config
    monkeypatch.setattr(
        photo_notes, "CONFIG",
        dataclasses.replace(config.CONFIG, storage_bucket="ayma-test.appspot.com"),
    )

    def _url(i):
        return (
            f"https://firebasestorage.googleapis.com/v0/b/ayma-test.appspot.com/"
            f"o/uploads%2Fu1%2Fchat{i}.jpg?alt=media&token=abc"
        )

    import biometric_consent
    monkeypatch.setattr(
        biometric_consent, "has_consent_fresh", lambda _db, _uid: True
    )

    calls = []
    import face_match

    async def _classify(*_a, **_k):
        calls.append(1)
        return {"verdict": "self", "confidence": "high",
                "face_visible": True, "reason": "Matches reference."}

    monkeypatch.setattr(face_match, "classify_photo", _classify)

    n = photo_notes._MAX_NEW_EMBEDS_PER_CALL + 5
    candidates = [
        {"id": str(i), "url": _url(i), "source": "chat", "is_user": "",
         "context": "", "deleted": False, "_embedding": None}
        for i in range(n)
    ]
    out = photo_notes.classify_and_dedupe(_Db(), "u1", candidates)

    assert len(calls) == photo_notes._MAX_NEW_EMBEDS_PER_CALL
    # The first twelve got a verdict; the rest wait for a later load.
    assert [p["is_user"] for p in out[:photo_notes._MAX_NEW_EMBEDS_PER_CALL]] == (
        ["yes"] * photo_notes._MAX_NEW_EMBEDS_PER_CALL
    )
    assert [p["is_user"] for p in out[photo_notes._MAX_NEW_EMBEDS_PER_CALL:]] == (
        [""] * 5
    )


def test_classify_and_dedupe_does_not_overwrite_an_already_cached_verdict(
    monkeypatch,
):
    """A chat photo whose `is_user` was already set (e.g. by
    `main._persist_shared_photo_verdict` at chat-send time) must not have
    that verdict recomputed/overwritten here, even though this photo would
    otherwise be classified — no regression on the authoritative-write
    ordering the bugfix relies on."""
    import dataclasses
    import config
    monkeypatch.setattr(
        photo_notes, "CONFIG",
        dataclasses.replace(config.CONFIG, storage_bucket="ayma-test.appspot.com"),
    )
    url = (
        "https://firebasestorage.googleapis.com/v0/b/ayma-test.appspot.com/"
        "o/uploads%2Fu1%2Fchat.jpg?alt=media&token=abc"
    )
    db = _Db(notes={photo_notes.photo_id(url): {"is_user": "no"}})

    import face_match

    async def _should_not_run(*_a, **_kw):  # pragma: no cover
        raise AssertionError(
            "is_user already cached — must not face-match to recompute it"
        )

    monkeypatch.setattr(face_match, "classify_photo", _should_not_run)

    # is_user already "no" — a face check would otherwise return "self" and
    # overwrite it; it must stay "no".
    candidates = [{"id": "1", "url": url, "source": "chat", "is_user": "no",
                   "context": "", "deleted": False, "_embedding": None}]
    out = photo_notes.classify_and_dedupe(db, "u1", candidates)

    assert out[0]["is_user"] == "no"
    raw = db.notes[photo_notes.photo_id(url)]
    assert raw["is_user"] == "no"


def test_publish_photo_surfaces_a_moderation_rejection(monkeypatch):
    import dataclasses
    import config

    monkeypatch.setattr(
        photo_notes, "CONFIG",
        dataclasses.replace(config.CONFIG, storage_bucket="ayma-test.appspot.com"),
    )
    url = (
        "https://firebasestorage.googleapis.com/v0/b/ayma-test.appspot.com/"
        "o/uploads%2Fu1%2Fchat.jpg?alt=media&token=abc"
    )
    db = _Db()

    async def _fake_process(*_a, **_kw):
        return {"published": False, "reason": "flagged"}

    import photo_pipeline
    monkeypatch.setattr(photo_pipeline, "process", _fake_process)

    result = asyncio.run(photo_notes.publish_photo(db, "u1", url, source="chat"))
    assert result == {"published": False, "reason": "flagged"}
