import asyncio
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


def test_chat_stream_turn_timeout_ends_in_an_error_event(monkeypatch):
    import main

    async def _events(_message, *_a, **_kw):
        yield {"type": "status", "label": "Thinking…"}
        await asyncio.sleep(3600)

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    monkeypatch.setattr(main, "_CHAT_TURN_TIMEOUT_SECONDS", 0.05)
    resp = client.post(
        "/chat/stream", json={"message": "set app to dark mode"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    events = _parse_sse(resp.text)
    assert events[-1] == {"type": "error", "detail": main._CHAT_TIMEOUT_DETAIL}


def test_chat_stream_sends_keepalives_while_a_turn_is_quiet(monkeypatch):
    import main

    async def _events(_message, *_a, **_kw):
        await asyncio.sleep(0.2)
        yield {"type": "reply", "text": "ok", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    monkeypatch.setattr(main, "_SSE_KEEPALIVE_SECONDS", 0.05)
    resp = client.post(
        "/chat/stream", json={"message": "slow one"}, headers=_auth(monkeypatch),
    )
    assert ": keepalive" in resp.text
    assert _parse_sse(resp.text)[-1]["text"] == "ok"


def test_chat_stream_tool_set_includes_the_app_control_tools(monkeypatch):
    seen = {}

    async def _events(_message, *_a, **kw):
        seen["decls"] = {d["name"] for d in kw["tool_declarations"]}
        seen["fns"] = set(kw["tool_fns"])
        yield {"type": "reply", "text": "done", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    client.post(
        "/chat/stream", json={"message": "set app to dark mode"},
        headers=_auth(monkeypatch),
    )
    assert "app_action" in seen["decls"] and "app_action" in seen["fns"]
    assert "open_screen" in seen["fns"]


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


# --- GW-SCROLL variant B: a turn must never evaporate ----------------------
# The Explore scroll-to-end overran the ack bound → the follow-up produced no
# reply → the whole turn vanished from history, user message and all. The turn
# now persists the user message at START and always finalizes with an honest
# reply, so a slow/failed turn always leaves a truthful record.

def _recording_history(monkeypatch):
    """Monkeypatch chat_history so persistence is captured in-memory and
    ``user_turn_exists`` reflects what was recorded (so the start-persist /
    finalize de-dup of the user turn is exercised faithfully)."""
    import main

    appended: list[tuple[str, str]] = []

    def _append(_db, _uid, role, text, **_kw):
        appended.append((role, text))

    def _user_exists(_db, _uid, _cid):
        return any(r == "user" for r, _ in appended)

    monkeypatch.setattr(main.chat_history, "append", _append)
    monkeypatch.setattr(main.chat_history, "user_turn_exists", _user_exists)
    return appended


def test_chat_stream_errored_turn_persists_user_and_an_honest_reply(monkeypatch):
    import main

    async def _events(_message, *_a, **_kw):
        yield {"type": "status", "label": "Thinking…"}
        # What the Explore scroll turn hit: the follow-up after the (timed-out)
        # tool produced nothing and the provider raised.
        raise RuntimeError("Gemini returned an empty response.")

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    appended = _recording_history(monkeypatch)
    resp = client.post(
        "/chat/stream",
        json={"message": "scroll to the bottom", "client_msg_id": "c-evap"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    events = _parse_sse(resp.text)
    # a live client still saw an honest error…
    assert any(e.get("type") == "error" for e in events)
    # …but the turn did NOT evaporate: the user message + one honest ayma
    # reply are persisted, exactly once each.
    roles = [r for r, _ in appended]
    assert roles.count("user") == 1, appended
    assert ("user", "scroll to the bottom") in appended
    assert ("ayma", main._CHAT_INCOMPLETE_REPLY) in appended


def test_chat_errored_turn_persists_user_and_an_honest_reply(monkeypatch):
    import main

    async def _fail(_message, **_kw):
        raise RuntimeError("Gemini returned an empty response.")

    monkeypatch.setattr(gemini, "generate_reply", _fail)
    appended = _recording_history(monkeypatch)
    resp = client.post(
        "/chat",
        json={"message": "scroll to the top", "client_msg_id": "c-evap2"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    assert resp.json()["reply"] == main._CHAT_INCOMPLETE_REPLY
    roles = [r for r, _ in appended]
    assert roles.count("user") == 1, appended
    assert ("user", "scroll to the top") in appended
    assert ("ayma", main._CHAT_INCOMPLETE_REPLY) in appended


def test_chat_stream_normal_turn_persists_one_user_and_one_ayma(monkeypatch):
    async def _events(_message, *_a, **_kw):
        yield {"type": "reply", "text": "all set", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    appended = _recording_history(monkeypatch)
    resp = client.post(
        "/chat/stream",
        json={"message": "hey", "client_msg_id": "c-ok"},
        headers=_auth(monkeypatch),
    )
    assert resp.status_code == 200
    roles = [r for r, _ in appended]
    # start-persist + finalize must not double the user turn.
    assert roles.count("user") == 1 and roles.count("ayma") == 1, appended
    assert ("user", "hey") in appended and ("ayma", "all set") in appended


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
        lambda _db, _uid, **_kw: "### interests — sailing\nThey sail on weekends.",
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


# --- Floating Ayma launcher: the page-context (`screen`/`screen_*`) the
# Flutter client's `AppContext` snapshot carries in, folded into the prompt
# via `skills.app_control._describe` for anything other than "profile" (which
# already gets a full briefing through `viewing_profile_uid`). ---


def test_chat_screen_context_reaches_the_prompt(monkeypatch):
    seen = {}

    async def _capture(message, system_prompt=None, **_kw):
        seen["prompt"] = system_prompt
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "what do you think",
            "screen": "explore",
            "screen_note": "tall guys in Austin",
        },
    )
    assert resp.status_code == 200
    assert "searching for 'tall guys in Austin'" in seen["prompt"]


def test_chat_screen_context_skipped_when_profile_already_briefed(monkeypatch):
    import main

    monkeypatch.setattr(
        main.public_profile_mod,
        "_viewing_profile_context",
        lambda _db, _uid, _other: "Full briefing on them.",
    )
    seen = {}

    async def _capture(message, system_prompt=None, **_kw):
        seen["prompt"] = system_prompt
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "what do you think",
            "screen": "profile",
            "viewing_profile_uid": "other-uid",
            "screen_subject_uid": "other-uid",
            "screen_subject_name": "Alex",
        },
    )
    assert resp.status_code == 200
    assert "Full briefing on them." in seen["prompt"]
    assert "looking at Alex's profile" not in seen["prompt"]


# --- Match report chat: unlike Story/deep-dive/Appearance, the score itself
# can't be edited, but a disputed fact behind it should be corrected via
# Ayma's existing profile/questionnaire tools, then picked up by a
# Recalculate (§ founder gap — Match previously got no report-specific
# briefing at all). ---


def test_chat_from_match_report_briefs_ayma_to_fix_the_underlying_fact(
    monkeypatch,
):
    seen = {}

    async def _capture(message, system_prompt=None, **_kw):
        seen["prompt"] = system_prompt
        return gemini.Reply(text="got it, updated your location")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "I don't live in Colorado",
            "match_report_id": "test-uid_other-uid",
        },
    )
    assert resp.status_code == 200
    prompt = seen["prompt"]
    assert "MATCH REPORT" in prompt
    assert "can't edit the score" in prompt
    assert "set_profile_field" in prompt
    assert "record_answer" in prompt
    assert "Recalculate" in prompt


def test_chat_without_match_report_id_gets_no_match_briefing(monkeypatch):
    seen = {}

    async def _capture(message, system_prompt=None, **_kw):
        seen["prompt"] = system_prompt
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat", headers=_auth(monkeypatch), json={"message": "hi"}
    )
    assert resp.status_code == 200
    assert "MATCH REPORT" not in seen["prompt"]


def test_chat_from_match_report_still_lands_in_chat_history(monkeypatch):
    """Same as the story-editor case: a match-report-scoped turn goes through
    the exact same `_finalize_chat` as any ordinary chat turn."""
    import main

    calls = []
    monkeypatch.setattr(
        main.chat_history,
        "append",
        lambda _db, uid, role, text, **kw: calls.append((role, text, kw)),
    )
    _stub_gemini(monkeypatch, "updated your location, tap Recalculate")
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "I don't live in Colorado",
            "match_report_id": "test-uid_other-uid",
        },
    )
    assert resp.status_code == 200
    assert [(r, t) for r, t, _ in calls] == [
        ("user", "I don't live in Colorado"),
        ("ayma", "updated your location, tap Recalculate"),
    ]


