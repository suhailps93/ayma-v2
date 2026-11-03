import main
import photo_pipeline
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "u-7"}
    )
    return {"Authorization": "Bearer valid"}


def test_media_requires_a_token():
    resp = client.post("/media", json={"storage_path": "uploads/u-7/a.jpg"})
    assert resp.status_code in (401, 403)


def test_media_rejects_a_path_outside_the_callers_uploads(monkeypatch):
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/someone-else/a.jpg"},
    )
    assert resp.status_code == 403


def test_media_runs_the_pipeline_and_returns_its_status(monkeypatch):
    called = {}

    async def _fake_process(db, uid, storage_path, context, **kw):
        called.update(uid=uid, path=storage_path, context=context, kw=kw)
        return {
            "media_id": "media-xyz",
            "moderation_status": "approved",
            "published": True,
            "reason": "",
            "attributes": {"hair_color": "brown"},
            "caption": "a person outside",
        }

    monkeypatch.setattr(photo_pipeline, "process", _fake_process)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/profile_1.jpg", "context": "profile"},
    )
    assert resp.status_code == 200
    assert resp.json() == {
        "ok": True,
        "media_id": "media-xyz",
        "moderation_status": "approved",
        "published": True,
        "reason": "",
        "photo_attrs": {"hair_color": "brown"},
    }
    assert called["uid"] == "u-7"
    assert called["path"] == "uploads/u-7/profile_1.jpg"
    assert called["kw"]["wiki_uids"] == ["u-7"]


def test_media_forwards_caption_context_to_the_pipeline(monkeypatch):
    called = {}

    async def _fake_process(db, uid, storage_path, context, **kw):
        called.update(kw=kw)
        return {
            "media_id": "media-xyz",
            "moderation_status": "approved",
            "published": True,
            "reason": "",
            "attributes": {"hair_color": "brown"},
            "caption": "a person outside",
        }

    monkeypatch.setattr(photo_pipeline, "process", _fake_process)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={
            "storage_path": "uploads/u-7/chat_1.jpg",
            "context": "chat",
            "caption_context": "just got back from the coast, feeling great",
        },
    )
    assert resp.status_code == 200
    assert (
        called["kw"]["accompanying_text"]
        == "just got back from the coast, feeling great"
    )


def test_media_caption_context_defaults_to_empty(monkeypatch):
    called = {}

    async def _fake_process(db, uid, storage_path, context, **kw):
        called.update(kw=kw)
        return {
            "media_id": "media-xyz",
            "moderation_status": "approved",
            "published": True,
            "reason": "",
            "attributes": {"hair_color": "brown"},
            "caption": "a person outside",
        }

    monkeypatch.setattr(photo_pipeline, "process", _fake_process)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/profile_1.jpg", "context": "profile"},
    )
    assert resp.status_code == 200
    assert called["kw"]["accompanying_text"] == ""


def test_media_reports_a_flagged_photo_without_publishing(monkeypatch):
    async def _flagged(db, uid, storage_path, context, **kw):
        return {
            "media_id": "m-flag",
            "moderation_status": "flagged",
            "published": False,
            "reason": "nudity",
            "attributes": None,
            "caption": "",
        }

    monkeypatch.setattr(photo_pipeline, "process", _flagged)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/bad.jpg", "context": "profile"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["published"] is False
    assert body["moderation_status"] == "flagged"
    assert body["reason"] == "nudity"


def test_media_schedules_auto_analysis_for_a_chat_attachment(monkeypatch):
    # Only a chat/DM attachment triggers analysis directly from /media — a
    # profile-grid photo doesn't become visible (or analysed) until it's
    # actually added to the grid (§ appearance batching).
    seen = []

    async def _spy(_db, uid, storage_path, **kw):
        seen.append((uid, storage_path, kw))

    monkeypatch.setattr(main.auto_analysis, "analyse_photo", _spy)

    async def _fake_process(db, uid, storage_path, context, **kw):
        return {
            "media_id": "m1",
            "moderation_status": "approved",
            "published": True,
            "reason": "",
            "attributes": {"shot_type": "face"},
            "caption": "",
            "embedding": [0.1, 0.2],
        }

    monkeypatch.setattr(photo_pipeline, "process", _fake_process)
    monkeypatch.setattr(main, "get_db", lambda: object())

    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/p.jpg", "context": "chat"},
    )
    assert resp.status_code == 200
    # TestClient drains background tasks after the response.
    assert len(seen) == 1
    uid, storage_path, kw = seen[0]
    assert (uid, storage_path) == ("u-7", "uploads/u-7/p.jpg")
    assert kw["embedding"] == [0.1, 0.2]
    assert kw["attributes"] == {"shot_type": "face"}


