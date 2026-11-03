"""The shareable Appearance report card's hide-from-card list: the analysed
photo pool, server-side validation (only the caller's own photo ids), and
that the list is surfaced on the report meta so the card builder and the
exported share image both honour it. Card-only — hiding never deletes the
photo or its analysis."""

import appearance
import main
import report_adapters as ra
import report_hub
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


_DOC = {
    "id": "current",
    "created_at": None,
    "attributes": {
        "record": {
            "eye_color": {"value": "brown", "source": "stated", "confidence": "high"},
        },
        "source_photos": ["users/u1/photos/a.jpg", "users/u1/photos/b.jpg"],
    },
    "face": {"usable": True, "overall_score": 7.0,
             "source_photos": ["users/u1/photos/face.jpg"]},
    "body": {"usable": True, "overall_score": 6.0,
             "source_photos": ["users/u1/photos/body.jpg"]},
    "photo_count": 4,
}


# --- the analysed-photo pool ---------------------------------------------


def test_pool_is_face_then_body_then_attributes_deduped():
    pool = appearance._pool_from_data(_DOC)
    # Face first, then body, then the attributes grid; deduped, order kept.
    assert pool == [
        "users/u1/photos/face.jpg",
        "users/u1/photos/body.jpg",
        "users/u1/photos/a.jpg",
        "users/u1/photos/b.jpg",
    ]


def test_pool_dedupes_a_photo_used_by_more_than_one_read():
    doc = dict(_DOC)
    doc["face"] = {"source_photos": ["users/u1/photos/a.jpg"]}
    doc["body"] = {"source_photos": ["users/u1/photos/a.jpg"]}
    assert appearance._pool_from_data(doc) == [
        "users/u1/photos/a.jpg",
        "users/u1/photos/b.jpg",
    ]


# --- validation: only the caller's own analysed photo ids ----------------


class _ProfileDoc:
    def __init__(self, store, exists_doc=None):
        self._store = store
        self._exists_doc = exists_doc

    def get(self):
        doc, store = self._exists_doc, self

        class _Snap:
            exists = doc is not None

            def to_dict(self):
                return dict(doc) if doc else None

        return _Snap()

    def set(self, data, merge=False):  # noqa: ARG002 - mirrors firestore
        self._store["written"] = data


def _patch_profile(monkeypatch, store, existing=None):
    ref = _ProfileDoc(store, existing)
    monkeypatch.setattr(appearance.schema, "profile_doc", lambda db, uid: ref)
    return ref


def test_set_hidden_accepts_own_photos_and_persists(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_DOC))
    store = {}
    _patch_profile(monkeypatch, store)
    out = appearance.set_card_hidden(
        object(), "u1", ["users/u1/photos/a.jpg", "users/u1/photos/a.jpg"]
    )
    # Deduped, persisted to the profile field.
    assert out == ["users/u1/photos/a.jpg"]
    assert store["written"] == {
        appearance.HIDDEN_PHOTOS_FIELD: ["users/u1/photos/a.jpg"]
    }


def test_set_hidden_rejects_a_foreign_photo(monkeypatch):
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_DOC))
    store = {}
    _patch_profile(monkeypatch, store)
    try:
        appearance.set_card_hidden(object(), "u1", ["users/someone-else/x.jpg"])
    except ValueError:
        pass
    else:
        raise AssertionError("expected ValueError for a foreign photo id")
    # Nothing written when validation fails.
    assert "written" not in store


def test_read_hidden_missing_profile_is_empty(monkeypatch):
    _patch_profile(monkeypatch, {}, existing=None)
    assert appearance.read_card_hidden(object(), "u1") == []


# --- the share image / card builder honours it ---------------------------


def test_report_meta_carries_only_live_pool_hidden_ids(monkeypatch):
    """The adapter surfaces the hidden list on the report meta, intersected
    with the live analysed pool so a stale id (a photo since removed from the
    pool) self-heals. The on-screen card and the exported 1080x1920 share
    image are both built from this same report, so the shared picture never
    shows a photo the user hid."""
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_DOC))
    # One live id + one stale id that is no longer in the pool.
    monkeypatch.setattr(
        appearance, "read_card_hidden",
        lambda db, uid: ["users/u1/photos/a.jpg", "users/u1/photos/gone.jpg"],
    )
    report, *_ = ra.appearance_blocks(object(), "u1")
    assert report["card_hidden_photos"] == ["users/u1/photos/a.jpg"]