def test_image_gen_turn_persists_image_path_and_durable_url(monkeypatch):
    """Founder bug 2026-09-27: a generate_image turn displayed fine live but
    vanished from the transcript on reopen — only ``image_path`` was
    persisted, and its ``ayma_generated/…`` path is unreadable to the client
    SDK (Storage rules). The whole delivery chain, end to end: the bound
    ``generate_image`` tool fills the shared ``ctx.photo_edit_result`` sink →
    the reply carries ``image_url`` → ``_finalize_chat`` persists the turn
    with BOTH the path and the durable token URL."""
    import main
    from skills import generate_image as gen_mod

    async def fake_model(prompt, *, image=None, uid=None, feature=""):
        return b"TREEBYTES", "image/png"

    async def fake_moderate(image_bytes, mime_type, **_kw):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(gen_mod.gemini, "generate_image", fake_model)
    monkeypatch.setattr(gen_mod.photo_moderation, "moderate", fake_moderate)
    monkeypatch.setattr(
        gen_mod, "_store_generated_photo",
        lambda uid, b, m: (
            f"ayma_generated/{uid}/tree.png",
            "https://firebasestorage.googleapis.com/v0/b/x/o/tree?alt=media&token=t9",
        ),
    )

    appended = []
    monkeypatch.setattr(
        main.chat_history,
        "append",
        lambda _db, uid, role, text, **kw: appended.append((role, text, kw)),
    )

    async def _fake_reply(_message, tool_fns=None, **_kw):
        # The model decides to draw: it calls the bound tool exactly as the
        # real Gemini tool loop would, then answers with the sink now filled.
        out = await tool_fns["generate_image"](prompt="my story as a tree")
        assert out == "done — sent the image in the chat"
        return gemini.Reply(
            text="Here's a tree mapping your journey",
            tools_used=["Generated an image"],
        )

    monkeypatch.setattr(gemini, "generate_reply", _fake_reply)

    resp = client.post(
        "/chat", headers=_auth(monkeypatch),
        json={"message": "can you draw me a chart showing my story as a tree"},
    )
    assert resp.status_code == 200
    # The live reply carries the URL (this part always worked)…
    assert resp.json()["image_url"].endswith("token=t9")
    # …and now the persisted turn does too, so it survives a reload.
    role, text, kw = appended[-1]
    assert (role, text) == ("ayma", "Here's a tree mapping your journey")
    assert kw["image_path"] == "ayma_generated/test-uid/tree.png"
    assert kw["image_url"].endswith("token=t9")
    assert kw["tools"] == ["Generated an image"]


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
    import asyncio

    import main

    monkeypatch.setattr(
        main.media_embed, "download_bytes",
        lambda _p: (b"JPEGBYTES", "image/jpeg"),
    )
    _stub_gemini(monkeypatch, "nice pic")

    # The follow-ups now run in a detached turn task (so a client disconnect
    # can't cancel them) rather than FastAPI's post-response hook — drive the
    # app on one live loop and drain those tasks before asserting.
    async def _run():
        import httpx

        transport = httpx.ASGITransport(app=main.app)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test"
        ) as ac:
            resp = await ac.post(
                "/chat",
                headers=_auth(monkeypatch),
                json={
                    "message": "what's this?",
                    "session_id": "sess-img1",
                    "image_path": "uploads/test-uid/chat_1.jpg",
                },
            )
        while main._TURN_TASKS:
            await asyncio.gather(
                *list(main._TURN_TASKS), return_exceptions=True
            )
        return resp

    resp = asyncio.run(_run())
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


