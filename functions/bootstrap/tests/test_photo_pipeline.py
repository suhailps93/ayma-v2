import asyncio

import photo_moderation
import photo_pipeline
import pytest

# Captured before the autouse fixture below ever runs, so tests exercising the
# real composer (mocking gemini.generate_json underneath it) aren't calling
# the fixture's blanket ``_caption`` stub instead.
_REAL_CAPTION = photo_pipeline._caption


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
    # Face identity now comes from the pairwise LiveKit check
    # (face_match.classify_photo), not a stored embedding: by default there
    # is no reference to match against, so the verdict is "unknown" and the
    # pipeline proceeds without a name.
    async def _no_face_match(*_a, **_k):
        return {
            "verdict": "unknown",
            "confidence": "low",
            "face_visible": True,
            "reason": "No reference photos for this account",
        }

    monkeypatch.setattr(
        photo_pipeline.face_match, "classify_photo", _no_face_match
    )

    async def _attrs(b, m, **_kw):
        return {"hair_color": "brown", "glasses": "no"}

    monkeypatch.setattr(photo_pipeline.photo_attrs, "extract_attributes", _attrs)

    async def _caption(b, m, **kw):
        return "a person hiking a ridgeline"

    monkeypatch.setattr(photo_pipeline, "_caption", _caption)


def _media_doc(db):
    return next(v for k, v in db.store.items() if k[:3] ==
               ("users", "u1", "user_media"))


def test_flagged_photo_stops_after_recording(monkeypatch):
    async def _mod(b, m, **_kw):
        return {"allowed": False, "reason": "nudity", "categories": ["nudity"]}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)
    face_calls = []

    async def _classify(*_a, **_k):
        face_calls.append(1)
        return {"verdict": "unknown", "confidence": "low",
                "face_visible": True, "reason": "not checked"}

    monkeypatch.setattr(photo_pipeline.face_match, "classify_photo", _classify)

    db = _Db()
    res = _run(photo_pipeline.process(db, "u1", "uploads/u1/x.jpg", "profile"))

    assert res["published"] is False
    assert res["moderation_status"] == "flagged"
    assert res["reason"] == "nudity"
    assert face_calls == []
    doc = _media_doc(db)
    assert doc["moderation_status"] == "flagged"
    assert "embedding" not in doc


def test_approved_photo_runs_every_stage(monkeypatch):
    async def _mod(b, m, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)
    monkeypatch.setattr(
        photo_pipeline.biometric_consent, "has_consent_fresh", lambda _db, _uid: True
    )

    async def _classify(*_a, **_k):
        return {"verdict": "self", "confidence": "high",
                "face_visible": True, "reason": "Matches reference."}

    monkeypatch.setattr(photo_pipeline.face_match, "classify_photo", _classify)
    monkeypatch.setattr(
        photo_pipeline.deep_dive, "profile_full_name",
        lambda db, uid: "Suhail Rahman",
    )

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
    # No stored embedding any more — identity is the pairwise face-match
    # verdict, carried on the result and the media doc instead.
    assert res["embedding"] is None
    assert res["face_verdict"] == "self"
    assert res["is_user"] == "yes"
    assert res["embedding_missing"] is False
    doc = _media_doc(db)
    assert doc["face_verdict"] == "self"
    assert doc["is_user"] == "yes"
    assert doc["source"] == "profile"
    assert "embedding" not in doc and "dim" not in doc
    # profile photo mirrors attrs onto profile/main
    assert db.store[("users", "u1", "profile", "main")]["photo_attrs"][
        "glasses"] == "no"
    # wiki caption ingested for u1 at default visibility
    assert wiki_calls == [("u1", None, "(shared a photo of themselves) a person hiking a ridgeline")]


def test_no_face_check_without_biometric_consent(monkeypatch):
    async def _mod(b, m, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)
    monkeypatch.setattr(
        photo_pipeline.biometric_consent, "has_consent_fresh", lambda _db, _uid: False
    )

    async def _classify(*_a, **_k):
        raise AssertionError("no face match without consent")

    monkeypatch.setattr(photo_pipeline.face_match, "classify_photo", _classify)
    db = _Db()
    res = _run(photo_pipeline.process(db, "u1", "uploads/u1/p.jpg", "chat"))

    assert res["published"] is True
    assert res["face_verdict"] == "unknown"
    assert res["embedding"] is None
    assert res["embedding_missing"] is False
    doc = _media_doc(db)
    assert doc["face_verdict"] == "unknown"
    assert doc["is_user"] == ""
    assert "embedding" not in doc and "dim" not in doc


