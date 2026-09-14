import gemini
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

from main import app

client = TestClient(app)


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    return {"Authorization": "Bearer valid"}


def _stub_gemini(monkeypatch, reply="a real-ish reply"):
    async def _fake(_message, **_kw):
        return gemini.Reply(text=reply)

    monkeypatch.setattr(gemini, "generate_reply", _fake)


def test_chat_requires_a_token():
    resp = client.post("/chat", json={"message": "hi"})
    assert resp.status_code in (401, 403)


def test_chat_returns_gemini_reply(monkeypatch):
    _stub_gemini(monkeypatch, "hello from the model")
    resp = client.post(
        "/chat", json={"message": "hi ayma"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert resp.json()["reply"] == "hello from the model"
    assert resp.json()["tools_used"] == []


def test_chat_surfaces_the_tools_ayma_used(monkeypatch):
    async def _fake(_message, **_kw):
        return gemini.Reply(
            text="looked it up", tools_used=["Searched the web"]
        )

    monkeypatch.setattr(gemini, "generate_reply", _fake)
    resp = client.post(
        "/chat", json={"message": "what's on at the Roxie?"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    assert resp.json()["tools_used"] == ["Searched the web"]


def _parse_sse(body: str) -> list[dict]:
    import json as _json
    return [
        _json.loads(line[len("data: "):])
        for line in body.splitlines()
        if line.startswith("data: ")
    ]


def test_chat_stream_emits_status_then_reply(monkeypatch):
    async def _events(_message, *_a, **_kw):
        yield {"type": "status", "label": "Thinking…"}
        yield {"type": "status", "label": "Searching the web…"}
        yield {"type": "reply", "text": "found it", "tools_used": ["Searched the web"]}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    appended = []
    monkeypatch.setattr(
        __import__("main").chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append((role, text)),
    )
    resp = client.post(
        "/chat/stream", json={"message": "what's on at the Roxie?"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    events = _parse_sse(resp.text)
    assert [e["type"] for e in events] == ["status", "status", "reply"]
    assert events[1]["label"] == "Searching the web…"
    assert events[-1]["text"] == "found it"
    assert events[-1]["tools_used"] == ["Searched the web"]
    # the reply was still persisted
    assert ("ayma", "found it") in appended


def test_chat_stream_capped_turn_yields_a_single_reply_event(monkeypatch):
    import main
    from turn_caps import TurnCapResult

    class _Caps:
        @staticmethod
        def evaluate(_db, _uid, _mode):
            return TurnCapResult(
                False, "tap get started", False, "marketing", 11, 10
            )

    monkeypatch.setattr(main, "turn_caps", _Caps)
    resp = client.post(
        "/chat/stream", json={"message": "still here?"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    events = _parse_sse(resp.text)
    assert len(events) == 1 and events[0]["type"] == "reply"
    assert events[0]["capped"] is True


def test_chat_rejects_empty_message(monkeypatch):
    resp = client.post("/chat", json={"message": ""}, headers=_auth(monkeypatch))
    assert resp.status_code == 422


def test_chat_feeds_recent_turns_into_the_system_prompt(monkeypatch):
    seen = {}

    async def _capture(message, system_prompt=None, **_kw):
        seen["prompt"] = system_prompt
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "...and that's why I love it",
            "recent_turns": [
                {"role": "user", "text": "I was telling you about sailing"},
                {"role": "ayma", "text": "you were mid-story"},
            ],
        },
    )
    assert resp.status_code == 200
    assert "I was telling you about sailing" in seen["prompt"]
    assert "you were mid-story" in seen["prompt"]


def test_chat_injects_wiki_context_into_the_prompt(monkeypatch):
    import main

    monkeypatch.setattr(
        main,
        "read_wiki_context",
        lambda _db, _uid: "### interests — sailing\nThey sail on weekends.",
    )
    seen = {}

    async def _capture(message, system_prompt=None, **_kw):
        seen["prompt"] = system_prompt
        return gemini.Reply(text="aye")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat", headers=_auth(monkeypatch), json={"message": "hi"}
    )
    assert resp.status_code == 200
    assert "They sail on weekends." in seen["prompt"]


def test_chat_rejects_a_bad_turn_role(monkeypatch):
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "hi",
            "recent_turns": [{"role": "robot", "text": "nope"}],
        },
    )
    assert resp.status_code == 422


def test_chat_persists_the_session_window_when_a_session_id_is_given(
    monkeypatch, no_firestore
):
    _stub_gemini(monkeypatch, "sure thing")
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "remember this",
            "session_id": "sess-abc123",
            "recent_turns": [{"role": "user", "text": "earlier"}],
        },
    )
    assert resp.status_code == 200
    assert len(no_firestore.persisted) == 1
    call = no_firestore.persisted[0]
    assert call["uid"] == "test-uid"
    assert call["session_id"] == "sess-abc123"
    assert [(t.role, t.text) for t in call["turns"]] == [
        ("user", "earlier"),
        ("user", "remember this"),
        ("ayma", "sure thing"),
    ]
    # A plain text turn no longer triggers a wiki ingest — that runs at session
    # end (/post_turn) or when Ayma calls the `remember` tool (cost review
    # 2026-09-07).
    assert no_firestore.ingested == []


def test_chat_with_an_image_still_ingests_so_the_caption_is_kept(
    monkeypatch, no_firestore
):
    import main

    monkeypatch.setattr(
        main.media_embed, "download_bytes",
        lambda _p: (b"JPEGBYTES", "image/jpeg"),
    )
    _stub_gemini(monkeypatch, "nice pic")
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "what's this?",
            "session_id": "sess-img1",
            "image_path": "uploads/test-uid/chat_1.jpg",
        },
    )
    assert resp.status_code == 200
    assert len(no_firestore.ingested) == 1
    assert no_firestore.ingested[0]["session_id"] == "sess-img1"