def test_chat_completes_honestly_when_gemini_fails(monkeypatch):
    # A generation failure no longer 502s and discards the turn: it completes
    # with the honest fallback reply and persists the turn, so the user is
    # never left with a silent non-response (GW-SCROLL variant B; founder rule).
    import main

    async def _boom(*_args, **_kwargs):
        raise RuntimeError("model exploded")

    monkeypatch.setattr(gemini, "generate_reply", _boom)
    resp = client.post(
        "/chat", json={"message": "hi"}, headers=_auth(monkeypatch)
    )
    assert resp.status_code == 200
    assert resp.json()["reply"] == main._CHAT_INCOMPLETE_REPLY


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
    # Routes through the shared out-of-credits copy (token_ledger.py) rather
    # than a hand-typed string.
    assert body["reply"] == token_ledger.out_of_credits_message(token_ledger.CONTEXT_CHAT)


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


def test_chat_with_a_plain_attached_photo_still_exposes_edit_photo(
    monkeypatch, no_firestore
):
    # § founder report: "make him a wolf" on a photo attached directly in the
    # main chat (no `photo_url`/Your Story origin) got "I can't actually edit
    # or generate photos" — edit_photo was only ever bound when `photo_url`
    # was set. Must be exposed for a bare `image_path` attachment too.
    import main

    monkeypatch.setattr(
        main.media_embed, "download_bytes",
        lambda _p: (b"JPEGBYTES", "image/jpeg"),
    )
    seen = {}

    async def _capture(_message, tool_declarations=None, system_prompt=None,
                        **_kw):
        seen["names"] = {d["name"] for d in (tool_declarations or [])}
        seen["prompt"] = system_prompt
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "make him a wolf",
            "image_path": "uploads/test-uid/chat_1.jpg",
        },
    )
    assert resp.status_code == 200
    assert "edit_photo" in seen["names"]
    assert "call `edit_photo`" in seen["prompt"]


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


