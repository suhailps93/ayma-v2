import asyncio

import dm_ingest
import gemini
import media_embed
from post_turn import persist_raw_turns
from wiki_ingest import ingest as wiki_ingest


def _run(coro):
    return asyncio.run(coro)


def test_text_message_ingests_normal_visibility_for_both(monkeypatch):
    persisted, ingested = [], []
    monkeypatch.setattr(
        dm_ingest, "persist_raw_turns",
        lambda db, uid, sid, turns: persisted.append((uid, sid, turns[0].text)),
    )

    async def _wiki(db, uid, sid, turns, force_visibility=None):
        ingested.append((uid, force_visibility))
        return 1

    monkeypatch.setattr(dm_ingest, "wiki_ingest", _wiki)

    _run(dm_ingest.ingest_dm_message(
        None, "a__b", "m1", "a", "b", "text", "I just adopted a dog"
    ))

    assert {c[0] for c in persisted} == {"a", "b"}
    assert ingested == [("a", None), ("b", None)]


def test_photo_message_captions_embeds_and_forces_ai_only(monkeypatch):
    monkeypatch.setattr(
        dm_ingest, "_to_thread",
        _async(lambda fn, *a: (b"IMG", "image/jpeg")
               if fn is media_embed.download_bytes else "embedded"),
    )

    async def _caption(image, mime):
        return "a golden retriever on a beach"

    monkeypatch.setattr(dm_ingest, "_photo_caption", _caption)

    forced = []

    async def _wiki(db, uid, sid, turns, force_visibility=None):
        forced.append(force_visibility)
        assert "golden retriever" in turns[0].text
        return 1

    monkeypatch.setattr(dm_ingest, "wiki_ingest", _wiki)
    monkeypatch.setattr(dm_ingest, "persist_raw_turns", lambda *a: None)

    _run(dm_ingest.ingest_dm_message(
        None, "a__b", "m2", "a", "b", "photo", "uploads/a/dog.jpg"
    ))
    assert forced == ["ai_only", "ai_only"]


def test_shared_profile_message_is_not_ingested(monkeypatch):
    called = []
    monkeypatch.setattr(
        dm_ingest, "persist_raw_turns", lambda *a: called.append(1)
    )
    _run(dm_ingest.ingest_dm_message(
        None, "a__b", "m3", "a", "b", "shared_profile", "carol"
    ))
    assert called == []


def _async(fn):
    async def _inner(*args, **kwargs):
        return fn(*args, **kwargs)

    return _inner
