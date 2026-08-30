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
        return reply

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


def test_chat_rejects_empty_message(monkeypatch):
    resp = client.post("/chat", json={"message": ""}, headers=_auth(monkeypatch))
    assert resp.status_code == 422


def test_chat_feeds_recent_turns_into_the_system_prompt(monkeypatch):
    seen = {}

    async def _capture(message, system_prompt=None, **_kw):
        seen["prompt"] = system_prompt
        return "ok"

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
        return "aye"

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
    # Same full window is handed to wiki ingest (§2.3).
    assert len(no_firestore.ingested) == 1
    assert no_firestore.ingested[0]["session_id"] == "sess-abc123"
    assert [
        (t.role, t.text) for t in no_firestore.ingested[0]["turns"]
    ] == [(t.role, t.text) for t in call["turns"]]


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


def test_chat_with_an_image_moderates_then_passes_it_to_gemini(monkeypatch):
    import main

    monkeypatch.setattr(
        main.media_embed, "download_bytes",
        lambda _p: (b"JPEGBYTES", "image/jpeg"),
    )

    async def _ok(_b, _m):
        return {"allowed": True, "reason": "", "categories": []}

    monkeypatch.setattr(main.photo_moderation, "moderate", _ok)
    monkeypatch.setattr(main.chat_history, "append", lambda *a, **k: None)

    seen = {}

    async def _capture(_message, image=None, **_kw):
        seen["image"] = image
        return "nice pic"

    monkeypatch.setattr(gemini, "generate_reply", _capture)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={"message": "what's this?",
              "image_path": "uploads/test-uid/chat_1.jpg"},
    )
    assert resp.status_code == 200
    assert resp.json()["reply"] == "nice pic"
    assert seen["image"] == (b"JPEGBYTES", "image/jpeg")


def test_chat_rejects_an_image_outside_the_callers_uploads(monkeypatch):
    _stub_gemini(monkeypatch)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={"message": "x", "image_path": "uploads/someone-else/x.jpg"},
    )
    assert resp.status_code == 403


def test_chat_refuses_a_flagged_image_without_calling_the_model(monkeypatch):
    import main

    monkeypatch.setattr(
        main.media_embed, "download_bytes", lambda _p: (b"x", "image/jpeg")
    )

    async def _blocked(_b, _m):
        return {"allowed": False, "reason": "nudity", "categories": ["nudity"]}

    monkeypatch.setattr(main.photo_moderation, "moderate", _blocked)
    monkeypatch.setattr(gemini, "generate_reply", _boom_should_not_run)
    resp = client.post(
        "/chat",
        headers=_auth(monkeypatch),
        json={"message": "x", "image_path": "uploads/test-uid/x.jpg"},
    )
    assert resp.status_code == 200
    assert resp.json()["image_rejected"] is True


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