# --- cost-program Phase 2: context diet (CONTEXT_OPT_LEVEL >= 2) --------------


def _capture_prompt(monkeypatch):
    seen = {}

    async def _capture(message, system_prompt=None, **_kw):
        seen["prompt"] = system_prompt
        return gemini.Reply(text="ok")

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    return seen


def _long_window(n=100):
    return [
        {"role": "user" if i % 2 == 0 else "ayma", "text": f"old turn {i}"}
        for i in range(n)
    ]


def test_chat_level2_prompt_carries_summary_plus_tail_not_the_full_window(
    monkeypatch,
):
    import context_opt

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")
    monkeypatch.setattr(
        context_opt, "stored_summary_text",
        lambda _db, _uid: "Earlier: their sister Meera lives in Kochi.",
    )
    seen = _capture_prompt(monkeypatch)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={"message": "hello again", "recent_turns": _long_window(100)},
    )
    assert resp.status_code == 200
    prompt = seen["prompt"]
    assert "old turn 99" in prompt  # the raw tail survives
    assert "old turn 0" not in prompt  # the deep history is gone from the prompt
    assert "Meera" in prompt  # ...but the rolling summary carries it


def test_chat_level0_prompt_still_carries_the_full_window(monkeypatch):
    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    seen = _capture_prompt(monkeypatch)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={"message": "hello again", "recent_turns": _long_window(100)},
    )
    assert resp.status_code == 200
    assert "old turn 0" in seen["prompt"]
    assert "old turn 99" in seen["prompt"]
    assert "running summary" not in seen["prompt"]


