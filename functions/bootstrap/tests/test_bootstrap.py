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

    async def _fake_seed(room, seed_json, agent_name=None):
        seeds.append((room, seed_json))

    monkeypatch.setattr(main, "seed_room_context", _fake_seed)

    async def _fake_watch(_room):
        return False

    monkeypatch.setattr(main, "watch_hosted_dispatch", _fake_watch)
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
    assert lk["room"].startswith("ayma-test-uid-123-")

    claims = pyjwt.decode(lk["token"], _SECRET, algorithms=["HS256"])
    assert claims["sub"] == "test-uid-123"
    assert claims["iss"] == _KEY
    assert claims["video"]["room"] == lk["room"]
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
    assert room == resp.json()["livekit"]["room"]
    assert room.startswith("ayma-test-uid-123-")
    seed = json.loads(seed_json)
    assert "started this out loud" in seed["system_prompt"]
    assert seed["recent_turns"][0] == {
        "role": "user",
        "text": "started this out loud",
    }


def test_each_voice_bootstrap_gets_a_fresh_room(monkeypatch):
    """The agent is auto-dispatched only when LiveKit creates a room. A room
    name reused across calls let a redial within the old room's departure
    timeout join that still-open room, so no agent was ever dispatched
    (founder's phone, 2026-10-25). Every voice start must mint, seed and
    grant a brand-new room."""
    seeds = _livekit_env(monkeypatch)
    rooms = []
    for _ in range(3):
        resp = client.post(
            "/bootstrap",
            headers=_valid_auth(monkeypatch),
            json={"session_id": "s-same-app-session", "recent_turns": []},
        )
        assert resp.status_code == 200
        lk = resp.json()["livekit"]
        claims = pyjwt.decode(lk["token"], _SECRET, algorithms=["HS256"])
        assert claims["video"]["room"] == lk["room"]
        rooms.append(lk["room"])
    assert len(set(rooms)) == 3
    assert [room for room, _seed in seeds] == rooms
    assert all(r.startswith(CONFIG.livekit_room_prefix + "test-uid-123-") for r in rooms)


def test_bootstrap_reports_the_configured_voice_provider(monkeypatch):
    _livekit_env(monkeypatch)
    real_get = main.feature_flags.get
    monkeypatch.setattr(
        main.feature_flags, "get",
        lambda name: "inference" if name == "voice_provider" else real_get(name),
    )
    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    assert resp.json()["livekit"]["voice_provider"] == "inference"


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


def test_bootstrap_level2_seeds_a_dieted_voice_context(monkeypatch):
    """Cost-program Phase 2: at CONTEXT_OPT_LEVEL>=2 the voice session is
    seeded with core wiki card + rolling summary + only the last ~10 turns —
    while the room metadata's `recent_turns` (the raw_turns persistence base)
    still carries the FULL window."""
    import json

    import context_opt
    import main

    monkeypatch.setenv("CONTEXT_OPT_LEVEL", "2")
    seeds = _livekit_env(monkeypatch)
    wiki_calls = []

    def _wiki(_db, _uid, *a, **k):
        wiki_calls.append(k)
        return "CORE CARD: a doctor from Kochi."

    monkeypatch.setattr(main, "read_wiki_context", _wiki)
    monkeypatch.setattr(
        context_opt, "stored_summary_text",
        lambda _db, _uid: "SUMMARY: sister Meera lives in Kochi.",
    )
    turns = [
        {"role": "user" if i % 2 == 0 else "ayma", "text": f"voice turn {i}"}
        for i in range(40)
    ]
    resp = client.post(
        "/bootstrap",
        headers=_valid_auth(monkeypatch),
        json={"session_id": "s-diet", "recent_turns": turns},
    )
    assert resp.status_code == 200
    seed = json.loads(seeds[0][1])
    prompt = seed["system_prompt"]
    assert "voice turn 39" in prompt  # the raw tail
    assert "voice turn 0" not in prompt  # deep history left out of the prompt
    assert "Meera" in prompt  # ...carried by the summary instead
    assert "CORE CARD" in prompt
    # the persistence window is NOT dieted
    assert len(seed["recent_turns"]) == 40
    # the wiki read was the core-card shape
    assert wiki_calls[0]["max_chars"] == context_opt.core_wiki_chars()
    assert wiki_calls[0]["include_page_types"] == context_opt.CORE_PAGE_TYPES