def test_chat_skips_persistence_without_a_session_id(monkeypatch, no_firestore):
    _stub_gemini(monkeypatch)
    resp = client.post(
        "/chat", headers=_auth(monkeypatch), json={"message": "hi"}
    )
    assert resp.status_code == 200
    assert no_firestore.persisted == []
    assert no_firestore.ingested == []


def test_chat_returns_a_nudge_when_the_turn_cap_is_hit(monkeypatch):
    import main
    from turn_caps import TurnCapResult

    class _Caps:
        @staticmethod
        def evaluate(_db, _uid, _mode):
            return TurnCapResult(
                False, "tap get started", False, "marketing", 11, 10
            )

    monkeypatch.setattr(main, "turn_caps", _Caps)
    monkeypatch.setattr(gemini, "generate_reply", _boom_should_not_run)
    resp = client.post(
        "/chat", headers=_auth(monkeypatch), json={"message": "still here?"}
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["reply"] == "tap get started"
    assert body["capped"] is True
    assert body["fallback_form"] is False


async def _boom_should_not_run(*_a, **_k):  # pragma: no cover
    raise AssertionError("model should not be called past the cap")


def test_chat_502_when_gemini_fails(monkeypatch):
    async def _boom(*_args, **_kwargs):
        raise RuntimeError("model exploded")

    monkeypatch.setattr(gemini, "generate_reply", _boom)
    resp = client.post(
        "/chat", json={"message": "hi"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 502


def test_chat_appends_user_and_ayma_to_chat_history(monkeypatch):
    import main

    calls = []
    monkeypatch.setattr(
        main.chat_history,
        "append",
        lambda _db, uid, role, text, **kw: calls.append((role, text, kw)),
    )
    _stub_gemini(monkeypatch, "noted")
    resp = client.post(
        "/chat", headers=_auth(monkeypatch), json={"message": "hey"}
    )
    assert resp.status_code == 200
    assert [(r, t) for r, t, _ in calls] == [("user", "hey"), ("ayma", "noted")]


def test_chat_from_the_story_editor_still_lands_in_chat_history(monkeypatch):
    """The Ask Ayma sheet's exchanges (`story_page_id`/`story_passage` on the
    request) go through the exact same `_finalize_chat` as any ordinary chat
    turn — nothing branches on story context to skip the append. Combined
    with `test_chat_history.py`'s own round-trip tests (which prove
    `chat_history.recent()` surfaces whatever `append()` wrote, with no
    story-specific filtering anywhere in that module), this confirms these
    turns already reach the main Ayma tab's transcript — no extra plumbing
    needed."""
    import main

    calls = []
    monkeypatch.setattr(
        main.chat_history,
        "append",
        lambda _db, uid, role, text, **kw: calls.append((role, text, kw)),
    )
    _stub_gemini(monkeypatch, "made that private")
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "make that private",
            "story_page_id": "career",
            "story_passage": "Laid off in 2024.",
        },
    )
    assert resp.status_code == 200
    assert [(r, t) for r, t, _ in calls] == [
        ("user", "make that private"),
        ("ayma", "made that private"),
    ]


def test_chat_with_an_image_passes_it_straight_to_gemini(monkeypatch):
    import main

    monkeypatch.setattr(
        main.media_embed, "download_bytes",
        lambda _p: (b"JPEGBYTES", "image/jpeg"),
    )
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    seen = {}

    async def _capture(_message, image=None, **_kw):
        seen["image"] = image
        return gemini.Reply(text="nice pic")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={"message": "what's this?",
              "image_path": "uploads/test-uid/chat_1.jpg"},
    )
    assert resp.status_code == 200
    assert resp.json()["reply"] == "nice pic"
    # No app-side content check on a chat image — it goes straight to Gemini.
    assert seen["image"] == (b"JPEGBYTES", "image/jpeg")


