"""User-attributable Gemini calls that used to go unmetered now record spend
under the user's uid and a dedicated feature — record-only (no credit gate)."""
import asyncio

import dm_ingest
import gemini
import photo_attrs
import photo_moderation
import photo_pipeline
import token_ledger


def _capture(monkeypatch, result):
    seen = {}

    async def _fake(contents, system_prompt=None, response_schema=None,
                    image=None, **kw):
        seen.update(kw)
        return result

    monkeypatch.setattr(gemini, "generate_json", _fake)
    return seen


def test_photo_attrs_records_to_uid_without_a_gate(monkeypatch):
    seen = _capture(monkeypatch, {})
    asyncio.run(photo_attrs.extract_attributes(b"I", "image/png", uid="u1"))
    assert seen["uid"] == "u1"
    assert seen["feature"] == token_ledger.FEATURE_PHOTO_ATTRS
    assert seen["enforce_cap"] is False


def test_photo_moderation_records_to_uid_without_a_gate(monkeypatch):
    seen = _capture(monkeypatch, {"allowed": True, "reason": "", "categories": []})
    asyncio.run(photo_moderation.moderate(b"I", "image/png", uid="u1"))
    assert seen["uid"] == "u1"
    assert seen["feature"] == token_ledger.FEATURE_PHOTO_MODERATION
    assert seen["enforce_cap"] is False


def test_photo_caption_records_to_uid_without_a_gate(monkeypatch):
    seen = _capture(monkeypatch, {"text": "hi"})
    out = asyncio.run(photo_pipeline._caption(b"I", "image/png", uid="u1"))
    assert out == "hi"
    assert seen["uid"] == "u1"
    assert seen["feature"] == token_ledger.FEATURE_PHOTO_CAPTION
    assert seen["enforce_cap"] is False


def test_dm_caption_and_transcript_record_to_sender(monkeypatch):
    seen = _capture(monkeypatch, {"text": "x"})
    asyncio.run(dm_ingest._photo_caption(b"I", "image/png", "u2"))
    assert seen["uid"] == "u2"
    assert seen["feature"] == token_ledger.FEATURE_DM_INGEST
    seen.clear()
    asyncio.run(dm_ingest._voice_transcript(b"A", "audio/ogg", "u2"))
    assert seen["uid"] == "u2" and seen["enforce_cap"] is False


def test_attribution_is_optional(monkeypatch):
    _capture(monkeypatch, {})
    assert asyncio.run(photo_attrs.extract_attributes(b"I", "image/png"))
