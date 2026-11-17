"""Hosted voice dispatch: detection-only failure watcher (§1.1).

Everything voice runs on the LiveKit-Cloud hosted worker (``ayma-lk``). The
GCP Cloud Run workers were DELETED on 2026-11-06, so there is no worker to
fall back to. These tests pin:

* ``livekit_token.watch_hosted_dispatch`` — polls a freshly-seeded
  livekit-routed room; when NO agent joins within the window it LOGS the
  failure (returns True) and leaves the room untouched — it never flips the
  marker, wakes Cloud Run or dispatches (prod feedback RFLpFWkaaCuDC0ew1MUT:
  a silent-voice call that left no backend trail, and flipping to the deleted
  Cloud Run target would only have made the hosted worker decline the room).
* The welcome room's move to explicit ``ayma-lk`` dispatch (it was the last
  always-on Cloud Run consumer).
* Practice Date voice routing through the same resolution (it originally
  bypassed it and always landed on Cloud Run).
"""

import dataclasses
import json
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth
from starlette.background import BackgroundTasks

import livekit_token
import main
import practice_date
import schema
from config import CONFIG

client = TestClient(main.app)

_SECRET = "<redacted>"
_KEY = "test-livekit-key"
_AGENT_KIND = 4  # ParticipantInfo.Kind.AGENT
_USER_KIND = 0  # ParticipantInfo.Kind.STANDARD


# --- shared fakes -----------------------------------------------------------


class _ProfileDoc:
    def __init__(self, stored=None):
        self.stored = dict(stored or {})

    def get(self):
        doc = self

        class _S:
            exists = True

            def to_dict(self_):
                return dict(doc.stored)

        return _S()


class _FakeRoomSvc:
    """Scripted room service: each list_participants call pops the next
    scripted outcome (a list of participant kinds, or an Exception to raise);
    the last outcome repeats."""

    def __init__(self, script, metadata=""):
        self._script = list(script)
        self._metadata = metadata
        self.updated = []

    async def list_participants(self, _req):
        item = self._script.pop(0) if len(self._script) > 1 else self._script[0]
        if isinstance(item, Exception):
            raise item
        return SimpleNamespace(
            participants=[SimpleNamespace(kind=k) for k in item]
        )

    async def list_rooms(self, req):
        return SimpleNamespace(
            rooms=[SimpleNamespace(name=req.names[0], metadata=self._metadata)]
        )

    async def update_room_metadata(self, req):
        self.updated.append(req)
        self._metadata = req.metadata


class _FakeDispatchSvc:
    def __init__(self):
        self.created = []

    async def create_dispatch(self, req):
        self.created.append(req)
        return SimpleNamespace()


class _FakeLK:
    def __init__(self, room_svc):
        self.room = room_svc
        self.agent_dispatch = _FakeDispatchSvc()

    async def aclose(self):
        pass


def _patch_lk(monkeypatch, room_svc):
    fake = _FakeLK(room_svc)
    monkeypatch.setattr(livekit_token.api, "LiveKitAPI", lambda *a, **k: fake)
    return fake


def _seed_json(cloud="livekit"):
    return json.dumps({"voice_agent_cloud": cloud, "uid": "u1"})


# --- watch_hosted_dispatch ---------------------------------------------------


@pytest.mark.asyncio
async def test_watch_no_fallback_when_agent_joins(monkeypatch):
    room = _FakeRoomSvc([[_AGENT_KIND]], metadata=_seed_json())
    fake = _patch_lk(monkeypatch, room)
    fired = await livekit_token.watch_hosted_dispatch(
        "ayma-u1-x", timeout_seconds=0.2, poll_seconds=0.01
    )
    assert fired is False
    assert room.updated == []
    assert fake.agent_dispatch.created == []