def test_dm_source_forces_ai_only(monkeypatch):
    async def _mod(b, m, **_kw):
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


def test_face_check_failure_is_non_fatal_and_records_unknown(monkeypatch):
    """When the pairwise face check raises, the pipeline continues,
    publishes as approved, and records an "unknown" verdict so the photo is
    never mislabelled as the user (or as someone else) on a failed check."""
    async def _mod(b, m, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)
    monkeypatch.setattr(
        photo_pipeline.biometric_consent, "has_consent_fresh", lambda _db, _uid: True
    )

    async def _broken_check(*_a, **_k):
        raise RuntimeError("vision model call failed")

    monkeypatch.setattr(
        photo_pipeline.face_match, "classify_photo", _broken_check
    )

    db = _Db()
    res = _run(photo_pipeline.process(db, "u1", "uploads/u1/p.jpg", "profile"))

    assert res["published"] is True
    assert res["moderation_status"] == "approved"
    assert res["embedding"] is None
    assert res["face_verdict"] == "unknown"
    assert res["is_user"] == ""
    assert res["embedding_missing"] is False
    doc = _media_doc(db)
    assert doc["moderation_status"] == "approved"
    assert doc["face_verdict"] == "unknown"
    assert "embedding" not in doc and "dim" not in doc
    assert res["attributes"]["hair_color"] == "brown"


def test_attribute_extraction_failure_is_non_fatal(monkeypatch):
    """When attribute extraction raises, the photo still publishes with blank
    attributes instead of failing the pipeline."""
    async def _mod(b, m, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)

    async def _failing_attrs(b, m, **_kw):
        raise RuntimeError("model service crashed")

    monkeypatch.setattr(photo_pipeline.photo_attrs, "extract_attributes", _failing_attrs)

    db = _Db()
    res = _run(photo_pipeline.process(db, "u1", "uploads/u1/p.jpg", "profile"))

    assert res["published"] is True
    assert res["moderation_status"] == "approved"
    assert res["attributes"] == photo_pipeline.photo_attrs._blank()


def test_moderation_flag_returns_reason(monkeypatch):
    """A photo rejected by moderation records the real human reason and stops."""
    async def _mod(b, m, **_kw):
        return {
            "allowed": False,
            "reason": "That photo cannot be used - screenshots of text are not allowed.",
            "categories": ["spam"],
        }

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)

    db = _Db()
    res = _run(photo_pipeline.process(db, "u1", "uploads/u1/bad.jpg", "profile"))

    assert res["published"] is False
    assert res["moderation_status"] == "flagged"
    assert res["reason"] == "That photo cannot be used - screenshots of text are not allowed."
    doc = _media_doc(db)
    assert doc["moderation_status"] == "flagged"
    assert doc["moderation_reason"] == "That photo cannot be used - screenshots of text are not allowed."
    assert "embedding" not in doc
    assert doc.get("embedding_missing") is not True


# --- _caption composer (name/context-aware gallery note) -------------------


def test_caption_composer_uses_name_and_folds_in_accompanying_text(monkeypatch):
    captured = {}

    async def _fake_generate_json(contents, **kw):
        captured["contents"] = contents
        captured["system_prompt"] = kw.get("system_prompt")
        return {"text": "Suhail on a boat, having a great day out at sea."}

    monkeypatch.setattr(photo_pipeline.gemini, "generate_json", _fake_generate_json)

    result = _run(_REAL_CAPTION(
        b"IMG", "image/jpeg",
        name="Suhail Rahman", match="self", source="chat",
        accompanying_text="just got back from the coast, feeling great",
    ))

    assert result == "Suhail on a boat, having a great day out at sea."
    assert "Suhail Rahman" in captured["contents"]
    assert "feeling great" in captured["contents"]
    assert "chat" in captured["contents"]
    # The static composer instructions, not the per-call facts.
    assert "private photo log" in captured["system_prompt"]


def test_caption_composer_falls_back_to_a_plain_description_when_unconfirmed(
    monkeypatch,
):
    captured = {}

    async def _fake_generate_json(contents, **kw):
        captured["contents"] = contents
        return {"text": "A bearded man rests his hand on a boat railing."}

    monkeypatch.setattr(photo_pipeline.gemini, "generate_json", _fake_generate_json)

    result = _run(_REAL_CAPTION(
        b"IMG", "image/jpeg",
        name="", match="", source="chat", accompanying_text="",
    ))

    assert result == "A bearded man rests his hand on a boat railing."
    assert "not confirmed" in captured["contents"].lower()
    assert "Suhail" not in captured["contents"]


