import asyncio

import photo_moderation
import photo_pipeline
import pytest


def _run(coro):
    return asyncio.run(coro)


class _Doc:
    def __init__(self, store, key):
        self._s, self._k = store, key

    @property
    def id(self):
        return self._k[-1]

    def set(self, payload, merge=False):
        self._s[self._k] = {**self._s.get(self._k, {}), **payload}

    def collection(self, name):
        return _Col(self._s, self._k + (name,))


class _Col:
    n = 0

    def __init__(self, store, key):
        self._s, self._k = store, key

    def document(self, doc_id=None):
        if doc_id is None:
            _Col.n += 1
            doc_id = f"media{_Col.n}"
        return _Doc(self._s, self._k + (doc_id,))


class _Db:
    def __init__(self):
        self.store = {}

    def collection(self, name):
        return _Col(self.store, (name,))


@pytest.fixture(autouse=True)
def _stub_media(monkeypatch):
    monkeypatch.setattr(
        photo_pipeline.media_embed, "download_bytes",
        lambda p: (b"IMGBYTES", "image/jpeg"),
    )
    monkeypatch.setattr(
        photo_pipeline.media_embed, "embed_image_bytes",
        lambda b, m="image/jpeg": [0.1] * 8,
    )

    async def _attrs(b, m):
        return {"hair_color": "brown", "glasses": "no"}

    monkeypatch.setattr(photo_pipeline.photo_attrs, "extract_attributes", _attrs)

    async def _caption(b, m):
        return "a person hiking a ridgeline"

    monkeypatch.setattr(photo_pipeline, "_caption", _caption)


def _media_doc(db):
    return next(v for k, v in db.store.items() if k[:3] ==
               ("users", "u1", "user_media"))


def test_flagged_photo_stops_after_recording(monkeypatch):
    async def _mod(b, m):
        return {"allowed": False, "reason": "nudity", "categories": ["nudity"]}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)
    embed_called = []
    monkeypatch.setattr(
        photo_pipeline.media_embed, "embed_image_bytes",
        lambda b, m="image/jpeg": embed_called.append(1),
    )

    db = _Db()
    res = _run(photo_pipeline.process(db, "u1", "uploads/u1/x.jpg", "profile"))

    assert res["published"] is False
    assert res["moderation_status"] == "flagged"
    assert res["reason"] == "nudity"
    assert embed_called == []
    doc = _media_doc(db)
    assert doc["moderation_status"] == "flagged"
    assert "embedding" not in doc


def test_approved_photo_runs_every_stage(monkeypatch):
    async def _mod(b, m):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)

    wiki_calls = []

    async def _wiki(db, uid, sid, turns, force_visibility=None):
        wiki_calls.append((uid, force_visibility, turns[0].text))

    monkeypatch.setattr(photo_pipeline, "wiki_ingest", _wiki)
    monkeypatch.setattr(photo_pipeline, "persist_raw_turns", lambda *a: None)

    db = _Db()
    res = _run(photo_pipeline.process(
        db, "u1", "uploads/u1/p.jpg", "profile", wiki_uids=["u1"],
    ))

    assert res["published"] is True
    assert res["moderation_status"] == "approved"
    assert res["attributes"]["hair_color"] == "brown"
    assert res["caption"] == "a person hiking a ridgeline"
    assert res["embedding"] == [0.1] * 8
    doc = _media_doc(db)
    assert doc["dim"] == 8 and doc["source"] == "profile"
    # profile photo mirrors attrs onto profile/main
    assert db.store[("users", "u1", "profile", "main")]["photo_attrs"][
        "glasses"] == "no"
    # wiki caption ingested for u1 at default visibility
    assert wiki_calls == [("u1", None, "(shared a photo) a person hiking a ridgeline")]


def test_dm_source_forces_ai_only(monkeypatch):
    async def _mod(b, m):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)
    forced = []

    async def _wiki(db, uid, sid, turns, force_visibility=None):
        forced.append(force_visibility)

    monkeypatch.setattr(photo_pipeline, "wiki_ingest", _wiki)
    monkeypatch.setattr(photo_pipeline, "persist_raw_turns", lambda *a: None)

    _run(photo_pipeline.process(
        _Db(), "u1", "uploads/u1/d.jpg", "dm",
        wiki_uids=["u1", "u2"], wiki_visibility="ai_only",
    ))
    assert forced == ["ai_only", "ai_only"]


# --- caption_turn_text ("of user" / "other" / "group" context note) --------


def test_caption_turn_text_self():
    assert (
        photo_pipeline.caption_turn_text("a smiling person", match="self")
        == "(shared a photo of themselves) a smiling person"
    )


def test_caption_turn_text_not_self():
    assert (
        photo_pipeline.caption_turn_text("a smiling person", match="not_self")
        == "(shared a photo, not of themselves — shows a smiling person)"
    )


def test_caption_turn_text_group():
    assert (
        photo_pipeline.caption_turn_text(
            "three friends at a bar", shot_type="group", match="self"
        )
        == "(shared a group photo) three friends at a bar"
    )


def test_caption_turn_text_unknown_falls_back_to_the_plain_phrasing():
    assert (
        photo_pipeline.caption_turn_text("a person hiking")
        == "(shared a photo) a person hiking"
    )


def test_approved_photo_folds_the_match_verdict_into_the_wiki_turn(monkeypatch):
    async def _mod(b, m):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)

    async def _attrs(b, m):
        return {"shot_type": "face", "usable_for_face": True}

    monkeypatch.setattr(photo_pipeline.photo_attrs, "extract_attributes", _attrs)
    monkeypatch.setattr(
        photo_pipeline.deep_dive_images, "reference_embeddings_for",
        lambda _db, _uid: [[0.1] * 8],
    )
    monkeypatch.setattr(
        photo_pipeline.deep_dive_images, "classify_face_match",
        lambda _emb, _refs: "self",
    )

    wiki_calls = []

    async def _wiki(db, uid, sid, turns, force_visibility=None):
        wiki_calls.append(turns[0].text)

    monkeypatch.setattr(photo_pipeline, "wiki_ingest", _wiki)
    monkeypatch.setattr(photo_pipeline, "persist_raw_turns", lambda *a: None)

    _run(photo_pipeline.process(
        _Db(), "u1", "uploads/u1/p.jpg", "profile", wiki_uids=["u1"],
    ))
    assert wiki_calls == [
        "(shared a photo of themselves) a person hiking a ridgeline"
    ]


def test_moderation_fails_closed_on_error(monkeypatch):
    async def _boom(*a, **k):
        raise RuntimeError("model down")

    monkeypatch.setattr(photo_moderation.gemini, "generate_json", _boom)
    out = _run(photo_moderation.moderate(b"x", "image/jpeg"))
    assert out == {"allowed": False, "reason": "moderation_error",
                   "categories": []}
