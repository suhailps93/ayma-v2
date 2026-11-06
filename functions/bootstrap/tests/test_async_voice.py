"""Async voice messages (``async_voice`` + ``POST /voice/async``).

The job is exercised end to end with every boundary faked (Storage,
Firestore job doc, STT/LLM/TTS legs, thread persistence): the tests pin the
stage order, the idempotency contract, every honest-error branch, and —
via :func:`test_async_path_makes_no_direct_provider_calls` — the founder
rule that the async path never touches a direct provider.
"""

from __future__ import annotations

import asyncio
import dataclasses

from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import async_voice
import chat_history
import gemini
import inference_tts
import main
import media_embed
import notifications_triggers
import public_profile
import session_mode
import token_ledger
import turn_caps
from config import CONFIG
from transcript import Turn

client = TestClient(main.app)

_WAV = (
    b"RIFF$\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00"
    b"\x80>\x00\x00\x00}\x00\x00\x02\x00\x10\x00data\x00\x00\x00\x00"
)


class _FakeDoc:
    def __init__(self):
        self.data: dict = {}
        self.exists = False
        self._cols: dict[str, _FakeCol] = {}

    def get(self):
        return self

    def to_dict(self):
        return dict(self.data)

    def set(self, data, merge=False):
        if merge:
            self.data.update(data)
        else:
            self.data = dict(data)
        self.exists = True

    def collection(self, name):
        return self._cols.setdefault(name, _FakeCol())


class _FakeCol:
    def __init__(self):
        self.docs: dict[str, _FakeDoc] = {}

    def document(self, doc_id):
        return self.docs.setdefault(doc_id, _FakeDoc())


class _FakeDb:
    def __init__(self):
        self._cols: dict[str, _FakeCol] = {}

    def collection(self, name):
        return self._cols.setdefault(name, _FakeCol())


class _FakeBlob:
    def __init__(self):
        self.uploads: list[tuple[bytes, str]] = []

    def upload_from_string(self, data, content_type):
        self.uploads.append((data, content_type))


class _Ctx:
    def __init__(self, monkeypatch):
        self.db = _FakeDb()
        self.statuses: list[str] = []
        self.appends: list[dict] = []
        self.persisted: list[dict] = []
        self.notified: list[str] = []
        self.fake_blob = _FakeBlob()
        self.job_id = "v-testjob1"
        self.clip = _WAV
        self.mime = "audio/wav"
        self.transcript = "hello ayma"
        self.reply = "hi there"
        self.tools = ["Searched the web"]

        from turn_caps import TurnCapResult

        monkeypatch.setattr(
            session_mode, "derive_for", lambda _db, _uid, _anon: "active"
        )
        monkeypatch.setattr(
            turn_caps, "evaluate",
            lambda _db, _uid, _mode: TurnCapResult(True, None, False, "active", 0, 0),
        )
        monkeypatch.setattr(
            media_embed, "download_bytes", lambda _p: (self.clip, self.mime)
        )

        async def _fake_json(*_a, **_k):
            return {"text": self.transcript}

        monkeypatch.setattr(gemini, "generate_json", _fake_json)

        async def _fake_prompt(_db, _uid, _mode, _window):
            return "system prompt"

        monkeypatch.setattr(async_voice, "_compose_prompt", _fake_prompt)

        async def _fake_reply(*_a, **_k):
            return gemini.Reply(text=self.reply, tools_used=list(self.tools))

        monkeypatch.setattr(gemini, "generate_reply", _fake_reply)
        monkeypatch.setattr(
            inference_tts, "synthesize", lambda *_a, **_k: _async(_WAV)
        )
        from firebase_admin import storage

        monkeypatch.setattr(storage, "bucket", lambda _n: self)
        monkeypatch.setattr(
            public_profile, "_photo_url",
            lambda _p: "https://cdn.example/r.wav",
        )
        monkeypatch.setattr(
            chat_history, "append",
            lambda _db, _uid, role, text, **kw: self.appends.append(
                {"role": role, "text": text, **kw}
            ),
        )
        monkeypatch.setattr(
            chat_history, "user_turn_exists", lambda *_a: False
        )
        monkeypatch.setattr(
            main, "_persist_session",
            lambda uid, sid, turns: self.persisted.append(
                {"uid": uid, "session_id": sid, "turns": list(turns)}
            ),
        )

        async def _fake_notify(_db, _uid, text):
            self.notified.append(text)

        monkeypatch.setattr(
            notifications_triggers, "notify_ayma_reply", _fake_notify
        )
        real_update = async_voice._update_job

        def _spy_update(db, uid, job_id, **fields):
            if "status" in fields:
                self.statuses.append(fields["status"])
            return real_update(db, uid, job_id, **fields)

        monkeypatch.setattr(async_voice, "_update_job", _spy_update)

    # The fake Storage bucket: ``storage.bucket(name)`` returns this ctx.
    def blob(self, _path):
        return self.fake_blob

    def run(self):
        async_voice.create_job(
            self.db, "u1", self.job_id,
            f"uploads/u1/async_voice/{self.job_id}.wav", "s-1",
        )
        return asyncio.run(async_voice.run_job(
            self.db, "u1",
            job_id=self.job_id,
            storage_path=f"uploads/u1/async_voice/{self.job_id}.wav",
            session_id="s-1",
            recent_turns=[Turn("user", "earlier")],
            is_anonymous=False,
        ))

    def job(self):
        return async_voice.fetch_job(self.db, "u1", self.job_id)


