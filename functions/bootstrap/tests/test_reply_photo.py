"""Photo reply references (founder 2026-11-09: reference, not content).

A swipe-reply to a photo message used to carry only the quote's text —
for a photo-only message, nothing at all — so Ayma answered about a
photo she could not see, from whatever the conversation was about
before. The client now puts a ``[photo ref:<url>]`` marker inside the
existing ``[Replying to ...]`` wire prefix; the turn binds the
``open_replied_photo`` tool to that exact reference server-side, the
prompt names the replied photo and requires opening it, and the tool
pulls the exact photo through the app's own storage-namespace rule
(``uploads/{uid}/…`` / ``ayma_generated/{uid}/…`` — the caller's own
conversation photos only).
"""

from urllib.parse import quote

import gemini
import media_embed
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import main
from config import CONFIG
from main import app
from skills import open_replied, session_tool_declarations
from tests.fake_firestore import FakeDb
from tool_media import ImageToolResult

client = TestClient(app)

UID = "test-uid"
OTHER = "other-uid"

_PHOTO_BYTES = b"ZZZPHOTOBYTES"
_USER_PATH = f"uploads/{UID}/chat/pic1.jpg"
_GENERATED_PATH = f"ayma_generated/{UID}/gen1.png"


def _url(path: str) -> str:
    return (
        "https://firebasestorage.googleapis.com/v0/b/"
        f"{CONFIG.storage_bucket}/o/{quote(path, safe='')}"
        "?alt=media&token=test-token"
    )


def _wire(url: str, snippet: str = "", subject: str = "You") -> str:
    marker = f"[photo ref:{url}]"
    quote_text = f"{snippet} {marker}" if snippet else marker
    return f'[Replying to {subject}: "{quote_text}"]\nwhat is this?'


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": UID}
    )
    return {"Authorization": "Bearer <redacted>"}


def _seeded(monkeypatch, seed):
    db = FakeDb(seed)
    monkeypatch.setattr(main, "get_db", lambda: db)
    return db


def _fake_download(monkeypatch, data=_PHOTO_BYTES, mime="image/jpeg"):
    seen = {}

    def _download(path):
        seen["path"] = path
        return data, mime

    monkeypatch.setattr(media_embed, "download_bytes", _download)
    return seen


# --- reference parsing ------------------------------------------------------


def test_extract_photo_ref_from_a_photo_only_reply():
    subject, url = open_replied.extract_reply_photo_ref(_wire(_url(_USER_PATH)))
    assert subject == "You"
    assert url == _url(_USER_PATH)


def test_extract_photo_ref_after_a_caption():
    msg = _wire(_url(_GENERATED_PATH), snippet="my dog", subject="Ayma")
    subject, url = open_replied.extract_reply_photo_ref(msg)
    assert subject == "Ayma"
    assert url == _url(_GENERATED_PATH)


def test_extract_none_for_a_text_reply_and_a_plain_message():
    assert open_replied.extract_reply_photo_ref(
        '[Replying to Ayma: "hello there"]\nhi again'
    ) is None
    assert open_replied.extract_reply_photo_ref("just a message") is None
    assert open_replied.extract_reply_photo_ref("") is None


# --- the ownership rule -------------------------------------------------------


def test_storage_path_accepts_own_uploads_and_generated():
    assert open_replied.storage_path_for_ref(UID, _url(_USER_PATH)) == _USER_PATH
    assert (
        open_replied.storage_path_for_ref(UID, _url(_GENERATED_PATH))
        == _GENERATED_PATH
    )
    # Bare paths (the other form a turn's image reference can take).
    assert open_replied.storage_path_for_ref(UID, _USER_PATH) == _USER_PATH


def test_storage_path_refuses_other_users_and_foreign_refs():
    # Another user's namespaces — even a well-formed app URL.
    assert open_replied.storage_path_for_ref(
        UID, _url(f"uploads/{OTHER}/chat/pic9.jpg")
    ) is None
    assert open_replied.storage_path_for_ref(
        UID, _url(f"ayma_generated/{OTHER}/gen9.png")
    ) is None
    # A different bucket, a foreign host, a non-photo namespace, junk.
    foreign = _url(_USER_PATH).replace(CONFIG.storage_bucket, "someone-else")
    assert open_replied.storage_path_for_ref(UID, foreign) is None
    assert open_replied.storage_path_for_ref(
        UID, "https://evil.example.com/v0/b/x/o/uploads%2Ftest-uid%2Fa.jpg"
    ) is None
    assert open_replied.storage_path_for_ref(
        UID, _url(f"profile_photos/{UID}/main.jpg")
    ) is None
    assert open_replied.storage_path_for_ref(UID, "not a url") is None
    assert open_replied.storage_path_for_ref(UID, "") is None


