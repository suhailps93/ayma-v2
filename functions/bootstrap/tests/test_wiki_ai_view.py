import deep_dive
import main
import photo_notes
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def _no_notes_no_dive(monkeypatch):
    """The common case: no notes written yet, no self dive on file."""
    monkeypatch.setattr(photo_notes, "all_notes", lambda _db, _uid: {})
    monkeypatch.setattr(deep_dive, "read_dive", lambda _db, _uid, _rid: None)


def _no_profile_photos(monkeypatch):
    monkeypatch.setattr(main.schema, "profile_doc",
                         lambda _db, _uid: type(
                             "D", (), {"get": lambda s: s, "to_dict": lambda s: {}}
                         )())
    monkeypatch.setattr(photo_notes, "profile_photo_media", lambda _db, _uid, _prof: [])


class _Snap:
    def __init__(self, data):
        self._data = data

    def to_dict(self):
        return dict(self._data)


class _ChatQuery:
    def __init__(self, rows):
        self._rows = rows

    def order_by(self, *a, **k):
        return self

    def limit(self, _n):
        return self

    def stream(self):
        return iter(self._rows)


class _UserRef:
    def __init__(self, rows):
        self._rows = rows

    def collection(self, name):
        assert name == "chat_messages"
        return _ChatQuery(self._rows)


class _Db:
    def __init__(self, rows):
        self._rows = rows

    def collection(self, name):
        assert name == "users"
        rows = self._rows

        class _Users:
            def document(self_, _uid):
                return _UserRef(rows)

        return _Users()


def test_ai_view_returns_notes_plus_photos_from_both_sources(monkeypatch):
    _no_notes_no_dive(monkeypatch)
    monkeypatch.setattr(main, "read_wiki_context", lambda _db, _uid: "the notes")

    monkeypatch.setattr(
        main.schema, "profile_doc",
        lambda _db, _uid: type("D", (), {"get": lambda s: s, "to_dict": lambda s: {}})(),
    )
    monkeypatch.setattr(
        photo_notes, "profile_photo_media",
        lambda _db, _uid, _prof: [{"url": "https://cdn/profile-1.jpg", "embedding": None}],
    )
    monkeypatch.setattr(
        main, "get_db",
        lambda: _Db([
            _Snap({"image_path": "uploads/me/chat_1.jpg"}),
            _Snap({"image_path": ""}),  # a text-only turn — skipped
            _Snap({"image_path": "uploads/me/chat_2.jpg"}),
        ]),
    )
    import public_profile
    monkeypatch.setattr(public_profile, "_photo_url", lambda path: f"https://cdn/{path}")

    r = client.get("/wiki/ai-view", headers=_auth(monkeypatch))
    assert r.status_code == 200
    body = r.json()
    assert body["text"] == "the notes"
    assert [p["source"] for p in body["photos"]] == ["profile", "chat", "chat"]
    assert body["photos"][0]["url"] == "https://cdn/profile-1.jpg"
    assert body["photos"][1]["url"] == "https://cdn/uploads/me/chat_1.jpg"
    # a profile photo is definitionally the user — defaulted without any
    # face-match work; an unclassified chat photo (no resolvable storage
    # path here) is left alone rather than guessed at.
    assert body["photos"][0]["is_user"] == "yes"
    assert body["photos"][1]["is_user"] == ""
    assert all(p["id"] and p["context"] == "" and p["deleted"] is False for p in body["photos"])