def test_chat_level2_short_window_needs_no_summary_read(monkeypatch):
    """A window at/below the raw tail is passed whole — no summary read, no
    summary block, nothing lost."""
    import context_opt

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")

    def _boom(_db, _uid):
        raise AssertionError("summary must not be read for a short window")

    monkeypatch.setattr(context_opt, "stored_summary_text", _boom)
    seen = _capture_prompt(monkeypatch)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={"message": "hi", "recent_turns": _long_window(6)},
    )
    assert resp.status_code == 200
    assert "old turn 0" in seen["prompt"]


def test_chat_level2_wiki_is_trimmed_to_message_relevant_page_types(monkeypatch):
    import context_opt
    import main

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")
    calls = []

    def _recorder(_db, _uid, *a, **k):
        calls.append(k)
        return ""

    monkeypatch.setattr(main, "read_wiki_context", _recorder)
    _stub_gemini(monkeypatch)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={"message": "my job interview went great"},
    )
    assert resp.status_code == 200
    assert len(calls) == 1
    k = calls[0]
    assert k["max_chars"] == context_opt.trim_wiki_chars()
    assert context_opt.CORE_PAGE_TYPES <= k["include_page_types"]
    assert "career" in k["include_page_types"]


def test_chat_level0_wiki_call_shape_is_unchanged(monkeypatch):
    import main

    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    calls = []

    def _recorder(_db, _uid, *a, **k):
        calls.append((a, k))
        return ""

    monkeypatch.setattr(main, "read_wiki_context", _recorder)
    _stub_gemini(monkeypatch)
    resp = client.post(
        "/chat", headers=_auth(monkeypatch), json={"message": "hi"}
    )
    assert resp.status_code == 200
    # Level 0 keeps the full-wiki shape (no max_chars / include_page_types
    # diet) — the only filter on any level is the `assessment` judgment page,
    # which never rides in the standing chat context (ai_assessment.py).
    import ai_assessment

    assert calls == [
        ((), {"exclude_page_types": ai_assessment.EXCLUDED_FROM_CHAT_CONTEXT})
    ]


def test_chat_level2_schedules_the_background_summary_update(monkeypatch):
    import context_opt

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")
    monkeypatch.setattr(context_opt, "stored_summary_text", lambda *_a: "")
    updated = []

    async def _fake_update(_db, uid, window, *, session_id=""):
        updated.append((uid, len(window), session_id))
        return True

    monkeypatch.setattr(context_opt, "maybe_update_summary", _fake_update)
    _stub_gemini(monkeypatch)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "hi",
            "session_id": "s1",
            "recent_turns": _long_window(30),
        },
    )
    assert resp.status_code == 200
    # window(30) + this turn's user+ayma appended by _finalize_chat; the
    # chat session id threads through for real-money spend attribution.
    assert updated == [("test-uid", 32, "s1")]


def test_chat_level0_never_schedules_a_summary_update(monkeypatch):
    import context_opt

    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    updated = []

    async def _fake_update(*_a):
        updated.append(1)

    monkeypatch.setattr(context_opt, "maybe_update_summary", _fake_update)
    _stub_gemini(monkeypatch)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={
            "message": "hi",
            "session_id": "s1",
            "recent_turns": _long_window(30),
        },
    )
    assert resp.status_code == 200
    assert updated == []


# ---------------------------------------------------------------------------
# Disconnection-proof turns + client_msg_id idempotency (founder bug
# 2026-09-28: backgrounding the app mid-send cancelled the /chat/stream
# generator inside the Gemini call, losing the reply after it was billed).
# ---------------------------------------------------------------------------


def _asgi_scope(path: str) -> dict:
    return {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.3"},
        "http_version": "1.1",
        "method": "POST",
        "scheme": "http",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "root_path": "",
        "headers": [
            (b"authorization", b"Bearer valid"),
            (b"content-type", b"application/json"),
            (b"host", b"test"),
        ],
        "client": ("127.0.0.1", 1),
        "server": ("test", 80),
    }