# --- the tool itself ----------------------------------------------------------


def test_tool_returns_the_exact_photo(monkeypatch):
    seen = _fake_download(monkeypatch)
    result = open_replied.fetch_replied_photo(UID, _url(_USER_PATH))
    assert isinstance(result, ImageToolResult)
    # The exact object the reference names — its bytes, its mime.
    assert seen["path"] == _USER_PATH
    assert result.image == (_PHOTO_BYTES, "image/jpeg")
    # Loops that cannot carry media stringify the result: text only,
    # never a bytes repr.
    assert str(result) == result.text


def test_tool_returns_a_generated_photo(monkeypatch):
    seen = _fake_download(monkeypatch, mime="image/png")
    result = open_replied.fetch_replied_photo(UID, _url(_GENERATED_PATH))
    assert isinstance(result, ImageToolResult)
    assert seen["path"] == _GENERATED_PATH
    assert result.image == (_PHOTO_BYTES, "image/png")


def test_tool_refuses_a_cross_user_reference(monkeypatch):
    def _boom(path):  # a refused reference must never reach storage
        raise AssertionError("download attempted for a refused reference")

    monkeypatch.setattr(media_embed, "download_bytes", _boom)
    result = open_replied.fetch_replied_photo(
        UID, _url(f"uploads/{OTHER}/chat/pic9.jpg")
    )
    assert isinstance(result, str)
    assert result.startswith("error:")
    assert "couldn't open" in result


def test_tool_missing_photo_fails_honestly(monkeypatch):
    def _missing(path):
        raise FileNotFoundError(path)

    monkeypatch.setattr(media_embed, "download_bytes", _missing)
    result = open_replied.fetch_replied_photo(UID, _url(_USER_PATH))
    assert isinstance(result, str)
    assert result.startswith("error:")
    assert "couldn't open" in result


def test_declaration_only_present_for_a_photo_reply():
    names = {d["name"] for d in session_tool_declarations()}
    assert "open_replied_photo" not in names
    names = {d["name"] for d in session_tool_declarations(reply_photo=True)}
    assert "open_replied_photo" in names


# --- the /chat turn -------------------------------------------------------------


def _capture_chat(monkeypatch, seed, payload):
    seen = {}

    async def _capture(message, system_prompt=None, tool_declarations=None,
                       tool_fns=None, **_kw):
        seen["prompt"] = system_prompt or ""
        seen["names"] = {d["name"] for d in (tool_declarations or [])}
        seen["fns"] = tool_fns or {}
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    _seeded(monkeypatch, seed)
    resp = client.post("/chat", json=payload, headers=_auth(monkeypatch))
    assert resp.status_code == 200, resp.text
    return seen


def test_chat_turn_with_a_photo_reply_binds_the_pull_tool(monkeypatch):
    _fake_download(monkeypatch)
    seen = _capture_chat(monkeypatch, {}, {"message": _wire(_url(_USER_PATH))})
    # The prompt names the replied photo and requires opening it...
    assert "REPLIED PHOTO" in seen["prompt"]
    assert "open_replied_photo" in seen["prompt"]
    # ...and the tool is declared and bound to this exact reference:
    # calling it (as the model does before answering) pulls the photo in.
    assert "open_replied_photo" in seen["names"]
    pulled = seen["fns"]["open_replied_photo"]()
    assert isinstance(pulled, ImageToolResult)
    assert pulled.image == (_PHOTO_BYTES, "image/jpeg")


def test_chat_turn_with_a_captioned_photo_reply_binds_the_pull_tool(monkeypatch):
    _fake_download(monkeypatch)
    seen = _capture_chat(
        monkeypatch, {},
        {"message": _wire(_url(_GENERATED_PATH), snippet="my dog",
                          subject="Ayma")},
    )
    assert "REPLIED PHOTO" in seen["prompt"]
    assert "open_replied_photo" in seen["names"]
    pulled = seen["fns"]["open_replied_photo"]()
    assert isinstance(pulled, ImageToolResult)


def test_chat_turn_with_a_cross_user_ref_binds_but_the_tool_refuses(monkeypatch):
    def _boom(path):
        raise AssertionError("download attempted for a refused reference")

    monkeypatch.setattr(media_embed, "download_bytes", _boom)
    seen = _capture_chat(
        monkeypatch, {},
        {"message": _wire(_url(f"uploads/{OTHER}/chat/pic9.jpg"))},
    )
    assert "open_replied_photo" in seen["names"]
    pulled = seen["fns"]["open_replied_photo"]()
    assert isinstance(pulled, str)
    assert pulled.startswith("error:")