def test_ai_view_dedupes_by_url_and_requires_auth(monkeypatch):
    _no_notes_no_dive(monkeypatch)
    monkeypatch.setattr(main, "read_wiki_context", lambda _db, _uid: "")
    monkeypatch.setattr(
        main.schema, "profile_doc",
        lambda _db, _uid: type("D", (), {"get": lambda s: s, "to_dict": lambda s: {}})(),
    )
    monkeypatch.setattr(
        photo_notes, "profile_photo_media",
        lambda _db, _uid, _prof: [{"url": "https://cdn/dup.jpg", "embedding": None}],
    )
    monkeypatch.setattr(
        main, "get_db",
        lambda: _Db([_Snap({"image_path": "uploads/me/chat_1.jpg"})]),
    )
    import public_profile
    monkeypatch.setattr(public_profile, "_photo_url", lambda _p: "https://cdn/dup.jpg")

    r = client.get("/wiki/ai-view", headers=_auth(monkeypatch))
    assert r.status_code == 200
    # the chat photo resolves to the exact same URL as the profile photo —
    # de-duped at the URL level before it even reaches classify_and_dedupe.
    photos = r.json()["photos"]
    assert len(photos) == 1
    assert photos[0]["url"] == "https://cdn/dup.jpg"
    assert photos[0]["source"] == "profile"

    assert client.get("/wiki/ai-view").status_code in (401, 403)


def test_ai_view_includes_only_verified_web_photos(monkeypatch):
    _no_notes_no_dive(monkeypatch)
    _no_profile_photos(monkeypatch)
    monkeypatch.setattr(main, "read_wiki_context", lambda _db, _uid: "")
    monkeypatch.setattr(main, "get_db", lambda: _Db([]))
    monkeypatch.setattr(
        deep_dive, "read_dive",
        lambda _db, _uid, _rid: {
            "digest": {
                "web_images": [
                    {"url": "https://web.example/found.jpg",
                     "source_page": "https://web.example/page",
                     "verified": True},
                    {"url": "https://web.example/unverified.jpg", "verified": False},
                ]
            }
        },
    )

    r = client.get("/wiki/ai-view", headers=_auth(monkeypatch))
    assert r.status_code == 200
    photos = r.json()["photos"]
    assert [p["url"] for p in photos] == ["https://web.example/found.jpg"]
    assert photos[0]["source"] == "web"
    assert photos[0]["source_page"] == "https://web.example/page"
    # a web photo is already face-verified before it lands in the digest —
    # defaulted to "yes" without any extra work.
    assert photos[0]["is_user"] == "yes"


def test_ai_view_looks_up_the_self_dive_by_name_not_by_uid(monkeypatch):
    """Regression: a self dive is stored keyed by name (target_uid="" — see
    the /deep-dive endpoint and skill, which always pass "" for is_self),
    never by the caller's own uid. `_ai_view_photos` used to look it up with
    `dive_report_id(target_uid=uid)`, which never matched anything a self
    dive actually wrote — every self dive's web photos silently never showed
    up in the gallery."""
    _no_notes_no_dive(monkeypatch)
    _no_profile_photos(monkeypatch)
    monkeypatch.setattr(main, "read_wiki_context", lambda _db, _uid: "")
    monkeypatch.setattr(main, "get_db", lambda: _Db([]))
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda _db, _uid: "Jane Doe")

    seen_ids = []

    def _read_dive(_db, _uid, report_id):
        seen_ids.append(report_id)
        if report_id == deep_dive.dive_report_id(name="Jane Doe"):
            return {"digest": {"web_images": [
                {"url": "https://web.example/found.jpg", "verified": True},
            ]}}
        return None

    monkeypatch.setattr(deep_dive, "read_dive", _read_dive)

    r = client.get("/wiki/ai-view", headers=_auth(monkeypatch))
    assert r.status_code == 200
    photos = r.json()["photos"]
    assert [p["url"] for p in photos] == ["https://web.example/found.jpg"]
    # the uid-keyed id must never be what's looked up.
    assert deep_dive.dive_report_id(target_uid="me") not in seen_ids


