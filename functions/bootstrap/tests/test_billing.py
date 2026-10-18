"""Free plan grant/daily allowance, paid tiers, expiry fallback and the
RevenueCat webhook (billing.py + token_ledger credit view)."""

import copy
import dataclasses
from datetime import datetime, timedelta, timezone

import billing
import main
import pytest
import token_ledger
from config import CONFIG, PLAN_TIERS
from fastapi.testclient import TestClient
from google.api_core.exceptions import AlreadyExists

T0 = datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc)
SECRET = "s3cret"


class _Snap:
    def __init__(self, data):
        self.exists = data is not None
        self._d = data

    def to_dict(self):
        return copy.deepcopy(self._d) if self._d is not None else None


def _merge(dst, src):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            _merge(dst[k], v)
        else:
            dst[k] = copy.deepcopy(v)


class _Doc:
    def __init__(self, db, key):
        self._db, self._key = db, key

    def get(self):
        return _Snap(self._db.docs.get(self._key))

    def set(self, payload, merge=False):
        if merge and self._key in self._db.docs:
            _merge(self._db.docs[self._key], payload)
        else:
            self._db.docs[self._key] = copy.deepcopy(payload)

    def create(self, data):
        if self._key in self._db.docs:
            raise AlreadyExists("exists")
        self._db.docs[self._key] = copy.deepcopy(data)

    def delete(self):
        self._db.docs.pop(self._key, None)


class _Col:
    def __init__(self, db, name):
        self._db, self._name = db, name

    def document(self, doc_id):
        return _Doc(self._db, (self._name, doc_id))


class _Db:
    def __init__(self):
        self.docs = {}

    def collection(self, name):
        return _Col(self, name)

    def user(self, uid="u1"):
        return self.docs[("users", uid)]


class _Clock(datetime):
    now_value = T0

    @classmethod
    def now(cls, tz=None):
        return cls.now_value


@pytest.fixture
def db(monkeypatch):
    d = _Db()
    d.docs[("users", "u1")] = {"token_usage": {"total": 0, "cost_usd": 0.0}}
    monkeypatch.setattr(token_ledger, "get_db", lambda: d)
    monkeypatch.setattr(token_ledger, "datetime", _Clock)
    _Clock.now_value = T0
    token_ledger.credits("u1")  # first read initialises billing (as /usage would)
    return d


def _spend(db, usd, uid="u1"):
    db.user(uid)["token_usage"]["cost_usd"] += usd


def _set_day(offset_days=0, extra=timedelta(0)):
    _Clock.now_value = T0 + timedelta(days=offset_days) + extra


def _event(etype, product="ayma_plus_monthly", eid="e1", uid="u1",
           expires=None, **kw):
    expires = expires or (T0 + timedelta(days=30))
    ev = {
        "id": eid, "type": etype, "app_user_id": uid, "product_id": product,
        "expiration_at_ms": int(expires.timestamp() * 1000),
    }
    ev.update(kw)
    return {"api_version": "1.0", "event": ev}


def _handle(db, payload, now=T0):
    return billing.handle_event(db, payload, CONFIG, now)


# --- free plan ---------------------------------------------------------------

def test_new_account_gets_500_credit_start_grant_and_daily_allowance(db):
    c = token_ledger.credits("u1")
    assert c["remaining"] == 500
    assert c["plan"] == "free"
    assert c["daily_credits_remaining"] == 25
    assert c["grant"] == 500 and c["used"] == 0
    assert c["period_end"] is None
    token_ledger.check("u1")


def test_start_grant_is_one_time_then_daily_allowance_applies(db):
    _spend(db, 5.0)  # start grant exhausted
    token_ledger.check("u1")  # today's 25 credits still usable
    assert token_ledger.credits("u1")["remaining"] == 25
    _spend(db, 0.25)
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")
    assert token_ledger.credits("u1")["remaining"] == 0


def test_daily_reset_uncaps_the_user(db):
    _spend(db, 5.25)
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")
    _set_day(1)
    token_ledger.check("u1")
    assert token_ledger.credits("u1")["remaining"] == 25


