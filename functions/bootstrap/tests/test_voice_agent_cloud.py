"""Dual-cloud voice agent (ARCHITECTURE §1.1): the per-user ``voice_agent_cloud``
flag, its ``/voice/agent-cloud`` endpoint, and the explicit-dispatch routing on
the room-seed path. Default is ``livekit`` (a no-pref user routes to the hosted
``ayma-lk`` worker); an explicit ``cloudrun`` pref still routes to Cloud Run."""

import json

import livekit_token
import main
import schema
from config import CONFIG
import pytest
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: {"uid": uid})
    return {"Authorization": "Bearer valid"}


class _ProfileDoc:
    def __init__(self, stored=None):
        self.stored = dict(stored or {})
        self.written = {}

    def get(self):
        doc = self

        class _S:
            exists = True

            def to_dict(self_):
                return dict(doc.stored)

        return _S()

    def set(self, payload, merge=False):
        self.written.update(payload)
        self.stored.update(payload)


def _patch_db(monkeypatch, doc):
    monkeypatch.setattr(main.schema, "profile_doc", lambda _db, _uid: doc)
    monkeypatch.setattr(main, "get_db", lambda: object())


# --- flag resolution --------------------------------------------------------

def test_flag_defaults_to_livekit_when_unset(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    assert main._voice_agent_cloud("me") == "livekit"
    assert schema.VOICE_AGENT_CLOUD_DEFAULT == "livekit"


def test_default_env_override_per_environment(monkeypatch):
    # Each environment picks its own default via the VOICE_AGENT_CLOUD_DEFAULT
    # env var (staging sets "cloudrun" so no-pref rooms route to its Cloud Run
    # worker — its separate LiveKit project has no ayma-lk; prod leaves it unset
    # = "livekit"). The constant is read from the env at import, so reload the
    # module to exercise it, and always reload back so the rest of the suite
    # sees the prod default. (founder bug R2-E2 / staging voice, 2026-11-02)
    import importlib

    try:
        monkeypatch.setenv("VOICE_AGENT_CLOUD_DEFAULT", "cloudrun")
        importlib.reload(schema)
        assert schema.VOICE_AGENT_CLOUD_DEFAULT == "cloudrun"
        # An invalid value falls back to "livekit", never crashes a voice start.
        monkeypatch.setenv("VOICE_AGENT_CLOUD_DEFAULT", "bogus")
        importlib.reload(schema)
        assert schema.VOICE_AGENT_CLOUD_DEFAULT == "livekit"
    finally:
        monkeypatch.delenv("VOICE_AGENT_CLOUD_DEFAULT", raising=False)
        importlib.reload(schema)
    assert schema.VOICE_AGENT_CLOUD_DEFAULT == "livekit"


def test_flag_resolves_livekit_when_set(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc({schema.PF_AYMA_VOICE_CLOUD: "livekit"}))
    assert main._voice_agent_cloud("me") == "livekit"


def test_flag_resolves_cloudrun_when_explicitly_set(monkeypatch):
    # Explicit opt-out still routes to Cloud Run (instant per-user rollback).
    _patch_db(monkeypatch, _ProfileDoc({schema.PF_AYMA_VOICE_CLOUD: "cloudrun"}))
    assert main._voice_agent_cloud("me") == "cloudrun"


def test_flag_unknown_value_falls_back_to_default(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc({schema.PF_AYMA_VOICE_CLOUD: "bogus"}))
    assert main._voice_agent_cloud("me") == "livekit"


def test_flag_read_error_falls_back_to_default(monkeypatch):
    class _Boom:
        def get(self):
            raise RuntimeError("firestore down")

    _patch_db(monkeypatch, _Boom())
    assert main._voice_agent_cloud("me") == "livekit"


# --- GET/POST /voice/agent-cloud -------------------------------------------

def test_get_agent_cloud_default(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    resp = client.get("/voice/agent-cloud", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    body = resp.json()
    assert body["current"] == "livekit"
    assert body["default"] == "livekit"
    assert set(body["options"]) == {"cloudrun", "livekit"}


def test_post_agent_cloud_sets_livekit(monkeypatch):
    doc = _ProfileDoc()
    _patch_db(monkeypatch, doc)
    resp = client.post(
        "/voice/agent-cloud",
        headers=_auth(monkeypatch),
        json={"cloud": "livekit"},
    )
    assert resp.status_code == 200
    assert resp.json()["current"] == "livekit"
    assert doc.written[schema.PF_AYMA_VOICE_CLOUD] == "livekit"


def test_post_agent_cloud_rejects_unknown(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    resp = client.post(
        "/voice/agent-cloud",
        headers=_auth(monkeypatch),
        json={"cloud": "aws"},
    )
    assert resp.status_code == 422


def test_agent_cloud_requires_auth():
    assert client.get("/voice/agent-cloud").status_code in (401, 403)


# --- room seed marker -------------------------------------------------------

def test_build_room_seed_defaults_marker_cloudrun():
    seed = json.loads(livekit_token.build_room_seed("sys", [], "u", "s"))
    assert seed["voice_agent_cloud"] == "cloudrun"


def test_build_room_seed_carries_livekit_marker():
    seed = json.loads(
        livekit_token.build_room_seed(
            "sys", [], "u", "s", voice_agent_cloud="livekit"
        )
    )
    assert seed["voice_agent_cloud"] == "livekit"


# --- explicit-dispatch routing on seed_room_context ------------------------

class _FakeRoomSvc:
    def __init__(self):
        self.created = []

    async def create_room(self, req):
        self.created.append(req)

    async def update_room_metadata(self, req):
        pass


class _FakeLiveKitAPI:
    last = None

    def __init__(self, *a, **k):
        self.room = _FakeRoomSvc()
        _FakeLiveKitAPI.last = self

    async def aclose(self):
        pass


@pytest.mark.asyncio
async def test_seed_room_context_default_has_no_explicit_dispatch(monkeypatch):
    monkeypatch.setattr(livekit_token.api, "LiveKitAPI", _FakeLiveKitAPI)
    await livekit_token.seed_room_context("ayma-room1", "{}")
    req = _FakeLiveKitAPI.last.room.created[0]
    # No explicit agent dispatch => LiveKit auto-dispatch to Cloud Run (today).
    assert len(req.agents) == 0


@pytest.mark.asyncio
async def test_seed_room_context_livekit_routes_to_agent_name(monkeypatch):
    monkeypatch.setattr(livekit_token.api, "LiveKitAPI", _FakeLiveKitAPI)
    await livekit_token.seed_room_context("ayma-room2", "{}", agent_name="ayma-lk")
    req = _FakeLiveKitAPI.last.room.created[0]
    assert [a.agent_name for a in req.agents] == ["ayma-lk"]


# --- default path: no pref => explicit ayma-lk dispatch --------------------

def _dispatch_agent_for(cloud: str):
    """Mirror of the /bootstrap dispatch decision (main.py): the explicit
    LiveKit agent_name when the resolved cloud is ``livekit``, else ``None``
    (automatic dispatch to the Cloud Run worker)."""
    return CONFIG.agent_name_livekit if cloud == "livekit" else None


def test_default_path_dispatches_to_ayma_lk(monkeypatch):
    # A user with no pref resolves to the livekit default and the room is
    # created with EXPLICIT dispatch to the hosted agent_name (ayma-lk).
    _patch_db(monkeypatch, _ProfileDoc())
    resolved = main._voice_agent_cloud("me")
    assert resolved == "livekit"
    assert _dispatch_agent_for(resolved) == CONFIG.agent_name_livekit


def test_explicit_cloudrun_uses_automatic_dispatch(monkeypatch):
    # An explicit cloudrun pref => no explicit agent dispatch (Cloud Run auto).
    _patch_db(monkeypatch, _ProfileDoc({schema.PF_AYMA_VOICE_CLOUD: "cloudrun"}))
    resolved = main._voice_agent_cloud("me")
    assert resolved == "cloudrun"
    assert _dispatch_agent_for(resolved) is None
