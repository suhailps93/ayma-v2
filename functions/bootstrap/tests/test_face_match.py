"""Unit tests for face_match.py (ARCHITECTURE.md §2.5).

Verifies:
- Verdict mapping (self, not_self, unknown).
- Unknown path on failure / unreadable images.
- Cache hit = no second call.
- Reference resolution helper: same account only (verified selfie + user_media).
- classify_photo helper.
"""

import asyncio
import pytest

import biometric_consent
import face_match
import gemini
import media_embed
import schema


@pytest.fixture(autouse=True)
def _clear():
    face_match.clear_cache()
    yield
    face_match.clear_cache()


def _run(coro):
    return asyncio.run(coro)


class _DocSnap:
    def __init__(self, data, exists=True):
        self._data = data
        self.exists = exists

    def to_dict(self):
        return self._data


class _FakeDb:
    def __init__(self, users_data=None, user_media=None):
        self._users = users_data or {}
        self._media = user_media or {}

    def collection(self, name):
        class _Coll:
            def __init__(coll_self, coll_name):
                coll_self.name = coll_name

            def document(coll_self, doc_id=""):
                class _Doc:
                    def __init__(doc_self, d_id):
                        doc_self.id = d_id

                    def get(doc_self):
                        if coll_self.name == "users":
                            d = self._users.get(doc_self.id)
                            return _DocSnap(d, exists=(d is not None))
                        return _DocSnap(None, exists=False)

                    def collection(doc_self, sub_name):
                        class _SubColl:
                            def stream(sub_self):
                                if coll_self.name == "users" and sub_name == "user_media":
                                    media_list = self._media.get(doc_self.id, [])
                                    return [_DocSnap(m, exists=True) for m in media_list]
                                return []
                        return _SubColl()

                return _Doc(doc_id)
        return _Coll(name)