async def _async(value):
    return value


def _auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": "u1"}
    )
    return {"Authorization": "Bearer [REDACTED]"}


def test_happy_path_delivers_thread_and_payload(monkeypatch):
    ctx = _Ctx(monkeypatch)
    payload = ctx.run()
    assert payload["status"] == "done"
    assert payload["transcript"] == "hello ayma"
    assert payload["reply_text"] == "hi there"
    assert payload["reply_audio_url"] == "https://cdn.example/r.wav"
    assert payload["tools"] == ["Searched the web"]
    assert ctx.statuses == ["transcribing", "thinking", "speaking", "done"]
    stored = ctx.job()
    assert stored["status"] == "done"
    assert stored["reply_audio_path"] == (
        f"ayma_generated/u1/async_voice/{ctx.job_id}.wav"
    )
    # The reply lands in the same thread, tagged with the job id.
    assert [a["role"] for a in ctx.appends] == ["user", "ayma"]
    user, ayma = ctx.appends
    assert user["text"] == "hello ayma"
    assert user["audio_path"] == f"uploads/u1/async_voice/{ctx.job_id}.wav"
    assert user["client_msg_id"] == ctx.job_id
    assert ayma["text"] == "hi there"
    assert ayma["audio_url"] == "https://cdn.example/r.wav"
    assert ayma["client_msg_id"] == ctx.job_id
    # raw_turns carries the full window; a backgrounded user is notified.
    assert [t.text for t in ctx.persisted[0]["turns"]] == [
        "earlier", "hello ayma", "hi there",
    ]
    assert ctx.notified == ["hi there"]
    # The spoken clip uploaded as wav.
    assert ctx.fake_blob.uploads == [(_WAV, "audio/wav")]


def test_user_turn_is_idempotent_per_job(monkeypatch):
    ctx = _Ctx(monkeypatch)
    monkeypatch.setattr(chat_history, "user_turn_exists", lambda *_a: True)
    ctx.run()
    assert [a["role"] for a in ctx.appends] == ["ayma"]


def test_turn_cap_refuses_honestly(monkeypatch):
    ctx = _Ctx(monkeypatch)
    from turn_caps import TurnCapResult

    monkeypatch.setattr(
        turn_caps, "evaluate",
        lambda _db, _u, m: TurnCapResult(False, "get started first", False, m, 9, 9),
    )
    payload = ctx.run()
    assert payload["status"] == "error"
    assert payload["capped"] is True
    assert payload["error"] == "get started first"
    assert ctx.appends == []


def test_foreign_clip_path_refuses(monkeypatch):
    ctx = _Ctx(monkeypatch)
    out = asyncio.run(async_voice.run_job(
        ctx.db, "u1", job_id=ctx.job_id,
        storage_path="uploads/other/x.wav", session_id="s-1",
        recent_turns=[], is_anonymous=False,
    ))
    assert out["status"] == "error"
    assert "isn't yours" in out["error"]


