import dataclasses

import jwt as pyjwt
import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

import livekit_token
from config import CONFIG
from main import app

client = TestClient(app)

_SECRET = "test-livekit-secret-value-0123456789"
_KEY = "test-livekit-key"


def _valid_auth(monkeypatch):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _token: {"uid": "test-uid-123"}
    )
    return {"Authorization": "Bearer valid"}


def _livekit_env(monkeypatch, *, url="wss://test.livekit.cloud"):
    patched = dataclasses.replace(CONFIG, livekit_url=url)
    monkeypatch.setattr(main, "CONFIG", patched)
    monkeypatch.setattr(livekit_token, "CONFIG", patched)
    monkeypatch.setenv("LIVEKIT_API_KEY", _KEY)
    monkeypatch.setenv("LIVEKIT_API_SECRET", _SECRET)
    seeds = []

    async def _fake_seed(room, seed_json):
        seeds.append((room, seed_json))

    monkeypatch.setattr(main, "seed_room_context", _fake_seed)
    return seeds


def test_bootstrap_requires_a_token():
    resp = client.post("/bootstrap")
    assert resp.status_code in (401, 403)  # missing Bearer credentials


def test_bootstrap_rejects_a_bad_token(monkeypatch):
    def _raise(_token):
        raise firebase_auth.InvalidIdTokenError("bad token")

    monkeypatch.setattr(firebase_auth, "verify_id_token", _raise)
    resp = client.post("/bootstrap", headers={"Authorization": "Bearer nope"})
    assert resp.status_code == 401


def test_bootstrap_returns_session_mode_for_a_valid_token(monkeypatch):
    _livekit_env(monkeypatch)
    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    body = resp.json()
    assert body["session_mode"] in ("marketing", "interview", "active")
    assert body["uid"] == "test-uid-123"


def test_bootstrap_mints_a_room_scoped_livekit_token(monkeypatch):
    _livekit_env(monkeypatch, url="wss://test.livekit.cloud")
    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    lk = resp.json()["livekit"]
    assert lk["url"] == "wss://test.livekit.cloud"
    assert lk["room"] == "ayma-test-uid-123"

    claims = pyjwt.decode(lk["token"], _SECRET, algorithms=["HS256"])
    assert claims["sub"] == "test-uid-123"
    assert claims["iss"] == _KEY
    assert claims["video"]["room"] == "ayma-test-uid-123"
    assert claims["video"]["roomJoin"] is True
    assert claims["exp"] > claims["nbf"]


def test_bootstrap_seeds_the_room_with_recent_turns(monkeypatch):
    import json

    seeds = _livekit_env(monkeypatch)
    resp = client.post(
        "/bootstrap",
        headers=_valid_auth(monkeypatch),
        json={
            "recent_turns": [
                {"role": "user", "text": "started this out loud"},
                {"role": "ayma", "text": "go on"},
            ]
        },
    )
    assert resp.status_code == 200
    assert len(seeds) == 1
    room, seed_json = seeds[0]
    assert room == "ayma-test-uid-123"
    seed = json.loads(seed_json)
    assert "started this out loud" in seed["system_prompt"]
    assert seed["recent_turns"][0] == {
        "role": "user",
        "text": "started this out loud",
    }


def test_bootstrap_works_without_a_body(monkeypatch):
    seeds = _livekit_env(monkeypatch)
    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    assert len(seeds) == 1
    _, seed_json = seeds[0]
    assert '"recent_turns": []' in seed_json


def test_bootstrap_503_when_livekit_unconfigured(monkeypatch):
    patched = dataclasses.replace(CONFIG, livekit_url="")
    monkeypatch.setattr(main, "CONFIG", patched)
    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 503


def test_bootstrap_503_when_signing_credentials_missing(monkeypatch):
    patched = dataclasses.replace(CONFIG, livekit_url="wss://test.livekit.cloud")
    monkeypatch.setattr(main, "CONFIG", patched)
    monkeypatch.setattr(livekit_token, "CONFIG", patched)
    monkeypatch.delenv("LIVEKIT_API_KEY", raising=False)
    monkeypatch.delenv("LIVEKIT_API_SECRET", raising=False)
    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 503
