"""Swipe-reply photo references (founder 2026-11-09: reference, not content).

A swipe-reply to a photo message used to give Ayma nothing about the
photo: the reply carried only a quote of the message text, and a photo
with no caption has no text. Now the turn carries only the REFERENCE —
the replied-to photo storage path (`reply_image_path`) — and the server
validates it against the caller trees (`uploads/{uid}/...` for a photo
the user sent, `ayma_generated/{uid}/...` for an image generated for
this user) and pulls the exact photo itself, attached to the generation
call so Ayma answers the reply looking at that photo. No photo bytes or
description ever ride the request.
"""

import gemini
import media_embed
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import main
from main import app
from tests.fake_firestore import FakeDb

client = TestClient(app)

UID = "test-uid"
OTHER = "other-uid"

_PHOTO_BYTES = b"ZZZREPLYPHOTOBYTES"
_WIRE = '[Replying to You: "[photo ref:https://example.invalid/x]"]\nThat was us!'


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    return {"Authorization": "Bearer <redacted>"}


def _seeded(monkeypatch, seed):
    db = FakeDb(seed)
    monkeypatch.setattr(main, "get_db", lambda: db)
    return db


def _fake_download(monkeypatch, *, fail=False):
    calls = []

    def _dl(path):
        calls.append(path)
        if fail:
            raise RuntimeError("object gone")
        return (_PHOTO_BYTES, "image/jpeg")

    monkeypatch.setattr(media_embed, "download_bytes", _dl)
    return calls


def _capture_chat(monkeypatch, payload, *, fail_download=False):
    seen = {}
    calls = _fake_download(monkeypatch, fail=fail_download)

    async def _capture(message, system_prompt=None, tool_declarations=None,
                       tool_fns=None, **kw):
        seen["prompt"] = system_prompt or ""
        seen["image"] = kw.get("image")
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    _seeded(monkeypatch, {})
    resp = client.post("/chat", json=payload, headers=_auth(monkeypatch))
    assert resp.status_code == 200, resp.text
    seen["download_calls"] = calls
    return seen


def test_reply_to_user_photo_pulls_the_exact_photo(monkeypatch):
    path = f"uploads/{UID}/chat/lake.jpg"
    seen = _capture_chat(monkeypatch, {
        "message": _WIRE,
        "reply_image_path": path,
    })
    # The server pulled the exact photo the reference names...
    assert seen["download_calls"] == [path]
    # ...and attached it to the generation call, so she answers looking
    # at it, with the prompt saying so.
    assert seen["image"] == (_PHOTO_BYTES, "image/jpeg")
    assert "REPLIED-TO PHOTO" in seen["prompt"]


def test_reply_to_generated_image_pulls_it(monkeypatch):
    path = f"ayma_generated/{UID}/caricature.png"
    seen = _capture_chat(monkeypatch, {
        "message": _WIRE,
        "reply_image_path": path,
    })
    assert seen["download_calls"] == [path]
    assert seen["image"] == (_PHOTO_BYTES, "image/jpeg")
    assert "REPLIED-TO PHOTO" in seen["prompt"]


def test_reply_reference_to_another_users_upload_is_ignored(monkeypatch):
    seen = _capture_chat(monkeypatch, {
        "message": _WIRE,
        "reply_image_path": f"uploads/{OTHER}/chat/lake.jpg",
    })
    # Never even fetched — and the turn itself still succeeds.
    assert seen["download_calls"] == []
    assert seen["image"] is None
    assert "REPLIED-TO PHOTO" not in seen["prompt"]


def test_reply_reference_to_another_users_generated_image_is_ignored(
    monkeypatch,
):
    seen = _capture_chat(monkeypatch, {
        "message": _WIRE,
        "reply_image_path": f"ayma_generated/{OTHER}/caricature.png",
    })
    assert seen["download_calls"] == []
    assert seen["image"] is None
    assert "REPLIED-TO PHOTO" not in seen["prompt"]


def test_reply_reference_that_no_longer_resolves_never_fails_the_turn(
    monkeypatch,
):
    seen = _capture_chat(
        monkeypatch,
        {
            "message": _WIRE,
            "reply_image_path": f"uploads/{UID}/chat/deleted.jpg",
        },
        fail_download=True,
    )
    assert seen["image"] is None
    assert "REPLIED-TO PHOTO" not in seen["prompt"]


def test_turn_without_a_reply_reference_gets_no_photo(monkeypatch):
    seen = _capture_chat(monkeypatch, {"message": "hi"})
    assert seen["download_calls"] == []
    assert seen["image"] is None
    assert "REPLIED-TO PHOTO" not in seen["prompt"]


def test_chat_stream_reply_reference_pulls_the_photo(monkeypatch):
    seen = {}
    calls = _fake_download(monkeypatch)
    path = f"uploads/{UID}/chat/lake.jpg"

    async def _events(message, system_prompt=None, tool_declarations=None,
                      tool_fns=None, **kw):
        seen["prompt"] = system_prompt or ""
        seen["image"] = kw.get("image")
        yield {"type": "reply", "text": "ok", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    _seeded(monkeypatch, {})
    resp = client.post(
        "/chat/stream",
        json={"message": _WIRE, "reply_image_path": path},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200, resp.text
    assert calls == [path]
    assert seen["image"] == (_PHOTO_BYTES, "image/jpeg")
    assert "REPLIED-TO PHOTO" in seen["prompt"]