@pytest.mark.asyncio
async def test_watch_flags_when_agent_never_joins(monkeypatch, caplog):
    room = _FakeRoomSvc([[_USER_KIND]], metadata=_seed_json())
    fake = _patch_lk(monkeypatch, room)

    with caplog.at_level("WARNING", logger="ayma.livekit_token"):
        fired = await livekit_token.watch_hosted_dispatch(
            "ayma-u1-x", timeout_seconds=0.05, poll_seconds=0.01
        )
    # The missing agent is DETECTED and logged — and the room is left exactly
    # as routed: no marker flip, no Cloud Run wake, no dispatch (that worker is
    # gone; flipping would only make the hosted worker decline the room).
    assert fired is True
    assert room.updated == []
    assert fake.agent_dispatch.created == []
    assert any(
        "did not join room ayma-u1-x" in r.message for r in caplog.records
    )


@pytest.mark.asyncio
async def test_watch_leaves_room_alone_when_caller_left(monkeypatch):
    gone = livekit_token.api.TwirpError(
        "not_found", "could not find room", status=404
    )
    room = _FakeRoomSvc([gone], metadata=_seed_json())
    fake = _patch_lk(monkeypatch, room)
    fired = await livekit_token.watch_hosted_dispatch(
        "ayma-u1-x", timeout_seconds=0.05, poll_seconds=0.01
    )
    assert fired is False
    assert room.updated == []
    assert fake.agent_dispatch.created == []


@pytest.mark.asyncio
async def test_watch_never_flags_a_cloudrun_marked_room(monkeypatch):
    # A cloudrun-marked room is not one the hosted worker was meant to serve,
    # so the watcher never flags it (and, as always, never touches it).
    room = _FakeRoomSvc([[_USER_KIND]], metadata=_seed_json("cloudrun"))
    fake = _patch_lk(monkeypatch, room)
    fired = await livekit_token.watch_hosted_dispatch(
        "ayma-u1-x", timeout_seconds=0.0, poll_seconds=0.01
    )
    assert fired is False
    assert room.updated == []
    assert fake.agent_dispatch.created == []


@pytest.mark.asyncio
async def test_watch_no_flag_if_agent_joins_during_the_window(monkeypatch):
    # First poll: only the caller. Final re-check (deadline already passed):
    # the hosted agent has arrived after all — a merely-slow agent is not
    # falsely flagged.
    room = _FakeRoomSvc([[_USER_KIND], [_AGENT_KIND]], metadata=_seed_json())
    fake = _patch_lk(monkeypatch, room)
    fired = await livekit_token.watch_hosted_dispatch(
        "ayma-u1-x", timeout_seconds=0.0, poll_seconds=0.01
    )
    assert fired is False
    assert room.updated == []
    assert fake.agent_dispatch.created == []


# --- endpoint routing: welcome + bootstrap schedule the watcher -------------


def _endpoint_env(monkeypatch):
    patched = dataclasses.replace(CONFIG, livekit_url="wss://test.livekit.cloud")
    monkeypatch.setattr(main, "CONFIG", patched)
    monkeypatch.setattr(livekit_token, "CONFIG", patched)
    monkeypatch.setenv("LIVEKIT_API_KEY", _KEY)
    monkeypatch.setenv("LIVEKIT_API_SECRET", _SECRET)
    seeds = []

    async def _fake_seed(room, seed_json, agent_name=None):
        seeds.append((room, seed_json, agent_name))

    monkeypatch.setattr(main, "seed_room_context", _fake_seed)
    watched = []

    async def _fake_watch(room):
        watched.append(room)
        return False

    monkeypatch.setattr(main, "watch_hosted_dispatch", _fake_watch)
    return seeds, watched