def test_media_profile_context_does_not_trigger_analysis_directly(monkeypatch):
    # A profile-grid upload's analysis is deferred to POST /media/photos (or
    # /media/photos/batch) — triggering it here too used to double-analyse
    # every profile upload (§ appearance report v2).
    seen = []

    async def _spy(_db, uid, storage_path, **kw):
        seen.append((uid, storage_path, kw))

    monkeypatch.setattr(main.auto_analysis, "analyse_photo", _spy)

    async def _fake_process(db, uid, storage_path, context, **kw):
        return {
            "media_id": "m1", "moderation_status": "approved", "published": True,
            "reason": "", "attributes": {"shot_type": "face"}, "caption": "",
            "embedding": [0.1, 0.2],
        }

    monkeypatch.setattr(photo_pipeline, "process", _fake_process)
    monkeypatch.setattr(main, "get_db", lambda: object())

    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/p.jpg", "context": "profile"},
    )
    assert resp.status_code == 200
    assert seen == []


def test_media_photos_add_runs_the_batch_pipeline(monkeypatch):
    import photo_ops

    seen = []

    async def _spy(db, uid, photos, *, source="add_photos"):
        seen.append((uid, photos, source))

    monkeypatch.setattr(main.appearance, "run_batch_photos", _spy)
    monkeypatch.setattr(
        photo_ops, "add_photo", lambda db, uid, mid: [{"media_id": mid}]
    )
    monkeypatch.setattr(
        main, "_media_record",
        lambda uid, mid: {
            "storage_path": "uploads/u-7/grid.jpg",
            "embedding": [0.3, 0.4],
            "attributes": {"shot_type": "full_body"},
        },
    )
    monkeypatch.setattr(main, "get_db", lambda: object())

    resp = client.post(
        "/media/photos", headers=_auth(monkeypatch), json={"media_id": "m-42"}
    )
    assert resp.status_code == 200
    assert len(seen) == 1
    uid, photos, source = seen[0]
    assert uid == "u-7"
    assert photos == [("uploads/u-7/grid.jpg", [0.3, 0.4], {"shot_type": "full_body"})]
    assert source == "add_photo"


