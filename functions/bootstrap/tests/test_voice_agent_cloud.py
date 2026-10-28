"""Dual-cloud voice agent (ARCHITECTURE §1.1): the per-user ``voice_agent_cloud``
flag, its ``/voice/agent-cloud`` endpoint, and the explicit-dispatch routing on
the room-seed path. Default is ``cloudrun`` (production unchanged); ``livekit``
routes the room to the LiveKit-Cloud-hosted worker's ``agent_name``."""

import json

import livekit_token
import main
import schema
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

def test_flag_defaults_to_cloudrun_when_unset(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    assert main._voice_agent_cloud("me") == "cloudrun"


def test_flag_resolves_livekit_when_set(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc({schema.PF_AYMA_VOICE_CLOUD: "livekit"}))
    assert main._voice_agent_cloud("me") == "livekit"


def test_flag_unknown_value_falls_back_to_cloudrun(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc({schema.PF_AYMA_VOICE_CLOUD: "bogus"}))
    assert main._voice_agent_cloud("me") == "cloudrun"


def test_flag_read_error_falls_back_to_cloudrun(monkeypatch):
    class _Boom:
        def get(self):
            raise RuntimeError("firestore down")

    _patch_db(monkeypatch, _Boom())
    assert main._voice_agent_cloud("me") == "cloudrun"


# --- GET/POST /voice/agent-cloud -------------------------------------------

def test_get_agent_cloud_default(monkeypatch):
    _patch_db(monkeypatch, _ProfileDoc())
    resp = client.get("/voice/agent-cloud", headers=_auth(monkeypatch))
    assert resp.status_code == 200
    body = resp.json()
    assert body["current"] == "cloudrun"
    assert body["default"] == "cloudrun"
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