def test_oversize_clip_refuses(monkeypatch):
    ctx = _Ctx(monkeypatch)
    monkeypatch.setattr(
        async_voice, "CONFIG",
        dataclasses.replace(CONFIG, async_voice_max_clip_bytes=10),
    )
    assert ctx.run()["error"].startswith("That voice message is too long")


def test_undecodable_mime_refuses_without_a_direct_fallback(monkeypatch):
    ctx = _Ctx(monkeypatch)
    ctx.mime = "audio/m4a"
    payload = ctx.run()
    assert payload["status"] == "error"
    assert "couldn't read" in payload["error"]


def test_missing_clip_fails_honestly(monkeypatch):
    ctx = _Ctx(monkeypatch)

    def _boom(_p):
        raise FileNotFoundError("gone")

    monkeypatch.setattr(media_embed, "download_bytes", _boom)
    payload = ctx.run()
    assert payload["status"] == "error"
    assert "couldn't fetch" in payload["error"]


def test_empty_transcript_fails_honestly_and_persists_nothing(monkeypatch):
    ctx = _Ctx(monkeypatch)
    ctx.transcript = "  "
    payload = ctx.run()
    assert payload["status"] == "error"
    assert "couldn't hear anything" in payload["error"]
    assert ctx.appends == []


def test_out_of_credits_at_stt_is_usage_capped(monkeypatch):
    ctx = _Ctx(monkeypatch)

    async def _broke(*_a, **_k):
        raise token_ledger.TokenCapExceeded()

    monkeypatch.setattr(gemini, "generate_json", _broke)
    payload = ctx.run()
    assert payload["status"] == "error"
    assert payload["usage_capped"] is True
    assert "credit" in payload["error"].lower()
    assert ctx.appends == []


def test_out_of_credits_at_llm_keeps_the_user_turn(monkeypatch):
    ctx = _Ctx(monkeypatch)

    async def _broke(*_a, **_k):
        raise token_ledger.TokenCapExceeded()

    monkeypatch.setattr(gemini, "generate_reply", _broke)
    payload = ctx.run()
    assert payload["usage_capped"] is True
    assert payload["transcript"] == "hello ayma"
    assert [a["role"] for a in ctx.appends] == ["user"]


def test_llm_failure_fails_honestly(monkeypatch):
    ctx = _Ctx(monkeypatch)

    async def _boom(*_a, **_k):
        raise RuntimeError("gateway down")

    monkeypatch.setattr(gemini, "generate_reply", _boom)
    payload = ctx.run()
    assert payload["status"] == "error"
    assert payload["transcript"] == "hello ayma"


def test_tts_failure_still_delivers_the_transcript(monkeypatch):
    ctx = _Ctx(monkeypatch)

    async def _boom(*_a, **_k):
        raise inference_tts.InferenceTTSError("tts down")

    monkeypatch.setattr(inference_tts, "synthesize", _boom)
    payload = ctx.run()
    assert payload["status"] == "done"
    assert payload["reply_text"] == "hi there"
    assert payload["reply_audio_url"] == ""
    assert [a["role"] for a in ctx.appends] == ["user", "ayma"]


def test_route_requires_auth():
    resp = client.post("/voice/async", json={
        "job_id": "v-x", "storage_path": "uploads/u1/x.wav",
    })
    assert resp.status_code in (401, 403)


def test_route_submits_and_spawns(monkeypatch):
    headers = _auth(monkeypatch)
    calls: dict = {}

    async def _fake_run(_db, _uid, **kw):
        calls.update(kw)
        return {"job_id": kw["job_id"], "status": "done"}

    monkeypatch.setattr(async_voice, "fetch_job", lambda *_a: None)
    monkeypatch.setattr(
        async_voice, "create_job",
        lambda _db, _u, j, _p, _s: calls.setdefault("created", j),
    )
    monkeypatch.setattr(async_voice, "run_job", _fake_run)
    resp = client.post("/voice/async", headers=headers, json={
        "job_id": "v-abc", "storage_path": "uploads/u1/async_voice/v-abc.wav",
        "session_id": "s-9",
        "recent_turns": [{"role": "user", "text": "hey"}],
    })
    assert resp.status_code == 200
    assert resp.json() == {"job_id": "v-abc", "status": "received"}
    assert calls["created"] == "v-abc"
    assert [(t.role, t.text) for t in calls["recent_turns"]] == [
        ("user", "hey")
    ]
    assert calls["session_id"] == "s-9"