def test_media_photos_batch_adds_all_and_runs_one_batch(monkeypatch):
    import photo_ops

    seen = []

    async def _spy(db, uid, photos, *, source="add_photos"):
        seen.append((uid, photos, source))

    monkeypatch.setattr(main.appearance, "run_batch_photos", _spy)
    monkeypatch.setattr(
        photo_ops, "add_photos",
        lambda db, uid, mids: {
            "photos": [{"media_id": m} for m in mids],
            "added": list(mids), "failed": [],
        },
    )
    records = {
        "m-1": {"storage_path": "uploads/u-7/a.jpg", "embedding": [0.1], "attributes": {}},
        "m-2": {"storage_path": "uploads/u-7/b.jpg", "embedding": [0.2], "attributes": {}},
    }
    monkeypatch.setattr(main, "_media_record", lambda uid, mid: records[mid])
    monkeypatch.setattr(main, "get_db", lambda: object())

    resp = client.post(
        "/media/photos/batch",
        headers=_auth(monkeypatch),
        json={"media_ids": ["m-1", "m-2"]},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["added"] == ["m-1", "m-2"] and body["failed"] == []
    assert len(seen) == 1
    uid, photos, source = seen[0]
    assert uid == "u-7"
    assert {p[0] for p in photos} == {"uploads/u-7/a.jpg", "uploads/u-7/b.jpg"}
    assert source == "add_photos_batch"


def test_media_photos_batch_requires_at_least_one_id(monkeypatch):
    resp = client.post(
        "/media/photos/batch", headers=_auth(monkeypatch), json={"media_ids": []},
    )
    assert resp.status_code == 422


def _stub_refresh(monkeypatch):
    async def _noop(*_a, **_k):
        return None

    monkeypatch.setattr(main.physical_attributes, "refresh", _noop)
    monkeypatch.setattr(main, "get_db", lambda: object())


def test_media_photos_remove_hides_from_public(monkeypatch):
    import photo_ops

    seen = []
    monkeypatch.setattr(
        photo_ops, "remove_photo",
        lambda db, uid, mid: seen.append((uid, mid)) or [{"media_id": "keep"}],
    )
    _stub_refresh(monkeypatch)
    resp = client.post("/media/photos/m-9/remove", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json()["photos"] == [{"media_id": "keep"}]
    assert seen == [("u-7", "m-9")]


def test_media_photos_set_primary(monkeypatch):
    import photo_ops

    seen = []
    monkeypatch.setattr(
        photo_ops, "set_primary",
        lambda db, uid, mid: seen.append((uid, mid)) or [{"media_id": mid}],
    )
    _stub_refresh(monkeypatch)
    resp = client.post("/media/photos/m-3/primary", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json()["photos"] == [{"media_id": "m-3"}]
    assert seen == [("u-7", "m-3")]


def test_media_photos_delete_permanent_passes_the_bucket(monkeypatch):
    import photo_ops

    seen = []
    sentinel = object()
    monkeypatch.setattr(
        photo_ops, "delete_photo_permanent",
        lambda db, uid, mid, bucket: seen.append((uid, mid, bucket)) or [],
    )
    monkeypatch.setattr(main, "_bucket", lambda: sentinel)
    _stub_refresh(monkeypatch)
    resp = client.post("/media/photos/m-x/delete", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json()["photos"] == []
    assert seen == [("u-7", "m-x", sentinel)]


def test_media_photos_mutations_require_a_token():
    for path in ("/media/photos/m/remove", "/media/photos/m/primary",
                 "/media/photos/m/delete"):
        assert client.post(path).status_code in (401, 403)


def test_media_502_when_pipeline_fails(monkeypatch):
    async def _boom(*_a, **_k):
        raise RuntimeError("vertex is grumpy")

    monkeypatch.setattr(photo_pipeline, "process", _boom)
    monkeypatch.setattr(main, "get_db", lambda: object())
    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/x.jpg"},
    )
    assert resp.status_code == 502


# --- newly-added photo reliably reaches the grid (founder bug: "re-run isn't
# taking my latest images") -------------------------------------------------


class _MediaSnap:
    def __init__(self, data):
        self._data = data

    @property
    def exists(self):
        return self._data is not None

    def to_dict(self):
        return dict(self._data) if self._data is not None else None


class _MediaDocRef:
    def __init__(self, store, key):
        self._store, self._key = store, key

    def get(self):
        return _MediaSnap(self._store.get(self._key))

    def set(self, payload, merge=False):
        cur = dict(self._store.get(self._key) or {}) if merge else {}
        cur.update(payload)
        self._store[self._key] = cur

    def collection(self, name):
        return _MediaCollRef(self._store, self._key + (name,))


class _MediaCollRef:
    def __init__(self, store, key):
        self._store, self._key = store, key

    def document(self, name):
        return _MediaDocRef(self._store, self._key + (name,))


class _MediaFakeDb:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _MediaCollRef(self.docs, (name,))


def test_profile_register_auto_grids_an_approved_heif_so_rerun_sees_it(monkeypatch):
    # § appearance re-run staleness (founder, 2026-11-02, live): "Whenever I
    # rerun the appearance report it's not taking the latest images, it's still
    # the old one." Root cause reproduced from his staging specimen: a HEIF
    # (photo_1792823550768_0.heif) uploaded + approved but NEVER entered
    # PF_PHOTOS, because gridding depended on a SEPARATE client call after
    # register — dropped for a slow HEIF. An un-gridded photo is invisible to
    # schema.analysis_photo_entries, so the Appearance re-run can't analyse it.
    # POST /media (context=profile, approved) must now put the photo on the grid
    # itself, so the newest image reliably enters the analysis set.
    import schema
    import photo_ops

    db = _MediaFakeDb()
    heif_path = "uploads/u-7/photo_1792823550768_0.heif"

    async def _fake_process(_db, uid, storage_path, context, **kw):
        # The pipeline creates the approved user_media doc (as it did for the
        # real orphan) — so the auto-grid step has an approved photo to add.
        _MediaDocRef(db.docs, ("users", uid, schema.USER_MEDIA, "m-heif")).set(
            {
                "storage_path": storage_path,
                "source": "profile",
                schema.MEDIA_MODERATION_STATUS: schema.MEDIA_STATUS_APPROVED,
                "attributes": {"shot_type": "full_body"},
            }
        )
        return {
            "media_id": "m-heif",
            "moderation_status": schema.MEDIA_STATUS_APPROVED,
            "published": True,
            "reason": "",
            "attributes": {"shot_type": "full_body"},
            "caption": "",
            "embedding": [0.1, 0.2],
        }

    monkeypatch.setattr(photo_pipeline, "process", _fake_process)
    monkeypatch.setattr(main, "get_db", lambda: db)

    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": heif_path, "context": "profile"},
    )
    assert resp.status_code == 200
    assert resp.json()["media_id"] == "m-heif"

    # The HEIF is now on the grid — WITHOUT a separate POST /media/photos call.
    grid = photo_ops.list_photos(db, "u-7")
    assert [p["media_id"] for p in grid] == ["m-heif"], (
        "an approved profile upload must auto-grid so a dropped client grid-add "
        "can't orphan it (this assertion fails without the fix)"
    )
    # ...and therefore it is in the set the Appearance analysis / pre-run sheet
    # reads, so a re-run takes the latest image.
    prof = (
        db.collection("users").document("u-7")
        .collection("profile").document("main").get().to_dict()
    )
    entries = schema.analysis_photo_entries(prof)
    assert "m-heif" in [e.get("media_id") for e in entries]


def test_profile_register_does_not_grid_a_flagged_photo(monkeypatch):
    # The auto-grid is gated on approval: a moderation-flagged profile upload
    # must never land on the public grid.
    import schema
    import photo_ops

    db = _MediaFakeDb()

    async def _fake_process(_db, uid, storage_path, context, **kw):
        return {
            "media_id": "m-bad",
            "moderation_status": "flagged",
            "published": False,
            "reason": "nope",
            "attributes": None,
            "caption": "",
            "embedding": None,
        }

    monkeypatch.setattr(photo_pipeline, "process", _fake_process)
    monkeypatch.setattr(main, "get_db", lambda: db)

    resp = client.post(
        "/media",
        headers=_auth(monkeypatch),
        json={"storage_path": "uploads/u-7/bad.heic", "context": "profile"},
    )
    assert resp.status_code == 200
    assert photo_ops.list_photos(db, "u-7") == []
