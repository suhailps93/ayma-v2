import main
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth

client = TestClient(main.app)


def _auth(monkeypatch, uid="me"):
    monkeypatch.setattr(
        firebase_auth, "verify_id_token", lambda _t: {"uid": uid}
    )
    return {"Authorization": "Bearer valid"}


def test_usage_requires_auth():
    assert client.get("/usage").status_code in (401, 403)


def test_usage_returns_total_cap_remaining_and_breakdown(monkeypatch):
    monkeypatch.setattr(
        main.token_ledger, "usage",
        lambda uid: {
            "total": 42000,
            "cap": 100000,
            "remaining": 58000,
            "features": {"chat": 30000, "voice": 9000, "matching": 3000},
        },
    )
    resp = client.get("/usage", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 42000 and body["cap"] == 100000
    assert body["remaining"] == 58000
    assert body["features"]["voice"] == 9000


def test_usage_passes_through_credits_and_costs(monkeypatch):
    monkeypatch.setattr(
        main.token_ledger, "usage",
        lambda uid: {
            "total": 42000,
            "cap": 100000,
            "remaining": 58000,
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


def test_credits_topup_bumps_the_balance_and_returns_fresh_usage(monkeypatch):
    calls = {}
    monkeypatch.setattr(
        main.token_ledger, "topup",
        lambda uid, amount: calls.update(uid=uid, amount=amount),
    )
    monkeypatch.setattr(
        main.token_ledger, "usage",
        lambda uid: {
            "total": 0, "cap": 100000, "remaining": 100000, "features": {},
            "credits": {"grant": 100, "added": 100, "used": 0,
                        "remaining": 200},
            "tokens_per_credit": 1000, "costs": {"match_score": 12},
        },
    )
    resp = client.post("/credits/topup", headers=_auth(monkeypatch, uid="u1"))
    assert resp.status_code == 200
    assert calls == {"uid": "u1", "amount": main.CONFIG.credit_topup_amount}
    assert resp.json()["credits"]["remaining"] == 200