def test_representative_face_photo_is_never_hidden_from_the_card(monkeypatch):
    """§ founder bug 2026-11-02: the share card stayed on a stale photo after a
    re-run while the report sections updated. Root cause: ``card_hidden``
    accumulated across selections until it covered the WHOLE current pool, so
    the card had no photo to draw (visible = pool − hidden = none). The card's
    representative (pool[0], the primary FACE photo) is the hero and must always
    survive so the card reflects the CURRENT selection — the hide-from-card
    control curates only the SECONDARY photos."""
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_DOC))
    pool = appearance._pool_from_data(_DOC)  # face, body, a, b
    # The user has hidden EVERY current pool photo (the accumulated stale list).
    monkeypatch.setattr(appearance, "read_card_hidden", lambda db, uid: list(pool))
    report, *_ = ra.appearance_blocks(object(), "u1")
    hidden = report["card_hidden_photos"]
    assert pool[0] == "users/u1/photos/face.jpg"
    # The hero is never hidden (fails without the fix, which hid the whole pool);
    # the rest stay hidden exactly as the user chose.
    assert pool[0] not in hidden
    assert hidden == pool[1:]


def test_rerun_with_a_new_face_selection_remaps_the_card_hero(monkeypatch):
    """On a re-run the user selects a DIFFERENT face photo; the card hero must
    follow the new selection (the new pool[0]) and never stay pinned by a stale
    card_hidden entry from the old selection."""
    doc = dict(_DOC)
    doc["face"] = {
        "usable": True, "overall_score": 7.0,
        "source_photos": ["users/u1/photos/new_face.jpg"],
    }
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(doc))
    # Stale hidden list: the OLD face photo, the NEW face photo, and the body —
    # all carried over from the prior selection's curation.
    monkeypatch.setattr(
        appearance, "read_card_hidden",
        lambda db, uid: [
            "users/u1/photos/face.jpg",       # old hero — no longer in the pool
            "users/u1/photos/new_face.jpg",   # the new hero
            "users/u1/photos/body.jpg",       # a secondary, still in the pool
        ],
    )
    report, *_ = ra.appearance_blocks(object(), "u1")
    pool = appearance._pool_from_data(doc)
    hidden = report["card_hidden_photos"]
    assert pool[0] == "users/u1/photos/new_face.jpg"
    # The new representative is the hero (not hidden); the old-face id self-heals
    # out (no longer in the pool); body stays hidden within the current set.
    assert "users/u1/photos/new_face.jpg" not in hidden
    assert "users/u1/photos/face.jpg" not in hidden
    assert "users/u1/photos/body.jpg" in hidden


def test_endpoint_requires_auth():
    assert client.post("/appearance/card/hidden").status_code in (401, 403)


def test_endpoint_rejects_foreign_id_with_422(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())

    def _raise(db, uid, ids):
        raise ValueError("not yours")

    monkeypatch.setattr(appearance, "set_card_hidden", _raise)
    resp = client.post(
        "/appearance/card/hidden",
        json={"hidden": ["users/other/x.jpg"]},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 422


def test_endpoint_stores_and_echoes_hidden(monkeypatch):
    monkeypatch.setattr(main, "get_db", lambda: object())
    seen = {}

    def _set(db, uid, ids):
        seen.update(uid=uid, ids=ids)
        return list(ids)

    monkeypatch.setattr(appearance, "set_card_hidden", _set)
    resp = client.post(
        "/appearance/card/hidden",
        json={"hidden": ["users/u1/photos/a.jpg"]},
        headers=_auth(monkeypatch, uid="u1"),
    )
    assert resp.status_code == 200
    assert resp.json() == {"hidden": ["users/u1/photos/a.jpg"]}
    assert seen == {"uid": "u1", "ids": ["users/u1/photos/a.jpg"]}