def test_ai_view_recovers_a_deleted_profile_photo_and_tags_it_deleted(monkeypatch):
    """A deleted profile photo is soft-removed from the live grid, so it's no
    longer enumerable from `profile_photo_media` — its own note's stored
    `url`/`source` is the only way it still surfaces, tagged `deleted: true`
    rather than dropped."""
    _no_profile_photos(monkeypatch)
    monkeypatch.setattr(main, "read_wiki_context", lambda _db, _uid: "")
    monkeypatch.setattr(main, "get_db", lambda: _Db([]))
    monkeypatch.setattr(deep_dive, "read_dive", lambda _db, _uid, _rid: None)

    gone_id = photo_notes.photo_id("https://cdn/gone.jpg")
    monkeypatch.setattr(
        photo_notes, "all_notes",
        lambda _db, _uid: {
            gone_id: {
                "context": "", "is_user": "", "status": "deleted",
                "url": "https://cdn/gone.jpg", "source": "profile",
                "embedding": None,
            }
        },
    )

    r = client.get("/wiki/ai-view", headers=_auth(monkeypatch))
    assert r.status_code == 200
    photos = r.json()["photos"]
    assert len(photos) == 1
    assert photos[0]["url"] == "https://cdn/gone.jpg"
    assert photos[0]["source"] == "profile"
    assert photos[0]["deleted"] is True


def test_ai_view_excludes_a_superseded_note_entirely(monkeypatch):
    """`superseded` (the original copy of a "Make public"-promoted photo) is
    internal bookkeeping only — it never comes back, deleted or otherwise."""
    _no_profile_photos(monkeypatch)
    monkeypatch.setattr(main, "read_wiki_context", lambda _db, _uid: "")
    monkeypatch.setattr(deep_dive, "read_dive", lambda _db, _uid, _rid: None)
    monkeypatch.setattr(
        main, "get_db",
        lambda: _Db([_Snap({"image_path": "uploads/me/chat_1.jpg"})]),
    )
    import public_profile
    monkeypatch.setattr(public_profile, "_photo_url", lambda path: f"https://cdn/{path}")

    superseded_id = photo_notes.photo_id("https://cdn/uploads/me/chat_1.jpg")
    monkeypatch.setattr(
        photo_notes, "all_notes",
        lambda _db, _uid: {
            superseded_id: {
                "context": "", "is_user": "yes", "status": "superseded",
                "url": "https://cdn/uploads/me/chat_1.jpg", "source": "chat",
                "embedding": None,
            }
        },
    )

    r = client.get("/wiki/ai-view", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json()["photos"] == []


def test_ai_view_collapses_two_candidates_with_matching_embeddings(monkeypatch):
    """The exact same photo surfaced under two different URLs (e.g. sent in
    chat *and* on the profile grid) only shows once."""
    monkeypatch.setattr(main, "read_wiki_context", lambda _db, _uid: "")
    monkeypatch.setattr(deep_dive, "read_dive", lambda _db, _uid, _rid: None)
    monkeypatch.setattr(
        main.schema, "profile_doc",
        lambda _db, _uid: type("D", (), {"get": lambda s: s, "to_dict": lambda s: {}})(),
    )
    monkeypatch.setattr(
        photo_notes, "profile_photo_media",
        lambda _db, _uid, _prof: [
            {"url": "https://cdn/profile-1.jpg", "embedding": [1.0, 0.0]}
        ],
    )
    monkeypatch.setattr(
        main, "get_db",
        lambda: _Db([_Snap({"image_path": "uploads/me/chat_same.jpg"})]),
    )
    import public_profile
    monkeypatch.setattr(public_profile, "_photo_url", lambda path: f"https://cdn/{path}")

    # the chat photo's own note already carries the same embedding as the
    # profile copy (e.g. cached from an earlier gallery load).
    chat_url = "https://cdn/uploads/me/chat_same.jpg"
    chat_id = photo_notes.photo_id(chat_url)
    monkeypatch.setattr(
        photo_notes, "all_notes",
        lambda _db, _uid: {
            chat_id: {
                "context": "", "is_user": "", "status": "",
                "url": chat_url, "source": "chat", "embedding": [1.0, 0.0],
            }
        },
    )

    r = client.get("/wiki/ai-view", headers=_auth(monkeypatch))
    assert r.status_code == 200
    photos = r.json()["photos"]
    assert len(photos) == 1
    assert photos[0]["source"] == "profile"