def test_chat_turn_with_a_plain_text_reply_gets_no_photo_tool(monkeypatch):
    seen = _capture_chat(
        monkeypatch, {},
        {"message": '[Replying to Ayma: "hello there"]\nhi again'},
    )
    assert "open_replied_photo" not in seen["names"]
    assert "open_replied_photo" not in seen["fns"]
    assert "REPLIED PHOTO" not in seen["prompt"]


def test_chat_turn_without_a_reply_gets_no_photo_tool(monkeypatch):
    seen = _capture_chat(monkeypatch, {}, {"message": "hi"})
    assert "open_replied_photo" not in seen["names"]
    assert "open_replied_photo" not in seen["fns"]
    assert "REPLIED PHOTO" not in seen["prompt"]


def test_chat_stream_turn_with_a_photo_reply_binds_the_pull_tool(monkeypatch):
    _fake_download(monkeypatch)
    seen = {}

    async def _events(message, system_prompt=None, tool_declarations=None,
                      tool_fns=None, **_kw):
        seen["prompt"] = system_prompt or ""
        seen["names"] = {d["name"] for d in (tool_declarations or [])}
        seen["fns"] = tool_fns or {}
        yield {"type": "reply", "text": "ok", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    _seeded(monkeypatch, {})
    resp = client.post(
        "/chat/stream",
        json={"message": _wire(_url(_USER_PATH))},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200, resp.text
    assert "REPLIED PHOTO" in seen["prompt"]
    assert "open_replied_photo" in seen["names"]
    pulled = seen["fns"]["open_replied_photo"]()
    assert isinstance(pulled, ImageToolResult)
    assert pulled.image == (_PHOTO_BYTES, "image/jpeg")


# --- the model loop: the opened photo is attached for the follow-up call -----

import asyncio
import dataclasses
import types as _pytypes

import inference_llm
import token_ledger


def _resp(text="", calls=None):
    return inference_llm.InferenceResponse(
        text=text,
        function_calls=list(calls or []),
        assistant_message={"role": "assistant", "content": text},
        usage_metadata=_pytypes.SimpleNamespace(
            prompt_token_count=10, candidates_token_count=5,
            total_token_count=15, cached_content_token_count=0,
        ),
    )


def _install_complete(monkeypatch, replies):
    sent = []
    queue = list(replies)

    async def _fake_complete(**kw):
        sent.append(kw)
        return queue.pop(0)

    monkeypatch.setattr(inference_llm, "complete", _fake_complete)
    monkeypatch.setattr(token_ledger, "record", lambda *a, **k: None)
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    return sent


def test_loop_attaches_the_opened_photo_to_the_followup_call(monkeypatch):
    _fake_download(monkeypatch)
    call = inference_llm.FunctionCall(
        id="c1", name="open_replied_photo", args={}
    )
    sent = _install_complete(monkeypatch, [
        _resp("", [call]),
        _resp("That is a photo of a dog on a beach."),
    ])
    monkeypatch.setattr(
        gemini, "CONFIG", dataclasses.replace(CONFIG, gemini_web_search=False)
    )
    fns = main.make_session_tool_fns(
        FakeDb({}), UID,
        reply_photo_ctx={"subject": "You", "url": _url(_USER_PATH)},
    )
    out = asyncio.run(
        gemini.generate_reply(
            _wire(_url(_USER_PATH)),
            system_prompt="persona",
            tool_declarations=session_tool_declarations(reply_photo=True),
            tool_fns=fns,
        )
    )
    assert out.text == "That is a photo of a dog on a beach."
    # Two gateway calls: the tool round, then the follow-up that answers.
    assert len(sent) == 2
    followup = sent[1]["messages"]
    # The tool result went back as text...
    tool_msgs = [m for m in followup if m.get("role") == "tool"]
    assert len(tool_msgs) == 1
    assert "opened the photo" in tool_msgs[0]["content"]
    # ...and the photo itself rides the follow-up as a real image part,
    # the same data-URL shape as a photo attached to a user message.
    image_parts = [
        part
        for m in followup if m.get("role") == "user"
        for part in (m["content"] if isinstance(m.get("content"), list) else [])
        if isinstance(part, dict) and part.get("type") == "image_url"
    ]
    assert len(image_parts) == 1
    import base64

    expected = "data:image/jpeg;base64," + base64.b64encode(
        _PHOTO_BYTES
    ).decode("ascii")
    assert image_parts[0]["image_url"]["url"] == expected