async def _post_with_disconnect(path: str, body: dict, disconnect):
    """Drive main.app over raw ASGI: deliver the request body, then an
    ``http.disconnect`` as soon as ``disconnect`` is set — exactly what
    uvicorn feeds starlette when the phone backgrounds the app and the OS
    kills the socket mid-request."""
    import json as _json

    import main

    body_bytes = _json.dumps(body).encode()
    sent_body = False

    async def receive():
        nonlocal sent_body
        if not sent_body:
            sent_body = True
            return {
                "type": "http.request", "body": body_bytes, "more_body": False
            }
        await disconnect.wait()
        return {"type": "http.disconnect"}

    messages = []

    async def send(message):
        messages.append(message)

    await main.app(_asgi_scope(path), receive, send)
    return messages


async def _drain_turns():
    import asyncio

    import main

    while main._TURN_TASKS:
        await asyncio.gather(*list(main._TURN_TASKS), return_exceptions=True)


def test_stream_client_disconnect_still_persists_the_full_turn(monkeypatch):
    """The founder bug, reproduced at the transport level: the client socket
    drops mid-generation. The turn must still finish (not be cancelled inside
    the Gemini call) and the reply must still land in chat history."""
    import asyncio

    import main

    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    state = {"cancelled": False, "finished": False, "calls": 0}
    reached_generation = asyncio.Event()

    async def _events(_message, *_a, **_kw):
        state["calls"] += 1
        yield {"type": "status", "label": "Creating that image…"}
        reached_generation.set()
        try:
            await asyncio.sleep(0.2)  # the slow (billed) Gemini call
        except asyncio.CancelledError:
            state["cancelled"] = True
            raise
        state["finished"] = True
        yield {"type": "reply", "text": "here you go", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    appended = []
    monkeypatch.setattr(
        main.chat_history, "append",
        lambda _db, uid, role, text, **kw: appended.append((role, text, kw)),
    )
    monkeypatch.setattr(
        main.chat_history, "reply_for_client_id", lambda *_a: None
    )

    async def run():
        disconnect = asyncio.Event()

        async def drop_when_generating():
            await reached_generation.wait()
            disconnect.set()

        dropper = asyncio.create_task(drop_when_generating())
        await _post_with_disconnect(
            "/chat/stream",
            {"message": "draw me a cat", "client_msg_id": "cm-cat-1"},
            disconnect,
        )
        await dropper
        await _drain_turns()

    asyncio.run(run())
    assert state["finished"] is True
    assert state["cancelled"] is False
    roles = [(r, t) for r, t, _ in appended]
    assert ("user", "draw me a cat") in roles
    assert ("ayma", "here you go") in roles
    # both rows are stamped with the send's client id, so a reconciling
    # client can find this turn by exact id
    assert all(kw.get("client_msg_id") == "cm-cat-1" for _, _, kw in appended)


def test_chat_duplicate_client_msg_id_is_answered_without_regenerating(
    monkeypatch,
):
    """A retry of a send that already completed (and was billed) must be
    answered from the persisted reply — never generated or billed again."""
    import main
    from tests.fake_firestore import FakeDb

    db = FakeDb({
        ("users", "test-uid", "chat_messages", "m1"): {
            "role": "user", "text": "draw me a cat",
            "client_msg_id": "cm-dup-1",
        },
        ("users", "test-uid", "chat_messages", "m2"): {
            "role": "ayma", "text": "already drew it",
            "client_msg_id": "cm-dup-1",
            "tools": ["Generated an image"],
            "image_url": "https://img.example/cat.png",
        },
    })
    monkeypatch.setattr(main, "get_db", lambda: db)
    calls = {"n": 0}

    async def _fake(_message, **_kw):
        calls["n"] += 1
        return gemini.Reply(text="a fresh (double-billed) reply")

    monkeypatch.setattr(gemini, "generate_reply", _fake)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={"message": "draw me a cat", "client_msg_id": "cm-dup-1"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["reply"] == "already drew it"
    assert body["tools_used"] == ["Generated an image"]
    assert body["image_url"] == "https://img.example/cat.png"
    assert body["duplicate"] is True
    assert calls["n"] == 0  # no second Gemini call, no second bill


def test_chat_stream_duplicate_client_msg_id_replays_the_persisted_reply(
    monkeypatch,
):
    import main
    from tests.fake_firestore import FakeDb

    db = FakeDb({
        ("users", "test-uid", "chat_messages", "m2"): {
            "role": "ayma", "text": "already answered",
            "client_msg_id": "cm-dup-2",
        },
    })
    monkeypatch.setattr(main, "get_db", lambda: db)
    calls = {"n": 0}

    async def _events(_message, *_a, **_kw):
        calls["n"] += 1
        yield {"type": "reply", "text": "regenerated", "tools_used": []}

    monkeypatch.setattr(gemini, "generate_reply_events", _events)
    resp = client.post(
        "/chat/stream",
        headers=_auth(monkeypatch),
        json={"message": "hi again", "client_msg_id": "cm-dup-2"},
    )
    assert resp.status_code == 200
    events = _parse_sse(resp.text)
    assert len(events) == 1
    assert events[0]["type"] == "reply"
    assert events[0]["text"] == "already answered"
    assert events[0]["duplicate"] is True
    assert calls["n"] == 0


def test_chat_retry_while_first_attempt_still_running_joins_it(monkeypatch):
    """A retry that lands while the original send is STILL generating (the
    app came back before the turn finished) must adopt that run's reply, not
    start a second generation."""
    import asyncio

    import main

    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "test-uid"}
    )
    monkeypatch.setattr(
        main.chat_history, "reply_for_client_id", lambda *_a: None
    )
    monkeypatch.setattr(
        main.chat_history, "append", lambda *_a, **_kw: None
    )
    calls = {"n": 0}
    release = None  # created on the test's own loop below

    async def _fake(_message, **_kw):
        calls["n"] += 1
        await release.wait()
        return gemini.Reply(text="one shared reply")

    monkeypatch.setattr(gemini, "generate_reply", _fake)

    async def run():
        nonlocal release
        release = asyncio.Event()
        import httpx

        transport = httpx.ASGITransport(app=main.app)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test"
        ) as ac:
            body = {"message": "slow one", "client_msg_id": "cm-join-1"}
            headers = {"Authorization": "Bearer valid"}
            first = asyncio.create_task(
                ac.post("/chat", json=body, headers=headers)
            )
            # let the first request reach the (gated) Gemini call
            for _ in range(50):
                await asyncio.sleep(0.01)
                if calls["n"]:
                    break
            second = asyncio.create_task(
                ac.post("/chat", json=body, headers=headers)
            )
            await asyncio.sleep(0.05)
            release.set()
            r1, r2 = await asyncio.gather(first, second)
        await _drain_turns()
        return r1, r2

    r1, r2 = asyncio.run(run())
    assert r1.status_code == 200 and r2.status_code == 200
    assert r1.json()["reply"] == "one shared reply"
    assert r2.json()["reply"] == "one shared reply"
    assert calls["n"] == 1  # generated (and billed) exactly once