def test_caption_composer_never_names_a_confirmed_non_match(monkeypatch):
    captured = {}

    async def _fake_generate_json(contents, **kw):
        captured["contents"] = contents
        return {"text": "Someone else, outdoors."}

    monkeypatch.setattr(photo_pipeline.gemini, "generate_json", _fake_generate_json)

    _run(_REAL_CAPTION(
        b"IMG", "image/jpeg",
        name="Suhail Rahman", match="not_self", source="chat",
        accompanying_text="",
    ))
    assert "NOT" in captured["contents"]
    assert "Suhail" not in captured["contents"]


# --- process(): match verdict computed once, fed into the composer --------


def test_process_computes_match_and_name_once_and_passes_them_to_the_composer(
    monkeypatch,
):
    async def _mod(b, m, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)
    monkeypatch.setattr(
        photo_pipeline.biometric_consent, "has_consent_fresh", lambda _db, _uid: True
    )

    face_calls = []

    async def _classify(*_a, **_k):
        face_calls.append(1)
        return {"verdict": "self", "confidence": "high",
                "face_visible": True, "reason": "Matches reference."}

    monkeypatch.setattr(photo_pipeline.face_match, "classify_photo", _classify)
    monkeypatch.setattr(
        photo_pipeline.deep_dive, "profile_full_name",
        lambda db, uid: "Suhail Rahman",
    )

    caption_calls = []

    async def _caption(image, mime, **kw):
        caption_calls.append(kw)
        return "a caption"

    monkeypatch.setattr(photo_pipeline, "_caption", _caption)

    async def _wiki(*a, **k):
        return None

    monkeypatch.setattr(photo_pipeline, "wiki_ingest", _wiki)
    monkeypatch.setattr(photo_pipeline, "persist_raw_turns", lambda *a: None)

    _run(photo_pipeline.process(
        _Db(), "u1", "uploads/u1/p.jpg", "chat",
        wiki_uids=["u1"], accompanying_text="feeling great",
    ))

    # The face check ran exactly once for this photo — the wiki-fold below
    # reuses the same match/shot_type rather than re-deriving them.
    assert face_calls == [1]
    assert caption_calls == [{
        "name": "Suhail Rahman", "match": "self", "source": "chat",
        "accompanying_text": "feeling great", "uid": "u1",
    }]


