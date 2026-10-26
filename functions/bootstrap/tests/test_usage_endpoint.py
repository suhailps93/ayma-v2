import dataclasses

import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me", admin=False):
    """``admin=True`` signs in as the allowlisted dev (verified founder email)."""
    claims = {"uid": uid}
    if admin:
        claims.update(email="suhailps@gmail.com", email_verified=True)
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: claims)
    return {"Authorization": "Bearer valid"}


def test_usage_requires_auth():
    assert client.get("/usage").status_code in (401, 403)


def test_usage_returns_total_and_breakdown(monkeypatch):
    monkeypatch.setattr(
        main.token_ledger, "usage",
        lambda uid, **kw: {
            "total": 42000,
            "features": {"chat": 30000, "voice": 9000, "matching": 3000},
        },
    )
    resp = client.get("/usage", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 42000
    assert body["features"]["voice"] == 9000
    # The legacy top-level cap/remaining pair (derived from the old lifetime
    # CONFIG.token_cap_per_user, never top-up-aware) is gone — the credit
    # balance is the one source of truth, at ``credits.remaining``.
    assert "cap" not in body and "remaining" not in body


def test_usage_passes_through_credits_and_costs(monkeypatch):
    monkeypatch.setattr(
        main.token_ledger, "usage",
        lambda uid, **kw: {
            "total": 42000,
            "features": {"chat": 42000},
            "credits": {"grant": 100, "added": 0, "used": 42, "remaining": 58},
            "tokens_per_credit": 1000,
            "costs": {"match_score": 12},
        },
    )
    body = client.get("/usage", headers=_auth(monkeypatch, uid="u1")).json()
    assert body["credits"]["remaining"] == 58
    assert body["credits"]["added"] == 0
    assert body["costs"]["match_score"] == 12
    assert body["tokens_per_credit"] == 1000


def test_usage_carries_the_real_money_view(monkeypatch):
    """The Credits screen's "Real money" tab rides the same GET /usage
    payload: the start-from-zero dollar total plus the recent
    per-conversation spend groups (see token_ledger.spend_groups)."""
    monkeypatch.setattr(
        main.token_ledger, "usage",
        lambda uid, **kw: {
            "total": 1000,
            "features": {"chat": 1000},
            "credits": {"grant": 100, "added": 0, "used": 1, "remaining": 99},
            "tokens_per_credit": 1000,
            "costs": {"match_score": 12},
            "cost_usd": 3.4,
            "real_money_usd": 0.0154,
            "spend_groups": [
                {
                    "id": "room-1", "kind": "voice", "session_id": "room-1",
                    "day": "2026-09-26", "first_ts": "2026-09-26T10:00:00+00:00",
                    "last_ts": "2026-09-26T10:06:00+00:00", "events": 6,
                    "cost_usd": 0.0121,
                    "features": {"voice": 0.0121},
                },
            ],
        },
    )
    body = client.get("/usage", headers=_auth(monkeypatch, uid="u1", admin=True)).json()
    assert body["real_money_usd"] == 0.0154
    assert body["spend_groups"][0]["kind"] == "voice"
    assert body["spend_groups"][0]["features"]["voice"] == 0.0121


def test_usage_carries_the_all_time_and_since_reset_split(monkeypatch):
    """The Reset button's view rides GET /usage: all-time keeps counting,
    since-reset restarts at the marker, and the legacy real_money_usd key
    mirrors since-reset for clients that predate the split."""
    monkeypatch.setattr(
        main.token_ledger, "usage",
        lambda uid, **kw: {
            "total": 1000,
            "features": {"chat": 1000},
            "credits": {"grant": 100, "added": 0, "used": 1, "remaining": 99},
            "tokens_per_credit": 1000,
            "costs": {"match_score": 12},
            "cost_usd": 3.4,
            "real_money_usd": 0.002,
            "real_money_all_time_usd": 1.08,
            "real_money_since_reset_usd": 0.002,
            "real_money_reset_at": "2026-09-26T10:00:00+00:00",
            "spend_groups": [],
        },
    )
    body = client.get(
        "/usage", headers=_auth(monkeypatch, uid="u1", admin=True)
    ).json()
    assert body["real_money_all_time_usd"] == 1.08
    assert body["real_money_since_reset_usd"] == 0.002
    assert body["real_money_usd"] == 0.002  # legacy = since-reset
    assert body["real_money_reset_at"] == "2026-09-26T10:00:00+00:00"


def test_reset_real_money_requires_auth():
    assert client.post("/usage/reset-real-money").status_code in (401, 403)


def test_reset_real_money_rejects_non_admin(monkeypatch):
    resp = client.post(
        "/usage/reset-real-money", headers=_auth(monkeypatch, uid="u1")
    )
    assert resp.status_code == 403


def test_reset_real_money_resets_and_returns_the_fresh_view(monkeypatch):
    calls = {}

    def _reset(uid):
        calls["uid"] = uid
        return {
            "total": 1000,
            "features": {"chat": 1000},
            "credits": {"grant": 100, "added": 0, "used": 1, "remaining": 99},
            "tokens_per_credit": 1000,
            "costs": {"match_score": 12},
            "cost_usd": 3.4,
            "real_money_usd": 0.0,
            "real_money_all_time_usd": 1.08,
            "real_money_since_reset_usd": 0.0,
            "real_money_reset_at": "2026-09-26T11:00:00+00:00",
            "spend_groups": [],
        }

    monkeypatch.setattr(main.token_ledger, "reset_real_money", _reset)
    resp = client.post(
        "/usage/reset-real-money",
        headers=_auth(monkeypatch, uid="u1", admin=True),
    )
    assert resp.status_code == 200
    assert calls == {"uid": "u1"}
    body = resp.json()
    assert body["real_money_since_reset_usd"] == 0.0
    assert body["real_money_all_time_usd"] == 1.08
    assert body["real_money_reset_at"] == "2026-09-26T11:00:00+00:00"


def test_unverified_founder_email_is_not_dev(monkeypatch):
    seen = []
    monkeypatch.setattr(
        main.token_ledger, "usage",
        lambda uid, include_dollars=False: seen.append(include_dollars) or {},
    )
    monkeypatch.setattr(
        firebase_auth, "verify_id_token",
        lambda _t: {"uid": "x", "email": "suhailps@gmail.com",
                    "email_verified": False},
    )
    body = client.get("/usage", headers={"Authorization": "Bearer v"}).json()
    assert seen == [False] and body["is_dev"] is False


def test_dev_allowlist_by_uid(monkeypatch):
    import auth

    monkeypatch.setattr(
        auth, "CONFIG",
        dataclasses.replace(auth.CONFIG, dev_view_uids=("dev-uid",)),
    )
    monkeypatch.setattr(main.token_ledger, "usage", lambda uid, **kw: {})
    assert client.get(
        "/usage", headers=_auth(monkeypatch, uid="dev-uid")
    ).json()["is_dev"] is True


def test_usage_reports_is_dev(monkeypatch):
    monkeypatch.setattr(main.token_ledger, "usage", lambda uid, **kw: {})
    r1 = client.get("/usage", headers=_auth(monkeypatch, uid="u1")).json()
    r2 = client.get(
        "/usage", headers=_auth(monkeypatch, uid="u1", admin=True)
    ).json()
    assert (r1["is_dev"], r2["is_dev"]) == (False, True)


def test_credits_topup_works_for_the_dev_even_with_the_flag_off(monkeypatch):
    assert main.CONFIG.credit_free_topup_enabled is False
    calls = []
    monkeypatch.setattr(
        main.token_ledger, "topup", lambda uid, amount: calls.append(uid)
    )

    async def _drain(db, uid, **kw):
        pass

    monkeypatch.setattr(main.backfill_ops, "drain", _drain)
    monkeypatch.setattr(main.token_ledger, "usage", lambda uid, **kw: {})
    resp = client.post(
        "/credits/topup", headers=_auth(monkeypatch, uid="u1", admin=True)
    )
    assert resp.status_code == 200 and calls == ["u1"]


def test_usage_hides_dollars_from_regular_users_and_shows_admins(monkeypatch):
    seen = []

    def _usage(uid, include_dollars=False):
        seen.append(include_dollars)
        return {"total": 1, "credits": {"remaining": 5}}

    monkeypatch.setattr(main.token_ledger, "usage", _usage)
    client.get("/usage", headers=_auth(monkeypatch, uid="u1"))
    client.get("/usage", headers=_auth(monkeypatch, uid="u1", admin=True))
    assert seen == [False, True]


def test_credits_topup_is_disabled_by_default_and_asks_to_upgrade(monkeypatch):
    assert main.CONFIG.credit_free_topup_enabled is False
    called = []
    monkeypatch.setattr(
        main.token_ledger, "topup", lambda *a: called.append(a)
    )
    resp = client.post("/credits/topup", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 402
    detail = resp.json()["detail"]
    assert detail["error"] == "upgrade_required"
    assert detail["message"] == main.token_ledger.UPGRADE_MESSAGE
    assert "$" not in detail["message"]
    assert called == []


def test_credits_topup_bumps_the_balance_and_returns_fresh_usage(monkeypatch):
    monkeypatch.setattr(
        main, "CONFIG",
        dataclasses.replace(main.CONFIG, credit_free_topup_enabled=True),
    )
    calls = {}
    monkeypatch.setattr(
        main.token_ledger, "topup",
        lambda uid, amount: calls.update(uid=uid, amount=amount),
    )
    drained = {}

    async def _drain(db, uid, **kw):
        drained["uid"] = uid

    monkeypatch.setattr(main.backfill_ops, "drain", _drain)
    monkeypatch.setattr(
        main.token_ledger, "usage",
        lambda uid, **kw: {
            "total": 0, "features": {},
            "credits": {"grant": 100, "added": 100, "used": 0,
                        "remaining": 200},
            "tokens_per_credit": 1000, "costs": {"match_score": 12},
        },
    )
    resp = client.post("/credits/topup", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 200
    assert calls == {"uid": "u1", "amount": main.CONFIG.credit_topup_amount}
    assert resp.json()["credits"]["remaining"] == 200
    assert drained == {"uid": "u1"}  # backfill kicked off


def test_usage_period_param_is_forwarded_and_validated(monkeypatch):
    seen = {}

    def _usage(uid, **kw):
        seen.update(kw)
        return {"total": 0, "features": {}}

    monkeypatch.setattr(main.token_ledger, "usage", _usage)
    headers = _auth(monkeypatch, uid="u1")
    assert client.get("/usage?period=30d", headers=headers).status_code == 200
    assert seen["period"] == "30d"
    assert client.get("/usage?period=bogus", headers=headers).status_code == 400