def test_daily_allowance_does_not_roll_over(db):
    _spend(db, 5.0)
    token_ledger.check("u1")  # day 0: marker stored
    _spend(db, 0.10)
    _set_day(1)
    assert token_ledger.credits("u1")["remaining"] == 25
    _set_day(2)  # a whole untouched day banks nothing
    assert token_ledger.credits("u1")["remaining"] == 25
    _set_day(3)
    token_ledger.check("u1")  # first call of the day stamps the day marker
    _spend(db, 0.05)
    assert token_ledger.credits("u1")["remaining"] == 20


def test_grandfathered_account_keeps_its_balance_and_gets_the_grant(db):
    db.docs[("users", "old")] = {
        "token_usage": {"total": 40_000, "cost_usd": 1.2},
        "credits_added": 100,
    }
    # legacy: 100 + 100 - ceil(40000/1000) = 160 credits kept at face value
    # on top of the $5 grant; the $1.20 already spent is forgiven.
    b, _ = billing.normalize(db.user("old"), T0, CONFIG)
    assert b["legacy_bonus_usd"] == pytest.approx(1.60)
    assert b["init_cost_usd"] == pytest.approx(1.2)
    assert token_ledger.credits("old")["plan"] == "free"
    # 5.00 grant + 1.60 legacy + 1.00 top-up bonus (credits_added) = 760
    assert token_ledger.credits("old")["remaining"] == 760


def test_grandfathering_persists_and_never_wipes(db):
    _spend(db, 0.4)
    before = token_ledger.credits("u1")["remaining"]
    assert db.user()["billing"]["initialized"] is True
    assert token_ledger.credits("u1")["remaining"] == before


def test_credit_override_is_honoured_in_grandfathering(db):
    db.docs[("users", "vip")] = {
        "token_usage": {"total": 10_000, "cost_usd": 0.1}, "credit_grant": 500,
    }
    b, _ = billing.normalize(db.user("vip"), T0, CONFIG)
    assert b["legacy_bonus_usd"] == pytest.approx(4.90)


def test_topup_gives_at_least_amount_credits(db):
    _spend(db, 5.25)
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")
    assert token_ledger.topup("u1", 100)["remaining"] >= 100
    token_ledger.check("u1")


# --- paid tiers --------------------------------------------------------------

@pytest.mark.parametrize("product,credits", [
    ("ayma_plus_monthly", 700),
    ("ayma_pro_monthly", 1400),
    ("ayma_max_monthly", 8000),
])
def test_tier_grants_pool_and_no_daily_limit(db, product, credits):
    assert _handle(db, _event("INITIAL_PURCHASE", product)) .startswith("granted_")
    c = token_ledger.credits("u1")
    assert c["remaining"] == credits and c["plan_credits"] == credits
    assert c["daily_credits_remaining"] == 0
    assert c["period_end"] is not None
    # the free start grant is irrelevant while paid: spend past the daily
    # allowance, still fine until the monthly pool is gone
    _spend(db, 0.30)
    token_ledger.check("u1")
    _spend(db, PLAN_TIERS[billing.PRODUCT_TO_PLAN[product]].pool_usd)
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")


def test_tier_constants():
    assert {k: (t.product_id, t.price_usd, t.pool_usd) for k, t in PLAN_TIERS.items()} == {
        "plus": ("ayma_plus_monthly", 10, 7.0),
        "pro": ("ayma_pro_monthly", 20, 14.0),
        "max": ("ayma_max_monthly", 100, 80.0),
    }


def test_renewal_resets_pool_without_rollover(db):
    _handle(db, _event("INITIAL_PURCHASE", eid="e1"))
    _spend(db, 2.0)
    assert token_ledger.credits("u1")["remaining"] == 500
    _handle(db, _event("RENEWAL", eid="e2", expires=T0 + timedelta(days=60)))
    assert token_ledger.credits("u1")["remaining"] == 700  # not 1200


def test_unused_paid_tokens_expire_to_free_plan_lazily(db):
    _spend(db, 5.0)  # free grant already gone before subscribing
    _handle(db, _event("INITIAL_PURCHASE"))
    _spend(db, 1.0)
    _set_day(31, timedelta(hours=2))  # past period_end + grace, no webhook
    c = token_ledger.credits("u1")
    assert c["plan"] == "free"
    assert c["remaining"] == 25  # daily allowance only; $5 not re-granted
    assert c["period_end"] is None
    _spend(db, 0.25)
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")