def test_process_skips_the_name_lookup_when_there_is_no_reference(monkeypatch):
    async def _mod(b, m, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)
    monkeypatch.setattr(
        photo_pipeline.biometric_consent, "has_consent_fresh", lambda _db, _uid: True
    )

    face_calls = []

    async def _classify(*_a, **_k):
        face_calls.append(1)
        return {"verdict": "unknown", "confidence": "low",
                "face_visible": True,
                "reason": "No reference photos for this account"}

    monkeypatch.setattr(photo_pipeline.face_match, "classify_photo", _classify)

    name_calls = []
    monkeypatch.setattr(
        photo_pipeline.deep_dive, "profile_full_name",
        lambda db, uid: name_calls.append(1) or "Suhail Rahman",
    )

    caption_calls = []

    async def _caption(image, mime, **kw):
        caption_calls.append(kw)
        return "a plain caption"

    monkeypatch.setattr(photo_pipeline, "_caption", _caption)

    async def _wiki(*a, **k):
        return None

    monkeypatch.setattr(photo_pipeline, "wiki_ingest", _wiki)
    monkeypatch.setattr(photo_pipeline, "persist_raw_turns", lambda *a: None)

    _run(photo_pipeline.process(
        _Db(), "u1", "uploads/u1/p.jpg", "chat", wiki_uids=["u1"],
    ))

    assert face_calls == [1]  # the check ran — it just found no reference
    assert name_calls == []  # never looked up — no confirmed match to justify it
    assert caption_calls == [{
        "name": "", "match": "unknown", "source": "chat",
        "accompanying_text": "", "uid": "u1",
    }]


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
    async def _mod(b, m, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)
    monkeypatch.setattr(
        photo_pipeline.biometric_consent, "has_consent_fresh", lambda _db, _uid: True
    )

    async def _attrs(b, m, **_kw):
        return {"shot_type": "face", "usable_for_face": True}

    monkeypatch.setattr(photo_pipeline.photo_attrs, "extract_attributes", _attrs)

    async def _classify(*_a, **_k):
        return {"verdict": "self", "confidence": "high",
                "face_visible": True, "reason": "Matches reference."}

    monkeypatch.setattr(photo_pipeline.face_match, "classify_photo", _classify)
    monkeypatch.setattr(
        photo_pipeline.deep_dive, "profile_full_name",
        lambda db, uid: "Suhail Rahman",
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


# --- gallery note (photo_notes.set_context) additive fold-in --------------


def _stub_moderation_allow(monkeypatch):
    async def _mod(b, m, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(photo_pipeline.photo_moderation, "moderate", _mod)


def test_approved_photo_updates_its_gallery_note(monkeypatch):
    import photo_notes
    import public_profile

    _stub_moderation_allow(monkeypatch)
    async def _wiki(*a, **k):
        return None

    monkeypatch.setattr(photo_pipeline, "wiki_ingest", _wiki)
    monkeypatch.setattr(photo_pipeline, "persist_raw_turns", lambda *a: None)
    monkeypatch.setattr(
        public_profile, "_photo_url",
        lambda path: f"https://cdn.example/{path}",
    )
    calls = []
    monkeypatch.setattr(
        photo_notes, "set_context",
        lambda db, uid, url, **kw: calls.append((uid, url, kw)),
    )

    _run(photo_pipeline.process(_Db(), "u1", "uploads/u1/p.jpg", "chat"))

    assert calls == [(
        "u1", "https://cdn.example/uploads/u1/p.jpg",
        {"context": "a person hiking a ridgeline", "is_user": ""},
    )]


def test_gallery_note_updated_for_profile_and_dm_sources_too(monkeypatch):
    import photo_notes
    import public_profile

    _stub_moderation_allow(monkeypatch)
    async def _wiki(*a, **k):
        return None

    monkeypatch.setattr(photo_pipeline, "wiki_ingest", _wiki)
    monkeypatch.setattr(photo_pipeline, "persist_raw_turns", lambda *a: None)
    monkeypatch.setattr(
        public_profile, "_photo_url",
        lambda path: f"https://cdn.example/{path}",
    )
    calls = []
    monkeypatch.setattr(
        photo_notes, "set_context",
        lambda db, uid, url, **kw: calls.append((uid, url)),
    )

    _run(photo_pipeline.process(
        _Db(), "u1", "uploads/u1/profile.jpg", "profile",
        wiki_uids=["u1"],
    ))
    _run(photo_pipeline.process(
        _Db(), "u1", "uploads/u1/dm.jpg", "dm",
        wiki_uids=["u1", "u2"], wiki_visibility="ai_only",
    ))

    assert calls == [
        ("u1", "https://cdn.example/uploads/u1/profile.jpg"),
        ("u1", "https://cdn.example/uploads/u1/dm.jpg"),
    ]


def test_no_gallery_note_written_when_there_is_no_caption(monkeypatch):
    import photo_notes

    _stub_moderation_allow(monkeypatch)

    async def _no_caption(b, m, **kw):
        return ""

    monkeypatch.setattr(photo_pipeline, "_caption", _no_caption)
    calls = []
    monkeypatch.setattr(
        photo_notes, "set_context",
        lambda *a, **k: calls.append((a, k)),
    )

    _run(photo_pipeline.process(_Db(), "u1", "uploads/u1/p.jpg", "chat"))
    assert calls == []


def test_gallery_note_failure_is_swallowed_and_never_fails_the_upload(
    monkeypatch,
):
    import photo_notes
    import public_profile

    _stub_moderation_allow(monkeypatch)
    async def _wiki(*a, **k):
        return None

    monkeypatch.setattr(photo_pipeline, "wiki_ingest", _wiki)
    monkeypatch.setattr(photo_pipeline, "persist_raw_turns", lambda *a: None)
    monkeypatch.setattr(
        public_profile, "_photo_url", lambda path: "https://cdn.example/x.jpg",
    )

    def _boom(*a, **k):
        raise RuntimeError("firestore write failed")

    monkeypatch.setattr(photo_notes, "set_context", _boom)

    res = _run(photo_pipeline.process(
        _Db(), "u1", "uploads/u1/p.jpg", "chat",
    ))
    assert res["published"] is True  # the upload itself still succeeds


def test_moderation_fails_closed_on_error(monkeypatch):
    async def _boom(*a, **k):
        raise RuntimeError("model down")

    monkeypatch.setattr(photo_moderation.gemini, "generate_json", _boom)
    out = _run(photo_moderation.moderate(b"x", "image/jpeg"))
    assert out == {"allowed": False, "reason": "moderation_error",
                   "categories": []}