def test_finalize_chat_skips_a_turn_already_persisted_for_that_client_id(
    monkeypatch,
):
    """The cross-instance guard: a twin finalize (retry raced the shielded
    original on another instance) must not append the turn twice."""
    import main
    from fastapi import BackgroundTasks
    from tests.fake_firestore import FakeDb

    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    ctx = main._ChatCtx(
        uid="test-uid", image=None, image_path="", window=[],
        system_prompt="sp",
    )
    req = main.ChatRequest(message="hello", client_msg_id="cm-fin-1")
    main._finalize_chat(BackgroundTasks(), ctx, req, "first reply")
    main._finalize_chat(BackgroundTasks(), ctx, req, "second reply")
    rows = [
        d for k, d in db.docs.items()
        if k[:3] == ("users", "test-uid", "chat_messages")
    ]
    assert [(r["role"], r["text"]) for r in rows] == [
        ("user", "hello"), ("ayma", "first reply"),
    ]


def test_finalize_chat_schedules_an_ayma_reply_push(monkeypatch):
    """Every persisted reply is pushed (the OS hides it while the app is
    foregrounded); a twin finalize for the same send must not push twice."""
    import main
    from fastapi import BackgroundTasks
    from tests.fake_firestore import FakeDb

    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    ctx = main._ChatCtx(
        uid="test-uid", image=None, image_path="", window=[],
        system_prompt="sp",
    )
    req = main.ChatRequest(message="hello", client_msg_id="cm-push-1")
    first, second = BackgroundTasks(), BackgroundTasks()
    main._finalize_chat(first, ctx, req, "the reply")
    main._finalize_chat(second, ctx, req, "the reply")
    pushes = [
        t.args for t in first.tasks
        if t.func is main.notifications_triggers.notify_ayma_reply
    ]
    assert pushes == [(db, "test-uid", "the reply")]
    assert second.tasks == []