def test_spend_before_lazy_settlement_is_not_charged_to_free_pool(db):
    _handle(db, _event("INITIAL_PURCHASE"))
    _spend(db, 3.0)
    _set_day(31, timedelta(hours=2))
    # free pool untouched by the $3 paid spend: the full start grant remains
    assert token_ledger.credits("u1")["remaining"] == 500


def test_within_grace_after_period_end_stays_paid(db):
    _handle(db, _event("INITIAL_PURCHASE"))
    _set_day(30, timedelta(minutes=30))
    assert token_ledger.credits("u1")["plan"] == "plus"


def test_expiration_event_falls_back_to_free(db):
    _spend(db, 5.0)
    _handle(db, _event("INITIAL_PURCHASE", eid="a"))
    _spend(db, 0.5)
    exp = T0 + timedelta(days=30)
    assert _handle(db, _event("EXPIRATION", eid="b", expires=exp), now=exp) == "expired_to_free"
    c = token_ledger.credits("u1")
    assert c["plan"] == "free" and c["remaining"] == 25


def test_cancellation_does_not_revoke_until_period_end(db):
    _handle(db, _event("INITIAL_PURCHASE", eid="a"))
    assert _handle(db, _event("CANCELLATION", eid="b")) == "cancel_noted"
    c = token_ledger.credits("u1")
    assert c["plan"] == "plus" and c["remaining"] == 700
    assert db.user()["billing"]["cancel_at_period_end"] is True
    _set_day(31, timedelta(hours=2))
    assert token_ledger.credits("u1")["plan"] == "free"


def test_billing_issue_keeps_access(db):
    _handle(db, _event("INITIAL_PURCHASE", eid="a"))
    assert _handle(db, _event("BILLING_ISSUE", eid="b")) == "billing_issue_noted"
    assert token_ledger.credits("u1")["plan"] == "plus"
    assert db.user()["billing"]["billing_issue"] is True


def test_product_change_upgrade_applies_now_downgrade_at_renewal(db):
    _handle(db, _event("INITIAL_PURCHASE", eid="a"))
    _handle(db, _event("PRODUCT_CHANGE", eid="b", product="ayma_plus_monthly",
                       new_product_id="ayma_max_monthly"))
    assert token_ledger.credits("u1")["remaining"] == 8000
    assert _handle(db, _event("PRODUCT_CHANGE", eid="c", product="ayma_max_monthly",
                              new_product_id="ayma_plus_monthly")) == "downgrade_deferred"
    assert token_ledger.credits("u1")["plan"] == "max"
    _handle(db, _event("RENEWAL", eid="d", product="ayma_plus_monthly",
                       expires=T0 + timedelta(days=60)))
    assert token_ledger.credits("u1")["plan"] == "plus"


def test_play_store_product_suffix_is_understood(db):
    _handle(db, _event("INITIAL_PURCHASE", product="ayma_pro_monthly:base"))
    assert token_ledger.credits("u1")["plan"] == "pro"


# --- webhook idempotency / edge cases ----------------------------------------

def test_event_id_is_idempotent(db):
    assert _handle(db, _event("INITIAL_PURCHASE", eid="same")) == "granted_plus"
    _spend(db, 1.0)
    # a replay must not reset the pool
    assert _handle(db, _event("INITIAL_PURCHASE", eid="same")) == "duplicate"
    assert token_ledger.credits("u1")["remaining"] == 600


def test_failed_apply_clears_marker_so_redelivery_is_processed(db, monkeypatch):
    real = billing._apply
    calls = {"n": 0}

    def flaky(*a, **kw):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("boom")
        return real(*a, **kw)

    monkeypatch.setattr(billing, "_apply", flaky)
    with pytest.raises(RuntimeError):
        _handle(db, _event("INITIAL_PURCHASE", eid="r"))
    assert _handle(db, _event("INITIAL_PURCHASE", eid="r")) == "granted_plus"


def test_stale_renewal_and_stale_expiration_are_ignored(db):
    _handle(db, _event("INITIAL_PURCHASE", eid="a", expires=T0 + timedelta(days=60)))
    assert _handle(db, _event("RENEWAL", eid="b", expires=T0 + timedelta(days=30))) == "ignored_stale"
    assert _handle(db, _event("EXPIRATION", eid="c", expires=T0 + timedelta(days=30))) == "ignored_stale"
    assert token_ledger.credits("u1")["plan"] == "plus"