def test_welcome_room_routes_to_the_hosted_worker(monkeypatch):
    seeds, watched = _endpoint_env(monkeypatch)
    main._welcome_hits.clear()

    resp = client.post("/welcome/token")
    assert resp.status_code == 200
    room = resp.json()["livekit"]["room"]
    seed_room, seed_json, agent_name = seeds[-1]
    assert seed_room == room
    # Explicit dispatch to ayma-lk + the "livekit" marker the hosted worker's
    # request_fnc guard requires — and no Cloud Run wake at seed time.
    assert agent_name == CONFIG.agent_name_livekit
    assert json.loads(seed_json)["voice_agent_cloud"] == "livekit"
    # The failure-only fallback watcher is armed for the room.
    assert watched == [room]


def test_bootstrap_livekit_room_arms_the_fallback_watcher(monkeypatch):
    seeds, watched = _endpoint_env(monkeypatch)
    monkeypatch.setattr(
        firebase_auth,
        "verify_id_token",
        lambda _t: {"uid": "test-uid-123"},
    )
    resp = client.post(
        "/bootstrap",
        headers={"Authorization": "Bearer x"},
        json={"session_id": "s-watch", "recent_turns": []},
    )
    assert resp.status_code == 200
    room = resp.json()["livekit"]["room"]
    assert seeds[-1][0] == room
    assert seeds[-1][2] == CONFIG.agent_name_livekit
    assert watched == [room]


# --- Practice Date voice routes through the same resolution -----------------


def _practice_env(monkeypatch, stored=None):
    patched = dataclasses.replace(
        CONFIG, livekit_url="wss://test.livekit.cloud"
    )
    monkeypatch.setattr(practice_date, "CONFIG", patched)
    monkeypatch.setattr(livekit_token, "CONFIG", patched)
    monkeypatch.setenv("LIVEKIT_API_KEY", _KEY)
    monkeypatch.setenv("LIVEKIT_API_SECRET", _SECRET)
    monkeypatch.setattr(practice_date, "get_db", lambda: object())
    monkeypatch.setattr(
        schema, "profile_doc", lambda _db, _uid: _ProfileDoc(stored)
    )
    monkeypatch.setattr(
        practice_date,
        "build_persona_context",
        lambda _db, _uid, _target: SimpleNamespace(
            name="Sofia",
            gender="female",
            age=29,
            location="San Jose",
            photo_count=3,
            photo_url="",
        ),
    )
    monkeypatch.setattr(
        practice_date.token_ledger, "check", lambda _uid: None
    )
    monkeypatch.setattr(
        practice_date,
        "start_or_resume_session",
        lambda _db, _uid, _target, **_kw: "sess-1",
    )
    monkeypatch.setattr(
        practice_date, "_caller_first_name", lambda _db, _uid: "Sam"
    )
    monkeypatch.setattr(
        practice_date,
        "compose_persona_prompt",
        lambda _ctx, voice, user_name: "persona prompt",
    )
    seeds = []

    async def _fake_seed(room, seed_json, agent_name=None):
        seeds.append((room, seed_json, agent_name))

    monkeypatch.setattr(practice_date, "seed_room_context", _fake_seed)

    async def _fake_watch(_room):
        return False

    monkeypatch.setattr(practice_date, "watch_hosted_dispatch", _fake_watch)
    return seeds


def _background_funcs(background):
    return [task.func for task in background.tasks]


@pytest.mark.asyncio
async def test_practice_voice_defaults_to_the_hosted_worker(monkeypatch):
    seeds = _practice_env(monkeypatch)
    background = BackgroundTasks()
    caller = practice_date.Caller(
        uid="me", is_anonymous=False, sign_in_provider="google"
    )
    resp = await practice_date.practice_voice_start(
        practice_date.VoiceStartRequest(other_uid="other-1"),
        background,
        caller,
    )
    assert resp["livekit"]["room"]
    _room, seed_json, agent_name = seeds[-1]
    assert agent_name == CONFIG.agent_name_livekit
    assert json.loads(seed_json)["voice_agent_cloud"] == "livekit"
    funcs = _background_funcs(background)
    assert practice_date.watch_hosted_dispatch in funcs