def test_verdict_mapping_self(monkeypatch):
    calls = []

    async def _fake_json(*args, **kwargs):
        calls.append(kwargs)
        return {
            "verdict": "self",
            "confidence": "high",
            "face_visible": True,
            "reason": "Clear match of facial features.",
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    res = _run(
        face_match.check_same_person(
            (b"img1", "image/jpeg"),
            (b"img2", "image/jpeg"),
            uid="u1",
        )
    )

    assert res["verdict"] == "self"
    assert res["confidence"] == "high"
    assert res["face_visible"] is True
    assert "facial features" in res["reason"]
    assert len(calls) == 1
    assert calls[0]["images"] == [(b"img1", "image/jpeg"), (b"img2", "image/jpeg")]


def test_verdict_mapping_not_self(monkeypatch):
    async def _fake_json(*args, **kwargs):
        return {
            "verdict": "not_self",
            "confidence": "high",
            "face_visible": True,
            "reason": "Different bone structure and eyes.",
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    res = _run(
        face_match.check_same_person(
            (b"ref", "image/jpeg"),
            (b"cand", "image/jpeg"),
            uid="u1",
        )
    )

    assert res["verdict"] == "not_self"
    assert res["confidence"] == "high"
    assert res["face_visible"] is True


def test_verdict_mapping_no_face_forces_not_self(monkeypatch):
    async def _fake_json(*args, **kwargs):
        return {
            "verdict": "self",
            "confidence": "medium",
            "face_visible": False,
            "reason": "No face found in candidate.",
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    res = _run(
        face_match.check_same_person(
            (b"ref", "image/jpeg"),
            (b"cand", "image/jpeg"),
            uid="u1",
        )
    )

    assert res["verdict"] == "not_self"
    assert res["face_visible"] is False


def test_unknown_path_on_model_exception(monkeypatch):
    async def _broken(*args, **kwargs):
        raise RuntimeError("LiveKit gateway timeout")

    monkeypatch.setattr(gemini, "generate_json", _broken)

    res = _run(
        face_match.check_same_person(
            (b"ref", "image/jpeg"),
            (b"cand", "image/jpeg"),
            uid="u1",
        )
    )

    assert res["verdict"] == "unknown"
    assert res["confidence"] == "low"
    assert res["face_visible"] is False


def test_unknown_path_on_empty_or_unreadable_bytes(monkeypatch):
    res1 = _run(face_match.check_same_person(b"", (b"cand", "image/jpeg")))
    assert res1["verdict"] == "unknown"

    res2 = _run(face_match.check_same_person((b"ref", "image/jpeg"), (b"", "image/jpeg")))
    assert res2["verdict"] == "unknown"


def test_cache_hit_prevents_second_call(monkeypatch):
    call_count = 0

    monkeypatch.setattr(
        media_embed,
        "download_bytes",
        lambda p: (b"bytes_" + p.encode(), "image/jpeg"),
    )

    async def _fake_json(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        return {
            "verdict": "self",
            "confidence": "high",
            "face_visible": True,
            "reason": "Cached match.",
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    path_ref = "verification/u1/selfie.jpg"
    path_cand = "uploads/u1/photo1.jpg"

    # First call - cache miss, calls model
    res1 = _run(face_match.check_same_person(path_ref, path_cand, uid="u1"))
    assert res1["verdict"] == "self"
    assert call_count == 1

    # Second call (same paths) - cache hit, no model call
    res2 = _run(face_match.check_same_person(path_ref, path_cand, uid="u1"))
    assert res2["verdict"] == "self"
    assert call_count == 1  # Still 1!

    # Reverse order paths - cache hit, no model call
    res3 = _run(face_match.check_same_person(path_cand, path_ref, uid="u1"))
    assert res3["verdict"] == "self"
    assert call_count == 1  # Still 1!


def test_get_reference_photos_requires_biometric_consent(monkeypatch):
    monkeypatch.setattr(biometric_consent, "has_consent_fresh", lambda db, uid: False)
    db = _FakeDb(
        users_data={"u1": {schema.FIELD_FACE_VERIFICATION: {"storage_path": "selfie.jpg"}}},
    )
    assert face_match.get_reference_photos(db, "u1") == []


def test_get_reference_photos_same_account_only(monkeypatch):
    monkeypatch.setattr(biometric_consent, "has_consent_fresh", lambda db, uid: True)
    db = _FakeDb(
        users_data={
            "u1": {
                schema.FIELD_FACE_VERIFICATION: {
                    schema.FACE_VERIFICATION_STORAGE_PATH: "verification/u1/selfie.jpg",
                }
            },
            "u2": {
                schema.FIELD_FACE_VERIFICATION: {
                    schema.FACE_VERIFICATION_STORAGE_PATH: "verification/u2/other.jpg",
                }
            },
        },
        user_media={
            "u1": [
                {"storage_path": "uploads/u1/pic1.jpg", "moderation_status": "approved"},
                {"storage_path": "uploads/u1/pic2.jpg", "moderation_status": "approved"},
                {"storage_path": "uploads/u1/flagged.jpg", "moderation_status": "flagged"},
            ],
            "u2": [
                {"storage_path": "uploads/u2/other_pic.jpg", "moderation_status": "approved"},
            ],
        },
    )

    refs = face_match.get_reference_photos(db, "u1")
    # Selfie first (authoritative), then approved user_media from u1
    assert refs == [
        "verification/u1/selfie.jpg",
        "uploads/u1/pic1.jpg",
        "uploads/u1/pic2.jpg",
    ]
    # No u2 pictures, no flagged pictures
    assert "verification/u2/other.jpg" not in refs
    assert "uploads/u2/other_pic.jpg" not in refs
    assert "uploads/u1/flagged.jpg" not in refs


def test_classify_photo_matches_authoritative_selfie(monkeypatch):
    monkeypatch.setattr(biometric_consent, "has_consent_fresh", lambda db, uid: True)
    db = _FakeDb(
        users_data={
            "u1": {
                schema.FIELD_FACE_VERIFICATION: {
                    schema.FACE_VERIFICATION_STORAGE_PATH: "verification/u1/selfie.jpg",
                }
            }
        },
    )
    monkeypatch.setattr(
        media_embed,
        "download_bytes",
        lambda p: (b"bytes_" + p.encode(), "image/jpeg"),
    )

    async def _fake_json(*args, **kwargs):
        return {
            "verdict": "self",
            "confidence": "high",
            "face_visible": True,
            "reason": "Matches selfie.",
        }

    monkeypatch.setattr(gemini, "generate_json", _fake_json)

    res = _run(
        face_match.classify_photo(
            db, "u1", (b"new_pic", "image/jpeg"), cand_path="uploads/u1/new.jpg"
        )
    )
    assert res["verdict"] == "self"
    assert res["confidence"] == "high"
