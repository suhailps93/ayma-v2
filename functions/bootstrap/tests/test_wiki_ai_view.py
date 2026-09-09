import main
import public_profile
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


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
    monkeypatch.setattr(main, "read_wiki_context", lambda _db, _uid: "the notes")

    class _ProfDoc:
        def get(self):
            return self

        def to_dict(self):
            return {"photos": [{"media_id": "m1"}]}

    monkeypatch.setattr(main.schema, "profile_doc", lambda _db, _uid: _ProfDoc())
    monkeypatch.setattr(
        public_profile, "_photos",
        lambda _db, _uid, _prof: ["https://cdn/profile-1.jpg"],
    )
    monkeypatch.setattr(
        public_profile, "_photo_url", lambda path: f"https://cdn/{path}"
    )
    monkeypatch.setattr(
        main, "get_db",
        lambda: _Db([
            _Snap({"image_path": "uploads/me/chat_1.jpg"}),
            _Snap({"image_path": ""}),  # a text-only turn — skipped
            _Snap({"image_path": "uploads/me/chat_2.jpg"}),
        ]),
    )

    r = client.get("/wiki/ai-view", headers=_auth(monkeypatch))
    assert r.status_code == 200
    body = r.json()
    assert body["text"] == "the notes"
    assert [p["source"] for p in body["photos"]] == ["profile", "chat", "chat"]
    assert body["photos"][0]["url"] == "https://cdn/profile-1.jpg"
    assert body["photos"][1]["url"] == "https://cdn/uploads/me/chat_1.jpg"


def test_ai_view_dedupes_and_requires_auth(monkeypatch):
    monkeypatch.setattr(main, "read_wiki_context", lambda _db, _uid: "")
    monkeypatch.setattr(
        main.schema, "profile_doc",
        lambda _db, _uid: type("D", (), {"get": lambda s: s, "to_dict": lambda s: {}})(),
    )
    monkeypatch.setattr(
        public_profile, "_photos", lambda _db, _uid, _prof: ["https://cdn/dup.jpg"]
    )
    monkeypatch.setattr(public_profile, "_photo_url", lambda _p: "https://cdn/dup.jpg")
    monkeypatch.setattr(
        main, "get_db",
        lambda: _Db([_Snap({"image_path": "uploads/me/chat_1.jpg"})]),
    )

    r = client.get("/wiki/ai-view", headers=_auth(monkeypatch))
    assert r.status_code == 200
    # the chat photo resolves to the same URL as the profile photo — de-duped.
    assert r.json()["photos"] == [{"url": "https://cdn/dup.jpg", "source": "profile"}]

    assert client.get("/wiki/ai-view").status_code in (401, 403)
