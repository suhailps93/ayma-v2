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

    @property
    def id(self):
        return self.key[-1]

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

    def add(self, data):
        d = len(self.key)
        n = sum(1 for k in self.store.keys() if len(k) == d + 1 and k[:d] == self.key)
        ref = _DocRef(self.store, self.key + (f"auto{n + 1}",))
        ref.set(dict(data))
        return (None, ref)

    def stream(self):
        d = len(self.key)
        seen = set()
        for k in list(self.store.keys()):
            if len(k) > d and k[:d] == self.key and k[d] not in seen:
                seen.add(k[d])
                child = self.key + (k[d],)
                yield _Snap(child, self.store.get(child))


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
    assert doc["photo_paths"] == ["uploads/u1/a.jpg", "uploads/u1/b.jpg"]
    stored = db.get(("users", "u1", "physical_attributes", "current"))
    assert stored["fields"]["hair_color"] == {
        "value": "black",
        "source": "photo",
        "confidence": "high",
        "note": "extracted from pictures",
        "photo_ids": ["uploads/u1/a.jpg", "uploads/u1/b.jpg"],
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
        "photo_ids": [],
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
    # explicit call -> a history doc + a trailing [physical:<id>] card marker
    import re as _re

    m = _re.search(r"\[physical:(auto\d+)\]$", out)
    assert m
    assert db.get(("users", "u1", "physical_reports", m.group(1))) is not None


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
    assert r.json() == {
        "record": None, "fields": {}, "photo_count": 0, "photo_paths": [],
        "summary": "", "id": "",
    }


def test_get_physical_attributes_requires_auth():
    assert _client.get("/physical-attributes").status_code in (401, 403)


def test_post_refresh_runs_and_returns_the_record(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    ran = []

    async def _refresh(_db, uid, **kw):
        ran.append((uid, kw))

    monkeypatch.setattr(main.physical_attributes, "refresh", _refresh)
    monkeypatch.setattr(
        main.physical_attributes, "current", lambda _db, uid: dict(_STORED)
    )
    r = _client.post(
        "/physical-attributes/refresh", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200
    assert ran == [("me", {"persist_report": True})]
    assert r.json()["ok"] is True
    assert r.json()["fields"]["hair_color"]["value"] == "black"


def test_post_refresh_out_of_credits_returns_usage_capped(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    def _capped(_uid):
        raise main.token_ledger.TokenCapExceeded("broke")

    monkeypatch.setattr(main.token_ledger, "check", _capped)
    r = _client.post(
        "/physical-attributes/refresh", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200
    assert r.json() == {"usage_capped": True}


def test_post_refresh_rejects_foreign_image_paths(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    r = _client.post(
        "/physical-attributes/refresh",
        headers=_auth(monkeypatch),
        json={"image_paths": ["uploads/someone-else/x.jpg"]},
    )
    assert r.status_code == 403


def test_post_refresh_folds_extra_image_paths_into_the_vision_pass(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(main.token_ledger, "check", lambda _uid: None)
    monkeypatch.setattr(
        main.media_embed, "download_bytes",
        lambda path: (b"bytes:" + path.encode(), "image/png"),
    )
    seen = []

    async def _refresh(_db, uid, **kw):
        seen.append((uid, kw))

    monkeypatch.setattr(main.physical_attributes, "refresh", _refresh)
    monkeypatch.setattr(
        main.physical_attributes, "current", lambda _db, uid: dict(_STORED)
    )
    r = _client.post(
        "/physical-attributes/refresh",
        headers=_auth(monkeypatch),
        json={"image_paths": ["uploads/me/a.jpg", "  ", "uploads/me/b.jpg"]},
    )
    assert r.status_code == 200
    assert len(seen) == 1
    uid, kw = seen[0]
    assert uid == "me"
    assert kw["persist_report"] is True
    assert kw["extra_images"] == [
        (b"bytes:uploads/me/a.jpg", "image/png", "uploads/me/a.jpg"),
        (b"bytes:uploads/me/b.jpg", "image/png", "uploads/me/b.jpg"),
    ]


# --- report persistence + wiki ingest --------------------------------------


def test_refresh_persist_report_writes_history_and_links_current(_patch_vision):
    db = _db_with_two_photos()
    doc = _run(pa.refresh(db, "u1", persist_report=True))

    rid = doc["report_id"]
    assert rid
    hist = db.get(("users", "u1", "physical_reports", rid))
    assert hist is not None
    assert hist["photo_count"] == 2
    assert hist["photo_paths"] == ["uploads/u1/a.jpg", "uploads/u1/b.jpg"]
    assert hist["summary"].startswith("Physical profile —")
    assert hist["fields"]["hair_color"]["value"] == "black"
    # current points at the last explicit run
    cur = db.get(("users", "u1", "physical_attributes", "current"))
    assert cur["report_id"] == rid


def test_refresh_without_persist_report_writes_no_history(_patch_vision):
    db = _db_with_two_photos()
    _run(pa.refresh(db, "u1"))
    assert not any(
        k[:3] == ("users", "u1", "physical_reports") for k in db.keys()
    )
    assert "report_id" not in (
        db.get(("users", "u1", "physical_attributes", "current")) or {}
    )


def test_refresh_ingests_physical_profile_wiki_at_non_public_visibility(
    _patch_vision,
):
    db = _db_with_two_photos()
    _run(pa.refresh(db, "u1", persist_report=True))

    page = db.get(("users", "u1", "wiki_pages", "physical-profile"))
    assert page is not None
    assert page["page_type"] == "physical_profile"
    assert page["visibility"] != "public"
    # explicit run -> promoted into the user's own story
    assert page["visibility"] == "private"
    assert "Apparent from their photos:" in page["ai_body"]
    assert "hair: black" in page["ai_body"]


def test_background_refresh_keeps_wiki_private(_patch_vision):
    db = _db_with_two_photos()
    _run(pa.refresh(db, "u1"))  # background photo-set refresh
    page = db.get(("users", "u1", "wiki_pages", "physical-profile"))
    assert page is not None
    assert page["visibility"] == "private"


def test_refresh_wiki_ingest_replaces_rather_than_appends(_patch_vision):
    db = _db_with_two_photos()
    _run(pa.refresh(db, "u1", persist_report=True))
    _run(pa.refresh(db, "u1", persist_report=True))
    page = db.get(("users", "u1", "wiki_pages", "physical-profile"))
    # one rendering, not two concatenated
    assert page["ai_body"].count("Apparent from their photos:") == 1
    assert page["visibility"] == "private"  # promoted state kept on re-run


# --- GET /physical-attributes-report/{id} + history -------------------------


def test_get_physical_attributes_report_by_id(monkeypatch):
    db = FakeDb(
        {
            ("users", "me", "physical_reports", "r7"): {
                "fields": {
                    "hair_color": {
                        "value": "black", "source": "photo",
                        "confidence": "high", "note": "extracted from pictures",
                    },
                },
                "photo_count": 4,
                "summary": "Physical profile — hair: black (from photos).",
                "model": "gemini-x",
            }
        }
    )
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = _client.get(
        "/physical-attributes-report/r7", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200
    body = r.json()
    assert body["id"] == "r7"
    assert body["photo_count"] == 4
    assert body["fields"]["hair_color"]["value"] == "black"
    assert body["summary"].startswith("Physical profile —")


def test_get_physical_attributes_report_current_falls_back_to_live(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    monkeypatch.setattr(
        main.physical_attributes, "current", lambda _db, uid: dict(_STORED)
    )
    r = _client.get(
        "/physical-attributes-report/current", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200
    assert r.json()["id"] == "current"
    assert r.json()["fields"]["eye_color"]["source"] == "stated"


def test_get_physical_attributes_report_404(monkeypatch):
    db = FakeDb({})
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(
        main.physical_attributes, "current", lambda _db, uid: None
    )
    r = _client.get(
        "/physical-attributes-report/nope", headers=_auth(monkeypatch)
    )
    assert r.status_code == 404


def test_physical_attributes_history_lists_past_runs(monkeypatch):
    db = FakeDb(
        {
            ("users", "me", "physical_reports", "a"): {
                "summary": "Physical profile — hair: black (from photos).",
                "photo_count": 3,
                "fields": {
                    "hair_color": {"value": "black", "source": "photo"},
                    "build": {"value": "athletic", "source": "stated"},
                },
                "created_at": "2026-02-01T00:00:00",
            },
        }
    )
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = _client.get(
        "/physical-attributes/history", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200
    rows = r.json()["reports"]
    assert len(rows) == 1
    assert rows[0]["id"] == "a"
    assert rows[0]["photo_count"] == 3
    assert rows[0]["attribute_count"] == 2
    assert rows[0]["summary"].startswith("Physical profile —")


# --- GET /physical-attributes/schema ----------------------------------------


def test_get_physical_attributes_schema(monkeypatch):
    r = _client.get(
        "/physical-attributes/schema", headers=_auth(monkeypatch)
    )
    assert r.status_code == 200
    fields = {f["field"]: f for f in r.json()["fields"]}
    assert fields["eye_color"]["type"] == "enum"
    assert "unknown" not in fields["eye_color"]["values"]
    assert "brown" in fields["eye_color"]["values"]
    assert fields["height_estimate_cm"]["type"] == "int"
    assert fields["race_ethnicity"]["type"] == "string"


def test_get_physical_attributes_schema_requires_auth():
    assert _client.get("/physical-attributes/schema").status_code in (401, 403)


# --- POST /physical-attributes/correct --------------------------------------


def test_correct_requires_auth():
    r = _client.post(
        "/physical-attributes/correct",
        json={"corrections": [{"field": "eye_color", "value": "blue"}]},
    )
    assert r.status_code in (401, 403)


def test_correct_rejects_unknown_field(monkeypatch):
    db = FakeDb({})
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = _client.post(
        "/physical-attributes/correct",
        headers=_auth(monkeypatch),
        json={"corrections": [{"field": "shoe_size", "value": "10"}]},
    )
    assert r.status_code == 422
    assert "shoe_size" in r.json()["detail"]
    # nothing written
    assert db.get(("users", "me", "profile", "main")) is None


def test_correct_rejects_invalid_enum_value(monkeypatch):
    db = FakeDb({})
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = _client.post(
        "/physical-attributes/correct",
        headers=_auth(monkeypatch),
        json={"corrections": [{"field": "eye_color", "value": "purple"}]},
    )
    assert r.status_code == 422
    assert "eye_color" in r.json()["detail"]
    assert db.get(("users", "me", "profile", "main")) is None


def test_correct_rejects_non_numeric_height(monkeypatch):
    db = FakeDb({})
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = _client.post(
        "/physical-attributes/correct",
        headers=_auth(monkeypatch),
        json={"corrections": [{"field": "height_estimate_cm", "value": "tall"}]},
    )
    assert r.status_code == 422


def test_correct_rejects_a_bad_entry_in_a_batch_and_writes_nothing(monkeypatch):
    # One invalid correction rejects the whole batch — never half-applied.
    db = FakeDb({})
    monkeypatch.setattr(main, "get_db", lambda: db)
    r = _client.post(
        "/physical-attributes/correct",
        headers=_auth(monkeypatch),
        json={
            "corrections": [
                {"field": "eye_color", "value": "blue"},
                {"field": "build", "value": "not-a-real-build"},
            ]
        },
    )
    assert r.status_code == 422
    assert db.get(("users", "me", "profile", "main")) is None


def test_correct_writes_profile_main_and_schedules_refresh(monkeypatch):
    db = FakeDb({("users", "me", "profile", "main"): {"name": "Sam"}})
    monkeypatch.setattr(main, "get_db", lambda: db)
    ran = []

    async def _refresh(_db, uid, **kw):
        ran.append((uid, kw))

    monkeypatch.setattr(main.physical_attributes, "refresh", _refresh)
    r = _client.post(
        "/physical-attributes/correct",
        headers=_auth(monkeypatch),
        json={
            "corrections": [
                {"field": "eye_color", "value": "BLUE"},
                {"field": "height_estimate_cm", "value": 178},
                {"field": "race_ethnicity", "value": "Mixed"},
            ]
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["fields"] == {
        "eye_color": "blue",
        "height_estimate_cm": 178,
        "race_ethnicity": "Mixed",
    }
    prof = db.get(("users", "me", "profile", "main"))
    assert prof["eye_color"] == "blue"
    assert prof["height_estimate_cm"] == 178
    assert prof["race_ethnicity"] == "Mixed"
    assert prof["name"] == "Sam"  # merge=True kept the rest of the doc
    # the background refresh trigger fired, mirroring every other
    # physical-attrs write path (photo upload/reorder/remove).
    assert ran == [("me", {})]


def test_correction_survives_a_fresh_report_run(_patch_vision, monkeypatch):
    """End-to-end: a correction really is prioritised over the photo read on
    a genuinely fresh regeneration, not just in the write that made it."""
    db = _db_with_two_photos()
    monkeypatch.setattr(main, "get_db", lambda: db)
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "u1"}
    )

    r = _client.post(
        "/physical-attributes/correct",
        headers={"Authorization": "Bearer valid"},
        json={"corrections": [{"field": "eye_color", "value": "blue"}]},
    )
    assert r.status_code == 200
    # The endpoint's own background refresh already ran synchronously under
    # TestClient — confirm it reflects the correction.
    cur = db.get(("users", "u1", "physical_attributes", "current"))
    assert cur["fields"]["eye_color"] == {
        "value": "blue", "source": "stated",
        "confidence": "high", "note": "from your answers", "photo_ids": [],
    }

    # Now simulate the user explicitly re-running the report (a fresh,
    # independent call, no re-use of the earlier result) — _patch_vision's
    # stub still reports eye_color="brown" from the photos. The correction
    # must still win.
    doc = _run(pa.refresh(db, "u1", persist_report=True))
    assert doc["fields"]["eye_color"] == {
        "value": "blue", "source": "stated",
        "confidence": "high", "note": "from your answers", "photo_ids": [],
    }


# --- Story-public visibility (§ founder follow-up 2026-09-20: attributes -----
# are PRIVATE BY DEFAULT on the Story-public Living Report) --------------------


def test_public_fields_is_empty_for_a_fresh_never_toggled_user():
    db = FakeDb()
    assert pa.public_fields(db, "u1") == set()
    assert pa.is_public(db, "u1", "eye_color") is False


def test_public_fields_is_empty_when_no_visibility_doc_exists_at_all():
    # A user who has a `current` record but has never touched the
    # make-public/make-private quick action — the everyday "brand new
    # field" case — still starts fully private, not just an already-known
    # field with no explicit choice recorded.
    db = FakeDb({
        ("users", "u1", "physical_attributes", "current"): {
            "fields": {"eye_color": {"value": "brown", "source": "stated", "confidence": "high"}},
        },
    })
    assert pa.public_fields(db, "u1") == set()


def test_set_public_true_then_read_back():
    db = FakeDb()
    assert pa.set_public(db, "u1", "eye_color", True) is True
    assert pa.public_fields(db, "u1") == {"eye_color"}
    assert pa.is_public(db, "u1", "eye_color") is True
    # an untouched field stays private even after a sibling field is made
    # public.
    assert pa.is_public(db, "u1", "hair_color") is False


def test_set_public_false_clears_it_again():
    db = FakeDb()
    pa.set_public(db, "u1", "eye_color", True)
    assert pa.set_public(db, "u1", "eye_color", False) is True
    assert pa.public_fields(db, "u1") == set()
    assert pa.is_public(db, "u1", "eye_color") is False


def test_set_public_accumulates_multiple_fields_without_clobbering():
    """A read-modify-write, not a bare nested-merge `set()` — making a
    second field public must not silently un-publish the first."""
    db = FakeDb()
    pa.set_public(db, "u1", "eye_color", True)
    pa.set_public(db, "u1", "build", True)
    assert pa.public_fields(db, "u1") == {"eye_color", "build"}


def test_set_public_rejects_an_unrecognised_field():
    db = FakeDb()
    assert pa.set_public(db, "u1", "not_a_real_field", True) is False
    assert pa.public_fields(db, "u1") == set()


def test_public_fields_never_wiped_by_a_refresh(_patch_vision):
    """§ the reason the visibility doc lives in its OWN sibling doc, not
    inside `current`: `refresh()` fully overwrites `current` on every
    photo-pipeline run. A user's public-attribute choices must survive
    that, silent background refreshes included."""
    db = _db_with_two_photos()
    pa.set_public(db, "u1", "eye_color", True)
    assert pa.public_fields(db, "u1") == {"eye_color"}
    _run(pa.refresh(db, "u1"))
    assert pa.public_fields(db, "u1") == {"eye_color"}
