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


def test_bootstrap_refuses_voice_when_out_of_credits(monkeypatch):
    _livekit_env(monkeypatch)

    def _capped(uid):
        raise main.token_ledger.TokenCapExceeded("out of credits")

    monkeypatch.setattr(main.token_ledger, "check", _capped)
    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    body = resp.json()
    assert body["usage_capped"] is True
    assert body["uid"] == "test-uid-123"
    # Being out of credits must not strand a signed-in user in marketing mode:
    # `session_mode` is still returned so the client routes to its real screen.
    assert body["session_mode"] in ("marketing", "interview", "active")
    assert "livekit" not in body


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
            "session_id": "s-real-voice-session",
            "recent_turns": [
                {"role": "user", "text": "started this out loud"},
                {"role": "ayma", "text": "go on"},
            ],
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


def test_bootstrap_seeds_with_empty_recent_turns_for_a_real_session(monkeypatch):
    """A genuine first-ever voice call: a real (non-empty) `session_id` but no
    history yet — still seeds the room, just with an empty `recent_turns`."""
    seeds = _livekit_env(monkeypatch)
    resp = client.post(
        "/bootstrap",
        headers=_valid_auth(monkeypatch),
        json={"session_id": "s-first-ever-call"},
    )
    assert resp.status_code == 200
    assert len(seeds) == 1
    _, seed_json = seeds[0]
    assert '"recent_turns": []' in seed_json


def test_bootstrap_without_a_session_id_never_touches_the_voice_room(monkeypatch):
    """`splash_screen.dart` calls `/bootstrap` with `session_id=''` purely to
    read `session_mode` for routing — it never connects to voice at all. This
    must not create/seed the user's voice room (`room_name_for` is
    deterministic — one room reused across every real call) or wake the
    scale-to-zero agent: either would leave that room seeded with this
    call's empty context ahead of the user's real, later voice-start call,
    which an already-dispatched agent job would never see (root-caused
    against the founder's "Ayma keeps re-asking already-covered ground"
    report, 2026-09-25). The response must still carry a usable LiveKit
    token, unchanged, since `splash_screen.dart`'s own response parsing
    requires the `livekit` key to be present."""
    seeds = _livekit_env(monkeypatch)
    woken = []
    monkeypatch.setattr(main.agent_wake, "wake_agent", lambda: woken.append(1))

    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    body = resp.json()
    assert body["livekit"]["token"]
    assert body["livekit"]["room"] == "ayma-test-uid-123"
    assert seeds == []
    assert woken == []

    # Same outcome when the client sends an explicit empty session_id (what
    # splash_screen.dart actually does) rather than omitting the field.
    resp2 = client.post(
        "/bootstrap", headers=_valid_auth(monkeypatch), json={"session_id": ""}
    )
    assert resp2.status_code == 200
    assert seeds == []
    assert woken == []


def test_bootstrap_schedules_the_one_time_web_self_dive(monkeypatch):
    _livekit_env(monkeypatch)
    monkeypatch.setattr(main, "_should_auto_dive", lambda _uid: True)
    seen = []

    async def _spy(_db, uid):
        seen.append(uid)

    monkeypatch.setattr(main.auto_analysis, "analyse_web", _spy)

    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    # TestClient drains background tasks after the response.
    assert seen == ["test-uid-123"]


def test_bootstrap_wakes_the_scale_to_zero_agent(monkeypatch):
    """ayma-agent runs min-instances=0 (docs/deploy.md §12.2) — a real
    voice-start /bootstrap call (a non-empty session_id — see
    `newSessionId()`) must fire the wake ping so Cloud Run starts the
    container in parallel with the LiveKit token mint, not leave it to
    LiveKit dispatch alone. (The routing-only, empty-session_id call
    `splash_screen.dart` makes deliberately skips this — see
    `test_bootstrap_without_a_session_id_never_touches_the_voice_room`.)"""
    _livekit_env(monkeypatch)
    woken = []
    monkeypatch.setattr(main.agent_wake, "wake_agent", lambda: woken.append(1))

    resp = client.post(
        "/bootstrap",
        headers=_valid_auth(monkeypatch),
        json={"session_id": "s-real-voice-session"},
    )
    assert resp.status_code == 200
    # TestClient drains background tasks after the response.
    assert woken == [1]


def test_bootstrap_skips_the_web_dive_when_not_eligible(monkeypatch):
    _livekit_env(monkeypatch)
    monkeypatch.setattr(main, "_should_auto_dive", lambda _uid: False)
    seen = []

    async def _spy(_db, uid):
        seen.append(uid)

    monkeypatch.setattr(main.auto_analysis, "analyse_web", _spy)

    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    assert seen == []


def test_bootstrap_schedules_the_one_time_photo_scan_as_a_fallback(monkeypatch):
    """`/bootstrap` still fires the one-time reverse-image scan as a fallback
    for any caller that never reaches `POST /onboarding/complete` (§ web
    photo search — reliable trigger)."""
    _livekit_env(monkeypatch)
    monkeypatch.setattr(main, "_should_auto_scan_photos", lambda _uid: True)
    seen = []

    async def _spy(_db, uid):
        seen.append(uid)

    monkeypatch.setattr(main.reverse_image_search, "auto_scan", _spy)

    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    assert seen == ["test-uid-123"]


def test_bootstrap_skips_the_photo_scan_when_not_eligible(monkeypatch):
    _livekit_env(monkeypatch)
    monkeypatch.setattr(main, "_should_auto_scan_photos", lambda _uid: False)
    seen = []

    async def _spy(_db, uid):
        seen.append(uid)

    monkeypatch.setattr(main.reverse_image_search, "auto_scan", _spy)

    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    assert seen == []


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


# --- POST /welcome/token (pre-sign-in greeting) ------------------------


def test_welcome_token_needs_no_auth_and_seeds_a_greeting(monkeypatch):
    seeds = _livekit_env(monkeypatch)
    main._welcome_hits.clear()

    resp = client.post("/welcome/token")
    assert resp.status_code == 200
    body = resp.json()
    assert body["livekit"]["url"] == "wss://test.livekit.cloud"
    assert body["livekit"]["token"]
    assert body["livekit"]["room"].startswith("welcome-")

    room, seed_json = seeds[-1]
    assert room.startswith("welcome-")
    assert "greeting_instructions" in seed_json
    assert "sign in" in seed_json


def test_welcome_token_wakes_the_scale_to_zero_agent(monkeypatch):
    _livekit_env(monkeypatch)
    main._welcome_hits.clear()
    woken = []
    monkeypatch.setattr(main.agent_wake, "wake_agent", lambda: woken.append(1))

    resp = client.post("/welcome/token")
    assert resp.status_code == 200
    assert woken == [1]


def test_welcome_token_rate_limits_per_ip(monkeypatch):
    _livekit_env(monkeypatch)
    main._welcome_hits.clear()
    codes = [client.post("/welcome/token").status_code for _ in range(6)]
    assert codes.count(200) == main._WELCOME_MAX_PER_MIN
    assert codes[-1] == 429


def test_welcome_token_503_when_livekit_unconfigured(monkeypatch):
    patched = dataclasses.replace(CONFIG, livekit_url="")
    monkeypatch.setattr(main, "CONFIG", patched)
    main._welcome_hits.clear()
    assert client.post("/welcome/token").status_code == 503