def test_chat_rejects_an_image_outside_the_callers_uploads(monkeypatch):
    _stub_gemini(monkeypatch)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={"message": "x", "image_path": "uploads/someone-else/x.jpg"},
    )
    assert resp.status_code == 403


def test_chat_history_endpoint_paginates(monkeypatch):
    import main

    monkeypatch.setattr(
        main.chat_history,
        "recent",
        lambda _db, uid, before=None, limit=40: {
            "messages": [{"role": "user", "text": "hi", "image_path": "",
                          "created_at": "2026-01-01T00:00:00+00:00"}],
            "next_before": None,
        },
    )
    resp = client.get("/chat/history?limit=10", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json()["messages"][0]["text"] == "hi"

    bad = client.get("/chat/history?before=not-a-date",
                     headers=_auth(monkeypatch))
    assert bad.status_code == 422


def test_chat_returns_a_friendly_message_at_the_token_cap(monkeypatch):
    import token_ledger

    async def _cap(*_a, **_kw):
        raise token_ledger.TokenCapExceeded("1/1")

    monkeypatch.setattr(gemini, "generate_reply", _cap)
    resp = client.post(
        "/chat", json={"message": "hi"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["usage_capped"] is True
    assert "budget" in body["reply"].lower() or "used up" in body["reply"].lower()


def test_profile_edit_flag_unlocks_the_profile_section_tools(monkeypatch):
    seen = {}

    async def _capture(message, system_prompt=None, tool_declarations=None,
                       **_kw):
        seen["names"] = {d["name"] for d in (tool_declarations or [])}
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)

    # Without the flag: no profile-edit tools.
    client.post("/chat", headers=_auth(monkeypatch),
                json={"message": "hi"})
    assert "edit_profile_section" not in seen["names"]

    # With profile_edit: they're present.
    client.post("/chat", headers=_auth(monkeypatch),
                json={"message": "hi", "profile_edit": True})
    assert {"list_profile_sections", "edit_profile_section",
            "set_profile_section_visibility"} <= seen["names"]


# --- "Chat about it" / "Talking about this photo": photo_url gives Ayma the
# actual pixels, not just a text note (founder bug: zero visual access). ---

_PHOTO_URL = (
    "https://firebasestorage.googleapis.com/v0/b/ayma-test.appspot.com/o/"
    "users%2Ftest-uid%2Fphotos%2Fp1.jpg?alt=media&token=abc"
)


def test_chat_with_photo_url_fetches_and_attaches_the_photo_bytes(monkeypatch):
    import main

    monkeypatch.setattr(
        main.photo_notes, "resolve_storage_path",
        lambda _u: "users/test-uid/photos/p1.jpg",
    )
    seen_paths = []

    def _download(path):
        seen_paths.append(path)
        return (b"PHOTOBYTES", "image/jpeg")

    monkeypatch.setattr(main.media_embed, "download_bytes", _download)

    seen = {}

    async def _capture(_message, image=None, system_prompt=None, **_kw):
        seen["image"] = image
        seen["prompt"] = system_prompt
        return gemini.Reply(text="nice shot")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "what do u think about this photo",
            "photo_url": _PHOTO_URL,
            "photo_source": "profile",
        },
    )
    assert resp.status_code == 200
    assert seen_paths == ["users/test-uid/photos/p1.jpg"]
    assert seen["image"] == (b"PHOTOBYTES", "image/jpeg")
    assert "which you can see attached" in seen["prompt"]