def test_bootstrap_level0_seeds_the_full_context_unchanged(monkeypatch):
    import json

    import main

    monkeypatch.delenv("CONTEXT_OPT_LEVEL", raising=False)
    seeds = _livekit_env(monkeypatch)
    wiki_calls = []

    def _wiki(_db, _uid, *a, **k):
        wiki_calls.append((a, k))
        return "FULL WIKI BLOCK"

    monkeypatch.setattr(main, "read_wiki_context", _wiki)
    turns = [
        {"role": "user" if i % 2 == 0 else "ayma", "text": f"voice turn {i}"}
        for i in range(40)
    ]
    resp = client.post(
        "/bootstrap",
        headers=_valid_auth(monkeypatch),
        json={"session_id": "s-full", "recent_turns": turns},
    )
    assert resp.status_code == 200
    seed = json.loads(seeds[0][1])
    assert "voice turn 0" in seed["system_prompt"]
    assert "voice turn 39" in seed["system_prompt"]
    assert "FULL WIKI BLOCK" in seed["system_prompt"]
    assert len(seed["recent_turns"]) == 40
    # Level 0 keeps the full-wiki shape (no diet kwargs); the only filter on
    # any level is the `assessment` judgment page, which never rides in the
    # standing context (ai_assessment.py).
    import ai_assessment

    assert wiki_calls == [
        ((), {"exclude_page_types": ai_assessment.EXCLUDED_FROM_CHAT_CONTEXT})
    ]


def test_bootstrap_without_a_session_id_never_touches_the_voice_room(monkeypatch):
    """`splash_screen.dart` calls `/bootstrap` with `session_id=''` purely to
    read `session_mode` for routing — it never connects to voice at all. This
    must not create/seed a voice room or wake the scale-to-zero agent: either
    would start an agent job (auto-dispatch on room creation) for a room
    nobody joins, seeded with this call's empty context (root-caused against
    the founder's "Ayma keeps re-asking already-covered ground" report,
    2026-09-25, when room names were still one-per-user). The response must still carry a usable LiveKit
    token, unchanged, since `splash_screen.dart`'s own response parsing
    requires the `livekit` key to be present."""
    seeds = _livekit_env(monkeypatch)
    woken = []
    monkeypatch.setattr(main.agent_wake, "wake_agent", lambda: woken.append(1))

    resp = client.post("/bootstrap", headers=_valid_auth(monkeypatch))
    assert resp.status_code == 200
    body = resp.json()
    assert body["livekit"]["token"]
    assert body["livekit"]["room"].startswith("ayma-test-uid-123-")
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


def test_bootstrap_wakes_cloud_run_only_for_cloudrun_users(monkeypatch):
    """ayma-agent (Cloud Run) runs min-instances=0 (docs/deploy.md §12.2), but
    the DEFAULT voice routing is now "livekit" — served by the
    LiveKit-Cloud-hosted worker, which LiveKit keeps warm itself. So a real
    voice-start /bootstrap (a non-empty session_id — see `newSessionId()`) for a
    livekit-routed user must NOT fire the Cloud Run wake ping: that would
    cold-start a 2 GB instance only for it to decline the room (request_fnc
    guard) — pure wasted spend. Only a user explicitly on "cloudrun" wakes it.
    (The routing-only, empty-session_id call `splash_screen.dart` makes never
    touches the voice room at all — see
    `test_bootstrap_without_a_session_id_never_touches_the_voice_room`.)"""
    _livekit_env(monkeypatch)
    woken = []
    monkeypatch.setattr(main.agent_wake, "wake_agent", lambda: woken.append(1))

    # Default routing ("livekit") → no Cloud Run wake.
    monkeypatch.setattr(main, "_voice_agent_cloud", lambda _uid: "livekit")
    resp = client.post(
        "/bootstrap",
        headers=_valid_auth(monkeypatch),
        json={"session_id": "s-real-voice-session"},
    )
    assert resp.status_code == 200
    # TestClient drains background tasks after the response.
    assert woken == []

    # Explicit "cloudrun" routing → wake the Cloud Run worker.
    monkeypatch.setattr(main, "_voice_agent_cloud", lambda _uid: "cloudrun")
    resp = client.post(
        "/bootstrap",
        headers=_valid_auth(monkeypatch),
        json={"session_id": "s-real-voice-session-2"},
    )
    assert resp.status_code == 200
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
    assert body["livekit"]["room"].startswith(f"{CONFIG.livekit_room_prefix}welcome-")

    room, seed_json = seeds[-1]
    assert room.startswith(f"{CONFIG.livekit_room_prefix}welcome-")
    assert "greeting_instructions" in seed_json
    assert "sign in" in seed_json


def test_welcome_token_no_longer_wakes_the_scale_to_zero_agent(monkeypatch):
    # The welcome room routes to the hosted LiveKit worker now (§1.1; founder
    # directive 2026-11-03 — everything on LiveKit Cloud, GCP only if LiveKit
    # crashes). The Cloud Run wake fires only inside the failure-only fallback
    # watcher (livekit_token.watch_hosted_dispatch), never at welcome-seed time.
    _livekit_env(monkeypatch)
    main._welcome_hits.clear()
    woken = []
    monkeypatch.setattr(main.agent_wake, "wake_agent", lambda: woken.append(1))

    resp = client.post("/welcome/token")
    assert resp.status_code == 200
    assert woken == []


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
