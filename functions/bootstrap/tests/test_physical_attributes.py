import asyncio

import gemini
import media_embed
import physical_attributes as pa
import pytest
import wiki_query
from skills import make_session_tool_fns, session_tool_declarations


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# --- a tiny path-keyed Firestore fake --------------------------------------


class _Snap:
    def __init__(self, key, data):
        self.id = key[-1]
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return None if self._data is None else dict(self._data)


class _DocRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def collection(self, name):
        return _CollRef(self.store, self.key + (name,))

    def get(self):
        return _Snap(self.key, self.store.get(self.key))

    def set(self, data, merge=False):
        cur = self.store.get(self.key)
        if merge and isinstance(cur, dict):
            self.store[self.key] = {**cur, **data}
        else:
            self.store[self.key] = dict(data)


class _CollRef:
    def __init__(self, store, key):
        self.store, self.key = store, key

    def document(self, doc_id):
        return _DocRef(self.store, self.key + (doc_id,))

    def stream(self):
        d = len(self.key)
        seen = set()
        for k in list(self.store.keys()):
            if len(k) > d and k[:d] == self.key and k[d] not in seen:
                seen.add(k[d])
                yield _Snap(self.key + (k[d],), {"_": True})


class FakeDb:
    def __init__(self, docs=None):
        self.docs = dict(docs or {})

    def get(self, key):
        return self.docs.get(key)

    def keys(self):
        return self.docs.keys()

    def __setitem__(self, key, value):
        self.docs[key] = value

    def collection(self, name):
        return _CollRef(self, (name,))


# --- merge precedence ------------------------------------------------------


def test_merge_stated_beats_photo():
    photo = {
        f: {"value": pa._blank_value(f), "confidence": "low"} for f in pa.fields()
    }
    photo["eye_color"] = {"value": "brown", "confidence": "high"}
    photo["hair_color"] = {"value": "black", "confidence": "medium"}
    stated = {"eye_color": "blue"}

    rec = pa.merge(photo, stated)
    assert rec["eye_color"] == {
        "value": "blue",
        "source": "stated",
        "confidence": "high",
        "note": "from your answers",
    }
    # photo-only field keeps source=photo and its note.
    assert rec["hair_color"]["value"] == "black"
    assert rec["hair_color"]["source"] == "photo"
    assert rec["hair_color"]["note"] == "extracted from pictures"


def test_merge_unknown_on_both_sides_is_none():
    photo = {
        f: {"value": pa._blank_value(f), "confidence": "low"} for f in pa.fields()
    }
    rec = pa.merge(photo, {})
    assert rec["build"] == {
        "value": "unknown",
        "source": "none",
        "confidence": "none",
        "note": "",
    }
    assert rec["height_estimate_cm"]["value"] is None
    assert rec["height_estimate_cm"]["source"] == "none"


def test_flat_mirror_drops_unknowns():
    photo = {
        f: {"value": pa._blank_value(f), "confidence": "low"} for f in pa.fields()
    }
    photo["skin_tone"] = {"value": "olive", "confidence": "low"}
    rec = pa.merge(photo, {"height_estimate_cm": 181})
    flat = pa.flat_mirror(rec)
    assert flat == {"skin_tone": "olive", "height_estimate_cm": 181}


# --- the wiki scan -------------------------------------------------------


def test_scan_wiki_pulls_explicit_self_reports():
    text = (
        "She has curly brown hair and green eyes. I'm athletic build and "
        "about 178 cm tall, ethnically South Asian."
    )
    found = pa._scan_wiki(text)
    assert found["hair_color"] == "brown"
    assert found["hair_type"] == "curly"
    assert found["eye_color"] == "green"
    assert found["build"] == "athletic"
    assert found["height_estimate_cm"] == 178
    assert found["race_ethnicity"] == "South Asian"


# --- refresh writes both docs -----------------------------------------------


@pytest.fixture
def _patch_vision(monkeypatch):
    async def _json(contents, system_prompt, response_schema=None, **kw):
        assert kw.get("images") and len(kw["images"]) == 2
        assert kw.get("feature") == "physical_attrs"
        return {
            "race_ethnicity": {"value": "unknown", "confidence": "low"},
            "skin_tone": {"value": "medium", "confidence": "low"},
            "eye_color": {"value": "brown", "confidence": "medium"},
            "hair_color": {"value": "black", "confidence": "high"},
            "hair_length": {"value": "short", "confidence": "medium"},
            "hair_type": {"value": "straight", "confidence": "low"},
            "height_estimate_cm": {"value": "unknown", "confidence": "low"},
            "weight_estimate_kg": {"value": "unknown", "confidence": "low"},
            "build": {"value": "average", "confidence": "low"},
            "facial_hair": {"value": "beard", "confidence": "high"},
            "glasses": {"value": "yes", "confidence": "high"},
            "visible_tattoos": {"value": "no", "confidence": "medium"},
            "visible_piercings": {"value": "no", "confidence": "medium"},
            "distinguishing_features": {"value": "", "confidence": "low"},
        }

    monkeypatch.setattr(gemini, "generate_json", _json)
    monkeypatch.setattr(
        media_embed, "download_bytes", lambda p: (b"jpgbytes", "image/jpeg")
    )
    monkeypatch.setattr(wiki_query, "read_wiki_context", lambda _db, _uid: "")