def test_chat_stream_with_photo_url_fetches_and_attaches_the_photo_bytes(
    monkeypatch,
):
    import main

    monkeypatch.setattr(
        main.photo_notes, "resolve_storage_path",
        lambda _u: "users/test-uid/photos/p1.jpg",
    )
    monkeypatch.setattr(
        main.media_embed, "download_bytes",
        lambda _p: (b"PHOTOBYTES", "image/jpeg"),
    )

    seen = {}

    async def _events(_message, image=None, **_kw):
        seen["image"] = image
        yield {"type": "reply", "text": "nice shot", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    resp = client.post(
        "/chat/stream",
        headers=_auth(monkeypatch),
        json={
            "message": "what do u think about this photo",
            "photo_url": _PHOTO_URL,
            "photo_source": "profile",
        },
    )
    assert resp.status_code == 200
    assert seen["image"] == (b"PHOTOBYTES", "image/jpeg")


def test_chat_photo_url_falls_back_to_a_direct_fetch_for_a_web_source_photo(
    monkeypatch,
):
    """A deep-dive ``source="web"`` photo's URL is some other site entirely —
    not one of our Storage download URLs — so there's no storage path to
    resolve; the backend falls back to a plain HTTP GET, the same helper
    deep-dive already uses for open-web images."""
    import main

    monkeypatch.setattr(main.photo_notes, "resolve_storage_path", lambda _u: None)
    seen_urls = []

    def _fetch(url):
        seen_urls.append(url)
        return (b"WEBPHOTO", "image/jpeg")

    monkeypatch.setattr(main.deep_dive_images, "_fetch_image", _fetch)

    seen = {}

    async def _capture(_message, image=None, **_kw):
        seen["image"] = image
        return gemini.Reply(text="found it")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "is this me?",
            "photo_url": "https://example.com/some-photo.jpg",
            "photo_source": "web",
        },
    )
    assert resp.status_code == 200
    assert seen_urls == ["https://example.com/some-photo.jpg"]
    assert seen["image"] == (b"WEBPHOTO", "image/jpeg")


def test_chat_image_path_takes_precedence_over_photo_url(monkeypatch):
    """A brand-new attachment on this exact turn wins over the photo the chat
    is scoped to — the photo_url fetch must not even run."""
    import main

    monkeypatch.setattr(
        main.media_embed, "download_bytes",
        lambda _p: (b"FRESHBYTES", "image/jpeg"),
    )

    def _boom(_url):  # pragma: no cover
        raise AssertionError("photo_url should not be resolved this turn")

    monkeypatch.setattr(main, "_resolve_photo_context_image", _boom)

    seen = {}

    async def _capture(_message, image=None, **_kw):
        seen["image"] = image
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "what's this new one?",
            "image_path": "uploads/test-uid/new.jpg",
            "photo_url": _PHOTO_URL,
            "photo_source": "profile",
        },
    )
    assert resp.status_code == 200
    assert seen["image"] == (b"FRESHBYTES", "image/jpeg")


def test_chat_falls_back_to_text_only_context_when_the_photo_fetch_fails(
    monkeypatch,
):
    import main

    def _boom(_path):
        raise RuntimeError("storage is down")

    monkeypatch.setattr(main.photo_notes, "resolve_storage_path", lambda _u: "p.jpg")
    monkeypatch.setattr(main.media_embed, "download_bytes", _boom)

    seen = {}

    async def _capture(_message, image=None, system_prompt=None, **_kw):
        seen["image"] = image
        seen["prompt"] = system_prompt
        return gemini.Reply(text="ok, tell me about it")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "what do u think",
            "photo_url": _PHOTO_URL,
            "photo_source": "profile",
        },
    )
    assert resp.status_code == 200
    assert seen["image"] is None
    assert "which you can see attached" not in seen["prompt"]
    assert "If they tell you what it shows" in seen["prompt"]


def test_photo_edit_context_wording_when_attached():
    import main

    text = main._photo_edit_context(_PHOTO_URL, "profile", attached=True)
    assert "which you can see attached" in text
    assert "update_photo_note" in text


def test_photo_edit_context_wording_when_not_attached():
    import main

    text = main._photo_edit_context(_PHOTO_URL, "profile", attached=False)
    assert "which you can see attached" not in text
    assert "If they tell you what it shows" in text
    assert "update_photo_note" in text


def test_photo_edit_context_empty_without_a_url():
    import main

    assert main._photo_edit_context("", "profile", attached=True) == ""
