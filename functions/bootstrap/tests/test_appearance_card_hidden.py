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
    # The list is stamped with the report version it was curated against
    # (_DOC carries no created_at, so the stamp is empty here) so a later
    # re-run invalidates it on read.
    assert store["written"] == {
        appearance.HIDDEN_PHOTOS_FIELD: ["users/u1/photos/a.jpg"],
        appearance.HIDDEN_PHOTOS_REPORT_FIELD: "",
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
    # One live CARD id (the face photo), one attributes-only id (a.jpg — not a
    # card photo, founder defect Nov 16 2026), and one stale id no longer in the
    # grid. Only the live card photo survives.
    monkeypatch.setattr(
        appearance, "read_card_hidden",
        lambda db, uid: [
            "users/u1/photos/face.jpg",
            "users/u1/photos/a.jpg",
            "users/u1/photos/gone.jpg",
        ],
    )
    report, *_ = ra.appearance_blocks(object(), "u1")
    assert report["card_hidden_photos"] == ["users/u1/photos/face.jpg"]


def test_hidden_list_is_applied_exactly_including_the_first_pool_photo(monkeypatch):
    """Within one report version the user's curation is honoured exactly:
    hiding EVERY current pool photo (the hero included) leaves the card
    with no photo — the fallback-to-normal-report case the client already
    handles. (Supersedes the 2026-11-02 pool[0] un-hide workaround: with
    run-scoped hidden lists — see test_appearance_card_stale.py — a stale
    list can no longer reach this adapter, so there is nothing to rescue,
    and un-hiding pool[0] only resurrected a photo the user had removed.)"""
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(_DOC))
    # The CARD pool is the selected face+body photos (attributes excluded,
    # founder defect Nov 16 2026). Hiding every card photo — plus an
    # attributes-only id for good measure — empties the card; the meta carries
    # exactly the card pool, never the attributes-only id.
    card_pool = ra._card_photo_pool(_DOC)  # face, body
    monkeypatch.setattr(
        appearance,
        "read_card_hidden",
        lambda db, uid: list(card_pool) + ["users/u1/photos/a.jpg"],
    )
    report, *_ = ra.appearance_blocks(object(), "u1")
    assert report["card_hidden_photos"] == card_pool


def test_rerun_hero_follows_the_new_selection_when_nothing_is_hidden(monkeypatch):
    """On a re-run the user selects a DIFFERENT face photo and no current-
    version hidden list exists (a stale one is scoped out inside
    ``read_card_hidden`` — covered end-to-end in
    test_appearance_card_stale.py); the adapter surfaces no hidden ids, so
    the card hero is the new pool[0]."""
    doc = dict(_DOC)
    doc["face"] = {
        "usable": True, "overall_score": 7.0,
        "source_photos": ["users/u1/photos/new_face.jpg"],
    }
    monkeypatch.setattr(appearance, "get_report", lambda db, uid, rid: dict(doc))
    monkeypatch.setattr(appearance, "read_card_hidden", lambda db, uid: [])
    report, *_ = ra.appearance_blocks(object(), "u1")
    pool = appearance._pool_from_data(doc)
    assert pool[0] == "users/u1/photos/new_face.jpg"
    assert report["card_hidden_photos"] == []


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