def test_route_rejects_a_bad_job_id(monkeypatch):
    headers = _auth(monkeypatch)
    resp = client.post("/voice/async", headers=headers, json={
        "job_id": "../evil", "storage_path": "uploads/u1/x.wav",
    })
    assert resp.status_code == 422


def test_route_answers_a_finished_job_from_store(monkeypatch):
    headers = _auth(monkeypatch)
    monkeypatch.setattr(async_voice, "fetch_job", lambda *_a: {
        "status": "done", "transcript": "t", "reply_text": "r",
        "reply_audio_url": "u", "tools": ["Searched the web"], "image_url": "",
    })
    ran = []
    monkeypatch.setattr(
        async_voice, "run_job",
        lambda *_a, **_k: ran.append(True) or _async({}),
    )
    resp = client.post("/voice/async", headers=headers, json={
        "job_id": "v-done", "storage_path": "uploads/u1/x.wav",
    })
    assert resp.json()["status"] == "done"
    assert resp.json()["reply_text"] == "r"
    assert ran == []


def test_route_joins_an_inflight_job(monkeypatch):
    headers = _auth(monkeypatch)
    monkeypatch.setattr(
        async_voice, "fetch_job", lambda *_a: {"status": "thinking"}
    )
    main._INFLIGHT_TURNS[("u1", "v-live")] = object()
    try:
        resp = client.post("/voice/async", headers=headers, json={
            "job_id": "v-live", "storage_path": "uploads/u1/x.wav",
        })
    finally:
        main._INFLIGHT_TURNS.pop(("u1", "v-live"), None)
    assert resp.json() == {
        "job_id": "v-live", "status": "thinking", "joined": True,
    }


def test_route_reruns_an_errored_job(monkeypatch):
    headers = _auth(monkeypatch)
    monkeypatch.setattr(
        async_voice, "fetch_job", lambda *_a: {"status": "error"}
    )
    created = []
    monkeypatch.setattr(
        async_voice, "create_job",
        lambda _db, _u, j, _p, _s: created.append(j),
    )
    monkeypatch.setattr(
        async_voice, "run_job", lambda *_a, **_k: _async({"status": "done"})
    )
    resp = client.post("/voice/async", headers=headers, json={
        "job_id": "v-retry", "storage_path": "uploads/u1/x.wav",
    })
    assert resp.json()["status"] == "received"
    assert created == ["v-retry"]


def test_async_path_makes_no_direct_provider_calls():
    """Grep gate (founder rule, permanent): the async voice path — job +
    TTS client — must route every inference leg through LiveKit and never
    construct a direct Google/Vertex call. This scans the two modules'
    source (not the AST gate's whole tree) so the async path's own diff
    carries its proof."""
    import pathlib

    root = pathlib.Path(__file__).resolve().parent.parent
    sources = {
        name: (root / name).read_text(encoding="utf-8")
        for name in ("async_voice.py", "inference_tts.py")
    }
    forbidden = (
        "google.genai",
        "google-genai",
        "vertexai",
        "VertexAI",
        "aiplatform",
        "generativelanguage",
        "GOOGLE_API_KEY",
        "google.auth",
        "google.cloud",
        ".batches",
        "generate_content",
        "genai.Client",
        "plugins.google",
    )
    offenders = {
        name: [tok for tok in forbidden if tok in src]
        for name, src in sources.items()
    }
    # No hardcoded provider endpoint either: the gateway base URL comes only
    # from config (the ws-scheme swap matches bare "http(s)://" prefixes,
    # which carry no host and so don't trip this).
    import re

    for name, src in sources.items():
        for url in re.findall(r"https?://[a-zA-Z0-9]", src):
            offenders.setdefault(name, []).append(f"hardcoded endpoint {url}…")
    offenders = {n: toks for n, toks in offenders.items() if toks}
    assert not offenders, (
        "direct-provider call in the async voice path (all inference must "
        f"go through the LiveKit gateway): {offenders}"
    )
    for name, src in sources.items():
        assert "livekit" in src.lower(), f"{name} never mentions LiveKit"
