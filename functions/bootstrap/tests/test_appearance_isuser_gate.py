"""NOTE 263 Item 3 — the is-you (``is_user == "yes"``) gate shared by the
appearance run path and the pre-run eligibility sheet.

Only photos CONFIRMED to be the account holder (``user_media.is_user == "yes"``,
set by the ingest face-match pipeline — see :mod:`photo_pipeline`) are
analysable. The server (``_grid_photos`` / ``run_appearance``) and the sheet's
source (``photo_attrs.eligibility``) apply the SAME predicate, so the sheet can
never offer a photo the server would refuse. When a user has photos but none
are confirmed (the demo-test1 fixture: zero ``is_user == "yes"``), the run is
refused with a 400 and eligibility reports ``has_unconfirmed_photos`` so the
sheet shows an honest "confirm a photo is you" prompt instead of running
nothing silently.
"""

import asyncio

import pytest

import appearance
import appearance_engine
import photo_attrs
from test_appearance import FakeDb


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def _seed(db, uid, media):
    """Seed ``uid``'s profile grid + ``user_media`` docs.

    ``media`` is a list of ``(media_id, is_user, shot_type)``; every photo is
    tagged usable for both axes so only the ``is_user`` / shot-type gate is
    under test.
    """
    db.docs[("users", uid, "profile", "main")] = {
        "photos": [
            {"media_id": mid, "order": i} for i, (mid, *_r) in enumerate(media)
        ]
    }
    for mid, is_user, shot in media:
        db.docs[("users", uid, "user_media", mid)] = {
            "storage_path": f"uploads/{uid}/{mid}.jpg",
            "is_user": is_user,
            "attributes": {
                "usable_for_face": True,
                "usable_for_body": True,
                "shot_type": shot,
            },
        }


@pytest.fixture
def _bytes(monkeypatch):
    monkeypatch.setattr(
        appearance_engine.media_embed,
        "download_bytes",
        lambda sp: (b"img", "image/jpeg"),
    )


# --- server run path -----------------------------------------------------------


def test_grid_photos_drops_photos_not_confirmed_as_the_user(_bytes):
    """A grid photo whose ``is_user`` is ``"no"`` or unset is NOT analysable —
    the demo-test1 state (zero ``is_user == "yes"``) yields an empty pool."""
    db = FakeDb()
    _seed(db, "u1", [("m_no", "no", "face"), ("m_unset", "", "upper_body")])
    assert appearance_engine._grid_photos(db, "u1") == []


def test_grid_photos_keeps_a_confirmed_user_photo(_bytes):
    """A photo confirmed as the user (``is_user == "yes"``) is accepted."""
    db = FakeDb()
    _seed(db, "u1", [("m_yes", "yes", "face")])
    photos = appearance_engine._grid_photos(db, "u1")
    assert [p["media_id"] for p in photos] == ["m_yes"]
    assert photos[0]["is_user"] == "yes"


def test_run_appearance_returns_none_when_no_confirmed_photo(_bytes):
    """``run_appearance`` short-circuits to ``None`` (which the
    ``POST /appearance/report`` route maps to the 400 "No confirmed photo of
    you to analyse") when every grid photo is unconfirmed — the exact failure
    Scout hit on demo-test1, with and without an explicit face selection."""
    db = FakeDb()
    _seed(db, "u1", [("m_no", "no", "face")])
    # No selection (chat / auto path).
    assert _run(appearance.run_appearance(db, "u1")) is None
    # Explicit selection of the unconfirmed grid photo (the sheet path Scout
    # reproduced) is still refused — the gate is not bypassed by naming the id.
    assert _run(
        appearance.run_appearance(db, "u1", face_media_ids=["m_no"])
    ) is None


# --- pre-run eligibility sheet source -----------------------------------------


def test_eligibility_excludes_unconfirmed_and_flags_them(monkeypatch):
    """The sheet's source hides unconfirmed photos (same gate as the run path)
    AND sets ``has_unconfirmed_photos`` so the sheet can show the honest
    confirm-a-photo state rather than implying the user has no photos."""
    monkeypatch.setattr(
        "public_profile._photo_url", lambda sp: f"https://x/{sp}"
    )
    db = FakeDb()
    _seed(db, "u1", [("m_no", "no", "face"), ("m_unset", "", "upper_body")])
    out = photo_attrs.eligibility(db, "u1")
    assert out["face"] == [] and out["body"] == []
    assert out["has_unconfirmed_photos"] is True


def test_eligibility_surfaces_a_confirmed_photo(monkeypatch):
    monkeypatch.setattr(
        "public_profile._photo_url", lambda sp: f"https://x/{sp}"
    )
    db = FakeDb()
    _seed(db, "u1", [("m_yes", "yes", "face")])
    out = photo_attrs.eligibility(db, "u1")
    assert [p["media_id"] for p in out["face"]] == ["m_yes"]
    assert out["has_unconfirmed_photos"] is False