def test_unknown_user_raises_and_anonymous_is_ignored(db):
    with pytest.raises(billing.UnknownUser):
        _handle(db, _event("INITIAL_PURCHASE", uid="ghost", eid="g"))
    assert ("billing_events", "g") not in db.docs
    assert _handle(db, _event("INITIAL_PURCHASE", uid="$RCAnonymousID:abc", eid="x")) == "ignored_anonymous"


def test_unknown_product_and_unhandled_type_do_nothing(db):
    assert _handle(db, _event("INITIAL_PURCHASE", product="nope", eid="a")) == "ignored_unknown_product"
    assert _handle(db, _event("TEST", eid="b")) == "ignored_type"
    assert token_ledger.credits("u1")["plan"] == "free"


# --- webhook auth ------------------------------------------------------------

@pytest.fixture
def client(db, monkeypatch):
    import auth

    cfg = dataclasses.replace(CONFIG, revenuecat_webhook_secret=SECRET)
    monkeypatch.setattr(auth, "CONFIG", cfg)
    monkeypatch.setattr(main, "CONFIG", cfg)
    monkeypatch.setattr(main, "get_db", lambda: db)
    return TestClient(main.app)


def test_webhook_rejects_missing_or_wrong_secret(client, db):
    body = _event("INITIAL_PURCHASE")
    assert client.post("/webhooks/revenuecat", json=body).status_code == 403
    r = client.post("/webhooks/revenuecat", json=body, headers={"Authorization": "nope"})
    assert r.status_code == 403
    assert token_ledger.credits("u1")["plan"] == "free"


def test_webhook_accepts_raw_and_bearer_secret(client, db):
    r = client.post("/webhooks/revenuecat", json=_event("INITIAL_PURCHASE", eid="a"),
                    headers={"Authorization": SECRET})
    assert r.status_code == 200 and r.json() == {"status": "granted_plus"}
    r = client.post("/webhooks/revenuecat", json=_event("INITIAL_PURCHASE", eid="a"),
                    headers={"Authorization": f"Bearer {SECRET}"})
    assert r.json() == {"status": "duplicate"}


def test_webhook_fails_closed_when_secret_not_provisioned(db, monkeypatch):
    import auth

    cfg = dataclasses.replace(CONFIG, revenuecat_webhook_secret="")
    monkeypatch.setattr(auth, "CONFIG", cfg)
    c = TestClient(main.app)
    r = c.post("/webhooks/revenuecat", json=_event("INITIAL_PURCHASE"),
               headers={"Authorization": ""})
    assert r.status_code == 403
    r = c.post("/webhooks/revenuecat", json=_event("INITIAL_PURCHASE"))
    assert r.status_code == 403


def test_webhook_unknown_user_is_404_so_revenuecat_retries(client):
    r = client.post("/webhooks/revenuecat",
                    json=_event("INITIAL_PURCHASE", uid="ghost", eid="g"),
                    headers={"Authorization": SECRET})
    assert r.status_code == 404


def test_webhook_rejects_non_object_body(client):
    r = client.post("/webhooks/revenuecat", json=[1],
                    headers={"Authorization": SECRET})
    assert r.status_code == 400


# --- credits only, never dollars ----------------------------------------------

def _keys(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield k
            yield from _keys(v)


def test_client_credit_payload_has_no_usd_token_values(db, monkeypatch):
    monkeypatch.setattr(token_ledger, "spend_groups", lambda uid: [])
    _handle(db, _event("INITIAL_PURCHASE"))
    for payload in (token_ledger.credits("u1"),
                    {k: token_ledger.usage("u1")[k]
                     for k in ("credits", "plan", "daily_credits_remaining", "period_end")}):
        bad = [k for k in _keys(payload) if "usd" in k.lower() or "dollar" in k.lower()]
        assert bad == []
        assert "$" not in repr(payload)


def test_out_of_credits_copy_has_no_dollars():
    for ctx in token_ledger._CONTEXT_ACTIONS:
        assert "$" not in token_ledger.out_of_credits_message(ctx)