def test_out_of_credits_turn_is_not_persisted_so_a_resend_runs_normally(
    monkeypatch,
):
    """The client's out-of-credits queue relies on this: a capped turn writes
    nothing, so re-sending the SAME client_msg_id once credits are back is a
    fresh turn (not a 'duplicate'), and a further retry dedups as usual."""
    import main
    import token_ledger
    from tests.fake_firestore import FakeDb

    db = FakeDb()
    monkeypatch.setattr(main, "get_db", lambda: db)
    state = {"credits": 0, "calls": 0}

    async def _fake(_message, **_kw):
        state["calls"] += 1
        if state["credits"] <= 0:
            raise token_ledger.TokenCapExceeded("0/0")
        return gemini.Reply(text="welcome back")

    monkeypatch.setattr(gemini, "generate_reply", _fake)
    body = {"message": "hi", "client_msg_id": "cm-queue-1"}

    async def run():
        import httpx

        transport = httpx.ASGITransport(app=main.app)
        async with httpx.AsyncClient(
            transport=transport, base_url="http://test"
        ) as ac:
            headers = {"Authorization": "Bearer valid"}
            capped = await ac.post("/chat", json=body, headers=headers)
            await _drain_turns()
            state["credits"] = 10
            sent = await ac.post("/chat", json=body, headers=headers)
            await _drain_turns()
            retry = await ac.post("/chat", json=body, headers=headers)
            return capped, sent, retry

    import asyncio

    _auth(monkeypatch)
    capped, sent, retry = asyncio.run(run())
    assert capped.json()["usage_capped"] is True
    assert sent.json()["reply"] == "welcome back"
    assert "duplicate" not in sent.json()
    assert retry.json()["reply"] == "welcome back"
    assert retry.json()["duplicate"] is True
    assert state["calls"] == 2  # capped attempt + the one real generation


def test_chat_switch_brain_is_deterministic_regardless_of_active_brain(monkeypatch):
    # Founder bug 2026-11-02: Meta->Gemini brain switch was one-way because the
    # switch turn ran on Muse Spark and often didn't emit set_brain. The
    # deterministic pre-model intercept (_prepare_chat) must handle it WITHOUT
    # ever calling the model, so it works whichever brain is active.
    called = {"model": False}

    async def _fake(_message, **_kw):
        called["model"] = True
        return type("R", (), {"text": "nope", "tools_used": []})()

    monkeypatch.setattr(gemini, "generate_reply", _fake)
    r = client.post(
        "/chat", json={"message": "change back to gemini"},
        headers=_auth(monkeypatch),
    )
    assert r.status_code == 200
    assert r.json().get("reply")  # a confirmation was returned
    assert called["model"] is False  # handled deterministically; model never ran