def _db_with_two_photos(**profile_extra):
    prof = {
        "name": "Sam",
        "photos": [
            {"media_id": "m1", "order": 0},
            {"media_id": "m2", "order": 1},
        ],
        **profile_extra,
    }
    return FakeDb(
        {
            ("users", "u1", "profile", "main"): prof,
            ("users", "u1", "user_media", "m1"): {"storage_path": "uploads/u1/a.jpg"},
            ("users", "u1", "user_media", "m2"): {"storage_path": "uploads/u1/b.jpg"},
        }
    )


def test_refresh_writes_record_and_flat_mirror(_patch_vision):
    db = _db_with_two_photos()
    doc = _run(pa.refresh(db, "u1"))

    assert doc is not None and doc["photo_count"] == 2
    stored = db.get(("users", "u1", "physical_attributes", "current"))
    assert stored["fields"]["hair_color"] == {
        "value": "black",
        "source": "photo",
        "confidence": "high",
        "note": "extracted from pictures",
    }
    assert stored["fields"]["height_estimate_cm"]["source"] == "none"

    mirror = db.get(("users", "u1", "profile", "main"))["physical_attrs"]
    assert mirror["hair_color"] == "black"
    assert mirror["glasses"] == "yes"
    assert "height_estimate_cm" not in mirror  # unknown -> not mirrored


def test_refresh_stated_profile_field_wins_over_photo(_patch_vision):
    # An explicit self-report on profile/main beats the photo read.
    db = _db_with_two_photos(eye_color="blue")
    _run(pa.refresh(db, "u1"))
    fields = db.get(("users", "u1", "physical_attributes", "current"))["fields"]
    assert fields["eye_color"] == {
        "value": "blue",
        "source": "stated",
        "confidence": "high",
        "note": "from your answers",
    }


def test_refresh_no_photos_returns_none(_patch_vision):
    db = FakeDb({("users", "u1", "profile", "main"): {"name": "Sam"}})
    assert _run(pa.refresh(db, "u1")) is None
    assert db.get(("users", "u1", "physical_attributes", "current")) is None


def test_backfill_only_touches_users_without_a_record(_patch_vision, monkeypatch):
    db = _db_with_two_photos()
    db[("users", "u2", "profile", "main")] = {
        "name": "Kai", "photos": [{"media_id": "x", "order": 0}]
    }
    db[("users", "u2", "user_media", "x")] = {"storage_path": "uploads/u2/x.jpg"}
    db[("users", "u2", "physical_attributes", "current")] = {"fields": {}}

    out = _run(pa.backfill_missing(db, user_limit=10))
    assert out == {"users": 1, "refreshed": 1}
    assert db.get(("users", "u1", "physical_attributes", "current")) is not None


# --- the skill -----------------------------------------------------------


def test_skill_is_registered_with_no_params():
    decl = next(
        d
        for d in session_tool_declarations()
        if d["name"] == "analyze_physical_attributes"
    )
    assert decl["parameters"]["properties"] == {}


def test_skill_runs_refresh_and_returns_a_summary(_patch_vision):
    db = _db_with_two_photos()
    fn = make_session_tool_fns(db, "u1")["analyze_physical_attributes"]
    out = _run(fn())
    assert out.startswith("Physical profile —")
    assert "hair: black (from photos)" in out
    assert db.get(("users", "u1", "physical_attributes", "current")) is not None


def test_skill_asks_for_a_photo_when_there_is_none(_patch_vision):
    db = FakeDb({("users", "u1", "profile", "main"): {"name": "Sam"}})
    fn = make_session_tool_fns(db, "u1")["analyze_physical_attributes"]
    assert "add at least one profile photo" in _run(fn())


# --- the endpoints -----------------------------------------------------------

from fastapi.testclient import TestClient  # noqa: E402
from firebase_admin import auth as firebase_auth  # noqa: E402

import main  # noqa: E402

_client = TestClient(main.app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "me"}
    )
    return {"Authorization": "Bearer valid"}


_STORED = {
    "fields": {
        "hair_color": {
            "value": "black", "source": "photo",
            "confidence": "high", "note": "extracted from pictures",
        },
        "eye_color": {
            "value": "blue", "source": "stated",
            "confidence": "high", "note": "from your answers",
        },
    },
    "photo_count": 3,
    "model": "gemini-x",
    "updated_at": None,
}


def test_get_physical_attributes_returns_the_record(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(
        main.physical_attributes, "current", lambda _db, uid: dict(_STORED)
    )
    r = _client.get("/physical-attributes", headers=_auth(monkeypatch))
    assert r.status_code == 200
    body = r.json()
    assert body["photo_count"] == 3
    assert body["fields"]["eye_color"]["source"] == "stated"
    assert body["record"]["model"] == "gemini-x"


def test_get_physical_attributes_empty_when_never_built(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(
        main.physical_attributes, "current", lambda _db, uid: None
    )
    r = _client.get("/physical-attributes", headers=_auth(monkeypatch))
    assert r.status_code == 200
    assert r.json() == {"record": None, "fields": {}, "photo_count": 0}


def test_get_physical_attributes_requires_auth():
    assert _client.get("/physical-attributes").status_code in (401, 403)


def test_post_refresh_runs_and_returns_the_record(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    ran = []

    async def _refresh(_db, uid):
        ran.append(uid)

    monkeypatch.setattr(main.physical_attributes, "refresh", _refresh)
    monkeypatch.setattr(
        main.physical_attributes, "current", lambda _db, uid: dict(_STORED)
    )
    r = _client.post(
        "/physical-attributes/refresh", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200
    assert ran == ["me"]
    assert r.json()["ok"] is True
    assert r.json()["fields"]["hair_color"]["value"] == "black"
