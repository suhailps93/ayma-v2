"""Free plan grant/daily allowance, paid tiers, expiry fallback and the
RevenueCat webhook (billing.py + token_ledger credit view)."""

import copy
import dataclasses
from datetime import datetime, timedelta, timezone

import billing
import main
import pytest
import start_grant
import token_ledger
from config import CONFIG, PLAN_TIERS
from fastapi.testclient import TestClient
from firebase_admin import auth as firebase_auth
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
    assert c["daily_credits_remaining"] == 100
    assert c["grant"] == 500 and c["used"] == 0
    assert c["period_end"] is None
    token_ledger.check("u1")


def test_start_grant_is_one_time_then_daily_allowance_applies(db):
    _spend(db, 5.0)  # start grant exhausted
    token_ledger.check("u1")  # today's 100 credits still usable
    assert token_ledger.credits("u1")["remaining"] == 100
    _spend(db, 1.0)
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")
    assert token_ledger.credits("u1")["remaining"] == 0


def test_daily_reset_uncaps_the_user(db):
    _spend(db, 6.0)  # $5 start grant + $1 daily allowance both exhausted
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")
    _set_day(1)
    token_ledger.check("u1")
    assert token_ledger.credits("u1")["remaining"] == 100


def test_daily_allowance_does_not_roll_over(db):
    _spend(db, 5.0)
    token_ledger.check("u1")  # day 0: marker stored
    _spend(db, 0.10)
    _set_day(1)
    assert token_ledger.credits("u1")["remaining"] == 100
    _set_day(2)  # a whole untouched day banks nothing
    assert token_ledger.credits("u1")["remaining"] == 100
    _set_day(3)
    token_ledger.check("u1")  # first call of the day stamps the day marker
    _spend(db, 0.05)
    assert token_ledger.credits("u1")["remaining"] == 95


def test_zero_credit_free_user_gets_the_daily_pool_on_a_new_day(db):
    """Founder bug 2026-10-27: a free account at 0 credits must get its full
    daily pool back the next UTC day (the "daily credits refresh every day"
    promise). Exhaust the start grant AND today's allowance, confirm 0, then
    roll the day and confirm the whole pool is back."""
    _spend(db, 6.0)  # $5 start grant + $1 daily allowance
    assert token_ledger.credits("u1")["remaining"] == 0
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")
    _set_day(1)
    assert token_ledger.credits("u1")["remaining"] == 100
    token_ledger.check("u1")  # no longer capped


def test_daily_pool_is_not_regranted_within_the_same_day(db):
    """The allowance must not top itself back up on a second read the same
    day — it is a bounded daily pool, not per-request. Spend part of it, read
    again the same day, and confirm the remainder only shrinks."""
    _spend(db, 5.0)  # start grant gone; full daily pool available
    assert token_ledger.credits("u1")["remaining"] == 100
    _spend(db, 0.40)
    assert token_ledger.credits("u1")["remaining"] == 60
    _spend(db, 0.40)  # same day, no rollover
    assert token_ledger.credits("u1")["remaining"] == 20
    assert token_ledger.credits("u1")["remaining"] == 20  # re-read: still 20


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
    _spend(db, 6.0)  # $5 start grant + $1 daily allowance both exhausted
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
    assert c["remaining"] == 100  # daily allowance only; $5 not re-granted
    assert c["period_end"] is None
    _spend(db, 1.0)
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
    assert c["plan"] == "free" and c["remaining"] == 100


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


def test_test_store_sandbox_event_grants_and_is_idempotent(db):
    ev = _event("INITIAL_PURCHASE", product="ayma_plus_monthly",
                environment="SANDBOX", store="TEST_STORE")
    assert _handle(db, ev) == "granted_plus"
    assert token_ledger.credits("u1")["remaining"] == 700
    assert _handle(db, ev) == "duplicate"
    assert token_ledger.credits("u1")["remaining"] == 700


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


# --- anti-abuse: start grant needs verified contact + selfie, no duplicate ----


def _new_user_db(monkeypatch, status):
    d = _Db()
    d.docs[("users", "n1")] = {"token_usage": {"total": 0, "cost_usd": 0.0}}
    monkeypatch.setattr(token_ledger, "get_db", lambda: d)
    monkeypatch.setattr(
        start_grant, "grant_status", lambda uid, data: status[0]
    )
    return d


def test_ineligible_account_gets_only_the_daily_allowance(monkeypatch):
    d = _new_user_db(monkeypatch, [start_grant.GRANT_PENDING])
    assert token_ledger.credits("n1")["remaining"] == 100
    assert d.docs[("users", "n1")]["billing"]["start_grant_unlocked"] is False


def test_becoming_eligible_later_unlocks_the_start_grant(monkeypatch):
    st = [start_grant.GRANT_PENDING]
    d = _new_user_db(monkeypatch, st)
    assert token_ledger.credits("n1")["remaining"] == 100
    st[0] = start_grant.GRANT_OK
    assert token_ledger.credits("n1")["remaining"] == 500
    assert d.docs[("users", "n1")]["billing"]["start_grant_unlocked"] is True


def test_duplicate_face_is_blocked_permanently_without_rechecks(monkeypatch):
    st = [start_grant.GRANT_DUPLICATE]
    d = _new_user_db(monkeypatch, st)
    assert token_ledger.credits("n1")["remaining"] == 100
    b = d.docs[("users", "n1")]["billing"]
    assert b["start_grant_unlocked"] is False and b["start_grant_blocked"] is True
    monkeypatch.setattr(
        start_grant, "grant_status",
        lambda uid, data: pytest.fail("blocked accounts are not re-checked"),
    )
    assert token_ledger.credits("n1")["remaining"] == 100


def test_unlocked_account_is_not_relocked_and_skips_lookup(monkeypatch):
    _new_user_db(monkeypatch, [start_grant.GRANT_OK])
    assert token_ledger.credits("n1")["remaining"] == 500
    monkeypatch.setattr(
        start_grant, "grant_status",
        lambda uid, data: pytest.fail("no lookup once unlocked"),
    )
    assert token_ledger.credits("n1")["remaining"] == 500


def test_account_initialised_before_the_gate_stays_unlocked(db):
    b = db.user()["billing"]
    del b["start_grant_unlocked"]
    assert token_ledger.credits("u1")["remaining"] == 500


def test_default_usage_view_has_no_dollar_fields_but_dev_view_does(db):
    plain = token_ledger.usage("u1")
    assert not [k for k in plain if "usd" in k or "real_money" in k]
    assert "spend_groups" not in plain
    assert "cost_usd" in token_ledger.usage("u1", include_dollars=True)


def test_free_topup_defaults_off():
    assert CONFIG.credit_free_topup_enabled is False


# --- Pro free trial ----------------------------------------------------------

def test_trial_grants_pro_pool_once_marks_trial_and_exposes_it(db):
    end = T0 + timedelta(days=30)
    ev = _event("INITIAL_PURCHASE", "ayma_pro_monthly", eid="t1",
                expires=end, period_type="TRIAL")
    assert _handle(db, ev) == "granted_pro_trial"
    assert _handle(db, ev) == "duplicate"
    c = token_ledger.credits("u1")
    assert c["plan"] == "pro" and c["remaining"] == CONFIG.pro_trial_credits
    assert CONFIG.pro_trial_credits == 1400
    assert c["is_trial"] is True and c["trial_end"] == end.isoformat()
    assert db.user()["billing"]["trial_used"] is True
    assert token_ledger.usage("u1")["is_trial"] is True


def test_trial_pool_follows_pro_trial_credits_config(db):
    cfg = dataclasses.replace(CONFIG, pro_trial_credits=300)
    ev = _event("INITIAL_PURCHASE", "ayma_pro_monthly", period_type="TRIAL")
    billing.handle_event(db, ev, cfg, T0)
    assert token_ledger.credits("u1")["remaining"] == 300


def test_second_trial_for_same_uid_is_ignored(db):
    _handle(db, _event("INITIAL_PURCHASE", "ayma_pro_monthly", eid="t1",
                       period_type="TRIAL"))
    _handle(db, _event("EXPIRATION", "ayma_pro_monthly", eid="x1"),
            now=T0 + timedelta(days=30))
    again = _event("INITIAL_PURCHASE", "ayma_pro_monthly", eid="t2",
                   expires=T0 + timedelta(days=90), period_type="TRIAL")
    assert _handle(db, again, now=T0 + timedelta(days=60)) == "ignored_trial_repeat"
    _set_day(60)
    assert token_ledger.credits("u1")["plan"] == "free"


def test_trial_conversion_renewal_grants_normal_pro_pool(db):
    _handle(db, _event("INITIAL_PURCHASE", "ayma_pro_monthly", eid="t1",
                       period_type="TRIAL"))
    _spend(db, 3.0)
    _handle(db, _event("RENEWAL", "ayma_pro_monthly", eid="r1",
                       expires=T0 + timedelta(days=60), period_type="NORMAL"))
    c = token_ledger.credits("u1")
    assert c["remaining"] == 1400 and c["is_trial"] is False
    assert c["trial_end"] is None


def test_trial_cancellation_runs_to_period_end_then_free(db):
    _handle(db, _event("INITIAL_PURCHASE", "ayma_pro_monthly", eid="t1",
                       period_type="TRIAL"))
    assert _handle(db, _event("CANCELLATION", "ayma_pro_monthly", eid="c1",
                              period_type="TRIAL")) == "cancel_noted"
    assert token_ledger.credits("u1")["plan"] == "pro"
    _set_day(31, timedelta(hours=2))
    c = token_ledger.credits("u1")
    assert c["plan"] == "free" and c["is_trial"] is False


def test_trial_expiration_event_removes_plan(db):
    end = T0 + timedelta(days=30)
    _handle(db, _event("INITIAL_PURCHASE", "ayma_pro_monthly", eid="t1",
                       expires=end, period_type="TRIAL"))
    assert _handle(db, _event("EXPIRATION", "ayma_pro_monthly", eid="x1",
                              expires=end, period_type="TRIAL"),
                   now=end) == "expired_to_free"
    assert token_ledger.credits("u1")["is_trial"] is False


def test_non_trial_purchase_is_not_flagged_trial(db):
    _handle(db, _event("INITIAL_PURCHASE", "ayma_pro_monthly",
                       period_type="NORMAL"))
    c = token_ledger.credits("u1")
    assert c["is_trial"] is False and c["trial_end"] is None
    assert c["remaining"] == 1400


# --- credits_updated_at: the "since last credit update" period start --------

def test_credit_adding_events_stamp_credits_updated_at(db):
    assert db.user()["billing"]["credits_updated_at"] == T0  # start grant
    _set_day(1)
    token_ledger.credits("u1")  # daily-allowance rollover
    assert db.user()["billing"]["credits_updated_at"] == T0 + timedelta(days=1)
    _handle(db, _event("INITIAL_PURCHASE"), now=T0 + timedelta(days=1, hours=2))
    assert db.user()["billing"]["credits_updated_at"] == (
        T0 + timedelta(days=1, hours=2)
    )
    later = T0 + timedelta(days=5)
    _handle(db, _event("RENEWAL", eid="e2", expires=later + timedelta(days=30)), now=later)
    assert db.user()["billing"]["credits_updated_at"] == later


# --- entitlement sync (POST /billing/sync: sandbox/test + resilience) --------
#
# A RevenueCat Test Store purchase never sends the server webhook, so the pool
# would never be granted; ``sync_entitlement`` grants it from the active
# entitlement instead, idempotently, and is also a production fallback.

def _ent(product="ayma_plus_monthly", days=30, is_trial=False):
    return {
        "product_id": product,
        "expires": T0 + timedelta(days=days),
        "is_trial": is_trial,
    }


@pytest.mark.parametrize("product,credits", [
    ("ayma_plus_monthly", 700),
    ("ayma_pro_monthly", 1400),
    ("ayma_max_monthly", 8000),
])
def test_sync_grants_each_plan_pool(db, product, credits):
    plan = billing.PRODUCT_TO_PLAN[product]
    assert billing.sync_entitlement(db, "u1", _ent(product), CONFIG, T0) == f"synced_{plan}"
    c = token_ledger.credits("u1")
    assert c["remaining"] == credits and c["plan"] == plan
    assert c["daily_credits_remaining"] == 0 and c["period_end"] is not None


def test_sync_is_idempotent_within_a_period(db):
    billing.sync_entitlement(db, "u1", _ent(), CONFIG, T0)
    _spend(db, 2.0)
    assert token_ledger.credits("u1")["remaining"] == 500
    # a re-sync for the same plan+period must not refill the pool
    assert billing.sync_entitlement(
        db, "u1", _ent(), CONFIG, T0 + timedelta(hours=1)
    ) == "already_synced"
    assert token_ledger.credits("u1")["remaining"] == 500


def test_sync_after_webhook_grant_is_idempotent(db):
    _handle(db, _event("INITIAL_PURCHASE", expires=T0 + timedelta(days=30)))
    _spend(db, 1.0)
    assert token_ledger.credits("u1")["remaining"] == 600
    # the webhook already granted this exact period; a sync is a no-op
    assert billing.sync_entitlement(
        db, "u1", _ent(), CONFIG, T0 + timedelta(hours=2)
    ) == "already_synced"
    assert token_ledger.credits("u1")["remaining"] == 600


def test_sync_no_active_entitlement_grants_nothing(db):
    assert billing.sync_entitlement(db, "u1", None, CONFIG, T0) == "no_active"
    c = token_ledger.credits("u1")
    assert c["plan"] == "free" and c["remaining"] == 500


def test_sync_renewal_refreshes_pool_without_rollover(db):
    billing.sync_entitlement(db, "u1", _ent(), CONFIG, T0)
    _spend(db, 2.0)
    later = T0 + timedelta(days=30)
    assert billing.sync_entitlement(db, "u1", _ent(days=60), CONFIG, later) == "synced_plus"
    assert token_ledger.credits("u1")["remaining"] == 700  # not 1200


def test_sync_upgrade_switches_plan_in_place(db):
    billing.sync_entitlement(db, "u1", _ent("ayma_plus_monthly"), CONFIG, T0)
    assert billing.sync_entitlement(
        db, "u1", _ent("ayma_max_monthly"), CONFIG, T0 + timedelta(hours=1)
    ) == "synced_max"
    assert token_ledger.credits("u1")["remaining"] == 8000


def test_sync_stale_older_period_is_ignored(db):
    billing.sync_entitlement(db, "u1", _ent(days=60), CONFIG, T0)
    assert billing.sync_entitlement(
        db, "u1", _ent(days=30), CONFIG, T0 + timedelta(hours=1)
    ) == "ignored_stale"
    assert token_ledger.credits("u1")["plan"] == "plus"


def test_sync_unknown_product_grants_nothing(db):
    bad = {"product_id": "nope", "expires": T0 + timedelta(days=30), "is_trial": False}
    assert billing.sync_entitlement(db, "u1", bad, CONFIG, T0) == "ignored_unknown_product"
    assert token_ledger.credits("u1")["plan"] == "free"


def test_sync_trial_grants_pro_trial_pool_and_marks_trial(db):
    assert billing.sync_entitlement(
        db, "u1", _ent("ayma_pro_monthly", is_trial=True), CONFIG, T0
    ) == "synced_pro_trial"
    c = token_ledger.credits("u1")
    assert c["plan"] == "pro" and c["remaining"] == CONFIG.pro_trial_credits
    assert c["is_trial"] is True
    assert db.user()["billing"]["trial_used"] is True


def test_sync_stamps_credits_updated_at(db):
    at = T0 + timedelta(days=2)
    billing.sync_entitlement(db, "u1", _ent(), CONFIG, at)
    assert db.user()["billing"]["credits_updated_at"] == at


def test_sync_unknown_user_raises(db):
    with pytest.raises(billing.UnknownUser):
        billing.sync_entitlement(db, "ghost", _ent(), CONFIG, T0)


def test_client_entitlement_builds_or_rejects():
    exp = T0 + timedelta(days=30)
    exp_ms = int(exp.timestamp() * 1000)
    e = billing.client_entitlement("ayma_pro_monthly", exp_ms, True)
    assert e["product_id"] == "ayma_pro_monthly" and e["is_trial"] is True
    assert e["expires"].timestamp() == pytest.approx(exp.timestamp())
    assert billing.client_entitlement(None, exp_ms, False) is None
    assert billing.client_entitlement("ayma_pro_monthly", None, False) is None


class _RcResp:
    def __init__(self, payload, status=200):
        self._p, self._s = payload, status

    def raise_for_status(self):
        if self._s >= 400:
            raise RuntimeError(f"http {self._s}")

    def json(self):
        return self._p


def _fake_rc(monkeypatch, payload, status=200):
    import requests

    captured = {}

    def _get(url, headers=None, timeout=None):
        captured.update(url=url, headers=headers)
        return _RcResp(payload, status)

    monkeypatch.setattr(requests, "get", _get)
    return captured


def test_fetch_active_entitlement_returns_latest_active_mapped_plan(monkeypatch):
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    soon = (T0 + timedelta(days=10)).isoformat()
    later = (T0 + timedelta(days=40)).isoformat().replace("+00:00", "Z")
    payload = {"subscriber": {
        "entitlements": {
            "plus": {"product_identifier": "ayma_plus_monthly", "expires_date": soon},
            "max": {"product_identifier": "ayma_max_monthly", "expires_date": later},
        },
        "subscriptions": {"ayma_max_monthly": {"period_type": "normal"}},
    }}
    cap = _fake_rc(monkeypatch, payload)
    ent = billing.fetch_active_entitlement("u1", cfg, now=T0)
    assert ent["product_id"] == "ayma_max_monthly" and ent["is_trial"] is False
    assert cap["headers"]["Authorization"] == "Bearer sk_test"
    assert "u1" in cap["url"]


def test_fetch_active_entitlement_flags_trial(monkeypatch):
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    exp = (T0 + timedelta(days=20)).isoformat()
    payload = {"subscriber": {
        "entitlements": {"pro": {"product_identifier": "ayma_pro_monthly", "expires_date": exp}},
        "subscriptions": {"ayma_pro_monthly": {"period_type": "trial"}},
    }}
    _fake_rc(monkeypatch, payload)
    assert billing.fetch_active_entitlement("u1", cfg, now=T0)["is_trial"] is True


def test_fetch_active_entitlement_none_without_key(db):
    assert billing.fetch_active_entitlement("u1", CONFIG, now=T0) is None


def test_fetch_active_entitlement_skips_expired(monkeypatch):
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    exp = (T0 - timedelta(days=5)).isoformat()
    payload = {"subscriber": {
        "entitlements": {"pro": {"product_identifier": "ayma_pro_monthly", "expires_date": exp}},
        "subscriptions": {},
    }}
    _fake_rc(monkeypatch, payload)
    assert billing.fetch_active_entitlement("u1", cfg, now=T0) is None


# --- /billing/sync endpoint ---------------------------------------------------

_FAR = datetime(2030, 1, 1, tzinfo=timezone.utc)
_FAR_MS = int(_FAR.timestamp() * 1000)


def _sync_client(db, monkeypatch, secret_key=""):
    import auth

    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key=secret_key)
    monkeypatch.setattr(auth, "CONFIG", cfg)
    monkeypatch.setattr(main, "CONFIG", cfg)
    monkeypatch.setattr(main, "get_db", lambda: db)
    return TestClient(main.app)


def _dev_auth(monkeypatch, uid="u1", dev=False):
    claims = {"uid": uid}
    if dev:
        claims.update(email="suhailps@gmail.com", email_verified=True)
    monkeypatch.setattr(firebase_auth, "verify_id_token", lambda _t: claims)
    return {"Authorization": "Bearer valid"}


def test_sync_endpoint_requires_auth(db, monkeypatch):
    c = _sync_client(db, monkeypatch)
    assert c.post("/billing/sync", json={}).status_code in (401, 403)


def test_sync_endpoint_dev_fallback_grants_without_rest_key(db, monkeypatch):
    c = _sync_client(db, monkeypatch, secret_key="")
    headers = _dev_auth(monkeypatch, uid="u1", dev=True)
    body = {"product_id": "ayma_pro_monthly", "expires_at_ms": _FAR_MS}
    r = c.post("/billing/sync", json=body, headers=headers)
    assert r.status_code == 200
    j = r.json()
    assert j["sync_status"] == "synced_pro"
    assert j["credits"]["remaining"] == 1400


def test_sync_endpoint_non_dev_without_key_grants_nothing(db, monkeypatch):
    c = _sync_client(db, monkeypatch, secret_key="")
    headers = _dev_auth(monkeypatch, uid="u1", dev=False)
    body = {"product_id": "ayma_pro_monthly", "expires_at_ms": _FAR_MS}
    r = c.post("/billing/sync", json=body, headers=headers)
    assert r.status_code == 200
    j = r.json()
    assert j["sync_status"] == "no_active" and j["plan"] == "free"


def test_sync_endpoint_uses_rest_when_key_present(db, monkeypatch):
    c = _sync_client(db, monkeypatch, secret_key="sk_live")
    headers = _dev_auth(monkeypatch, uid="u1", dev=True)
    monkeypatch.setattr(
        billing, "fetch_active_entitlement",
        lambda uid, cfg, now=None: {
            "product_id": "ayma_max_monthly", "expires": _FAR, "is_trial": False,
        },
    )
    # the client body is ignored when the server has its own REST key
    r = c.post("/billing/sync",
               json={"product_id": "ayma_plus_monthly", "expires_at_ms": 1},
               headers=headers)
    j = r.json()
    assert j["sync_status"] == "synced_max" and j["credits"]["remaining"] == 8000


def test_sync_endpoint_rest_error_is_502(db, monkeypatch):
    c = _sync_client(db, monkeypatch, secret_key="sk_live")
    headers = _dev_auth(monkeypatch, uid="u1", dev=True)

    def _boom(uid, cfg, now=None):
        raise RuntimeError("down")

    monkeypatch.setattr(billing, "fetch_active_entitlement", _boom)
    assert c.post("/billing/sync", json={}, headers=headers).status_code == 502


# --- dev-only test upgrade (no real billing) ---------------------------------

@pytest.mark.parametrize("plan,credits", [
    ("plus", 700),
    ("pro", 1400),
    ("max", 8000),
])
def test_dev_test_upgrade_grants_the_tier_pool(db, monkeypatch, plan, credits):
    c = _sync_client(db, monkeypatch)
    headers = _dev_auth(monkeypatch, uid="u1", dev=True)
    r = c.post("/dev/test-upgrade", json={"plan": plan}, headers=headers)
    assert r.status_code == 200
    j = r.json()
    assert j["sync_status"] == f"synced_{plan}"
    assert j["plan"] == plan
    assert j["credits"]["remaining"] == credits
    # No dollar/payment fields leak to the client.
    assert "$" not in repr(j)


def test_dev_test_upgrade_rejects_non_dev(db, monkeypatch):
    c = _sync_client(db, monkeypatch)
    headers = _dev_auth(monkeypatch, uid="u1", dev=False)
    r = c.post("/dev/test-upgrade", json={"plan": "pro"}, headers=headers)
    assert r.status_code == 403
    # Nothing was granted — the account is still free.
    assert token_ledger.credits("u1")["plan"] == "free"


def test_dev_test_upgrade_requires_auth(db, monkeypatch):
    c = _sync_client(db, monkeypatch)
    assert c.post("/dev/test-upgrade", json={"plan": "pro"}).status_code in (401, 403)


def test_dev_test_upgrade_rejects_unknown_plan(db, monkeypatch):
    c = _sync_client(db, monkeypatch)
    headers = _dev_auth(monkeypatch, uid="u1", dev=True)
    r = c.post("/dev/test-upgrade", json={"plan": "free"}, headers=headers)
    assert r.status_code == 400
    assert token_ledger.credits("u1")["plan"] == "free"


def test_dev_test_upgrade_can_switch_tiers(db, monkeypatch):
    c = _sync_client(db, monkeypatch)
    headers = _dev_auth(monkeypatch, uid="u1", dev=True)
    assert c.post("/dev/test-upgrade", json={"plan": "plus"},
                  headers=headers).json()["credits"]["remaining"] == 700
    # Switching tier refreshes the pool to the new plan (not additive).
    j = c.post("/dev/test-upgrade", json={"plan": "max"}, headers=headers).json()
    assert j["plan"] == "max" and j["credits"]["remaining"] == 8000


# --- fetch_active_entitlement error handling & edge cases -----

class _RcErrorResp:
    def __init__(self, status=500, error_msg="Internal Server Error"):
        self._status = status
        self._msg = error_msg

    def raise_for_status(self):
        exc = RuntimeError(f"HTTP {self._status}: {self._msg}")
        exc.status_code = self._status
        raise exc

    def json(self):
        raise RuntimeError("json() called on error response")


def test_fetch_active_entitlement_http_error_propagates(monkeypatch):
    """Network/HTTP errors from RevenueCat API should propagate to caller."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    import requests

    def _get_500(url, headers=None, timeout=None):
        return _RcErrorResp(500)

    monkeypatch.setattr(requests, "get", _get_500)
    with pytest.raises(RuntimeError, match="HTTP 500"):
        billing.fetch_active_entitlement("u1", cfg, now=T0)


def test_fetch_active_entitlement_timeout_propagates(monkeypatch):
    """Timeout errors should propagate."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    import requests

    def _timeout(url, headers=None, timeout=None):
        raise requests.Timeout("connection timed out")

    monkeypatch.setattr(requests, "get", _timeout)
    with pytest.raises(Exception, match="timed out"):
        billing.fetch_active_entitlement("u1", cfg, now=T0)


def test_fetch_active_entitlement_connection_error_propagates(monkeypatch):
    """Connection errors should propagate."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    import requests

    def _conn_err(url, headers=None, timeout=None):
        raise requests.ConnectionError("unable to connect")

    monkeypatch.setattr(requests, "get", _conn_err)
    with pytest.raises(Exception, match="unable to connect"):
        billing.fetch_active_entitlement("u1", cfg, now=T0)


def test_fetch_active_entitlement_malformed_json_response(monkeypatch):
    """If response.json() fails, the error propagates."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    import requests

    class _BadJsonResp:
        def raise_for_status(self):
            pass

        def json(self):
            raise ValueError("invalid json")

    monkeypatch.setattr(requests, "get", lambda *a, **kw: _BadJsonResp())
    with pytest.raises(ValueError, match="invalid json"):
        billing.fetch_active_entitlement("u1", cfg, now=T0)


def test_fetch_active_entitlement_empty_subscriber_returns_none(monkeypatch):
    """Empty or missing subscriber data returns None."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    _fake_rc(monkeypatch, {})  # no subscriber key
    assert billing.fetch_active_entitlement("u1", cfg, now=T0) is None
    
    _fake_rc(monkeypatch, {"subscriber": None})  # null subscriber
    assert billing.fetch_active_entitlement("u1", cfg, now=T0) is None
    
    _fake_rc(monkeypatch, {"subscriber": {}})  # empty subscriber
    assert billing.fetch_active_entitlement("u1", cfg, now=T0) is None


def test_fetch_active_entitlement_no_entitlements_returns_none(monkeypatch):
    """When subscriber has no entitlements, returns None."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    _fake_rc(monkeypatch, {"subscriber": {"entitlements": None}})
    assert billing.fetch_active_entitlement("u1", cfg, now=T0) is None
    
    _fake_rc(monkeypatch, {"subscriber": {"entitlements": {}}})
    assert billing.fetch_active_entitlement("u1", cfg, now=T0) is None


def test_fetch_active_entitlement_empty_entitlements_returns_none(monkeypatch):
    """Empty entitlements dict returns None."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    payload = {"subscriber": {
        "entitlements": {},
        "subscriptions": {},
    }}
    _fake_rc(monkeypatch, payload)
    assert billing.fetch_active_entitlement("u1", cfg, now=T0) is None


def test_fetch_active_entitlement_skips_unmapped_products(monkeypatch):
    """Products that don't map to a known plan are skipped."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    exp = (T0 + timedelta(days=30)).isoformat()
    payload = {"subscriber": {
        "entitlements": {
            "unknown": {"product_identifier": "unknown_product", "expires_date": exp},
        },
        "subscriptions": {},
    }}
    _fake_rc(monkeypatch, payload)
    assert billing.fetch_active_entitlement("u1", cfg, now=T0) is None


def test_fetch_active_entitlement_skips_expired_with_grace(monkeypatch):
    """Entitlements past grace period should be skipped."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test",
                             billing_expiry_grace_seconds=3600)  # 1 hour grace
    # Past grace boundary: expired + grace + 1 second
    exp = (T0 - timedelta(hours=1, seconds=1)).isoformat()
    payload = {"subscriber": {
        "entitlements": {
            "pro": {"product_identifier": "ayma_pro_monthly", "expires_date": exp},
        },
        "subscriptions": {},
    }}
    _fake_rc(monkeypatch, payload)
    assert billing.fetch_active_entitlement("u1", cfg, now=T0) is None


def test_fetch_active_entitlement_includes_just_within_grace(monkeypatch):
    """Entitlements just within grace period should be included."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test",
                             billing_expiry_grace_seconds=3600)  # 1 hour grace
    # Just within grace: now + grace - 1 second
    exp = (T0 + timedelta(hours=1, seconds=-1)).isoformat()
    payload = {"subscriber": {
        "entitlements": {
            "pro": {"product_identifier": "ayma_pro_monthly", "expires_date": exp},
        },
        "subscriptions": {},
    }}
    _fake_rc(monkeypatch, payload)
    ent = billing.fetch_active_entitlement("u1", cfg, now=T0)
    assert ent is not None and ent["product_id"] == "ayma_pro_monthly"


def test_fetch_active_entitlement_picks_latest_expiry_when_multiple(monkeypatch):
    """When multiple entitlements exist, returns the one with latest expiry."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    soon = (T0 + timedelta(days=10)).isoformat()
    later = (T0 + timedelta(days=40)).isoformat()
    payload = {"subscriber": {
        "entitlements": {
            "plus": {"product_identifier": "ayma_plus_monthly", "expires_date": soon},
            "pro": {"product_identifier": "ayma_pro_monthly", "expires_date": later},
            "max": {"product_identifier": "ayma_max_monthly", "expires_date": soon},
        },
        "subscriptions": {"ayma_pro_monthly": {"period_type": "normal"}},
    }}
    _fake_rc(monkeypatch, payload)
    ent = billing.fetch_active_entitlement("u1", cfg, now=T0)
    assert ent["product_id"] == "ayma_pro_monthly"


def test_fetch_active_entitlement_invalid_iso_date_skips_entitlement(monkeypatch):
    """Entitlements with invalid expiry dates are skipped."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    valid = (T0 + timedelta(days=30)).isoformat()
    payload = {"subscriber": {
        "entitlements": {
            "bad": {"product_identifier": "ayma_plus_monthly", "expires_date": "not-a-date"},
            "good": {"product_identifier": "ayma_pro_monthly", "expires_date": valid},
        },
        "subscriptions": {"ayma_pro_monthly": {"period_type": "normal"}},
    }}
    _fake_rc(monkeypatch, payload)
    ent = billing.fetch_active_entitlement("u1", cfg, now=T0)
    # The bad one is skipped; the good one is returned
    assert ent["product_id"] == "ayma_pro_monthly"


def test_fetch_active_entitlement_missing_expiry_skips_entitlement(monkeypatch):
    """Entitlements without expiry_date are skipped."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    valid = (T0 + timedelta(days=30)).isoformat()
    payload = {"subscriber": {
        "entitlements": {
            "no_exp": {"product_identifier": "ayma_plus_monthly"},  # no expires_date
            "good": {"product_identifier": "ayma_pro_monthly", "expires_date": valid},
        },
        "subscriptions": {"ayma_pro_monthly": {"period_type": "normal"}},
    }}
    _fake_rc(monkeypatch, payload)
    ent = billing.fetch_active_entitlement("u1", cfg, now=T0)
    assert ent["product_id"] == "ayma_pro_monthly"


def test_fetch_active_entitlement_trial_detection_case_insensitive(monkeypatch):
    """Trial detection should be case-insensitive."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    exp = (T0 + timedelta(days=30)).isoformat()
    for period_type in ["TRIAL", "Trial", "trial", "TriAL"]:
        payload = {"subscriber": {
            "entitlements": {
                "pro": {"product_identifier": "ayma_pro_monthly", "expires_date": exp},
            },
            "subscriptions": {"ayma_pro_monthly": {"period_type": period_type}},
        }}
        _fake_rc(monkeypatch, payload)
        ent = billing.fetch_active_entitlement("u1", cfg, now=T0)
        assert ent["is_trial"] is True, f"Failed for period_type={period_type}"


def test_fetch_active_entitlement_with_empty_uid_returns_none(db):
    """Empty or None uid should return None without API call."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    assert billing.fetch_active_entitlement("", cfg, now=T0) is None
    assert billing.fetch_active_entitlement(None, cfg, now=T0) is None


def test_fetch_active_entitlement_uses_correct_timeout(monkeypatch):
    """The fetch should use a timeout parameter."""
    cfg = dataclasses.replace(CONFIG, revenuecat_secret_api_key="sk_test")
    captured = {}

    class _Resp:
        def raise_for_status(self):
            pass

        def json(self):
            return {"subscriber": {"entitlements": {}, "subscriptions": {}}}

    def _get(url, headers=None, timeout=None):
        captured["timeout"] = timeout
        return _Resp()

    import requests
    monkeypatch.setattr(requests, "get", _get)
    billing.fetch_active_entitlement("u1", cfg, now=T0)
    assert captured.get("timeout") == 10


# --- subscription status mapping edge cases -----

def test_authorize_header_comparison_is_constant_time(db):
    """The HMAC comparison should use constant-time comparison."""
    cfg = dataclasses.replace(CONFIG, revenuecat_webhook_secret="secret123")
    # Both wrong and right tokens should take same time (no early exit)
    assert billing.authorized("secret123", cfg) is True
    assert billing.authorized("secret124", cfg) is False
    assert billing.authorized("x" * 10, cfg) is False
    assert billing.authorized("", cfg) is False


def test_authorize_bearer_token_strips_whitespace(db):
    """Bearer token should be case-insensitive and whitespace-tolerant."""
    cfg = dataclasses.replace(CONFIG, revenuecat_webhook_secret="mytoken")
    assert billing.authorized("Bearer mytoken", cfg) is True
    assert billing.authorized("bearer mytoken", cfg) is True
    assert billing.authorized("  Bearer   mytoken  ", cfg) is True
    assert billing.authorized("BEARER mytoken", cfg) is True


def test_ms_conversion_handles_edge_cases():
    """_ms should handle various timestamp edge cases."""
    # Valid timestamp
    ts = T0.timestamp() * 1000
    result = billing._ms(ts)
    assert result is not None
    assert result.timestamp() == pytest.approx(T0.timestamp())
    
    # Invalid types
    assert billing._ms(None) is None
    assert billing._ms("not a number") is None
    assert billing._ms([]) is None
    
    # Extreme values
    assert billing._ms(0) is not None  # Unix epoch
    assert billing._ms(-1000) is not None  # negative (pre-epoch)


def test_plan_for_handles_product_suffixes():
    """_plan_for should handle product IDs with suffixes."""
    assert billing._plan_for("ayma_plus_monthly") == "plus"
    assert billing._plan_for("ayma_plus_monthly:base") == "plus"
    assert billing._plan_for("ayma_plus_monthly:extras") == "plus"
    assert billing._plan_for("ayma_pro_monthly:anything") == "pro"
    assert billing._plan_for("unknown_product") is None
    assert billing._plan_for("") is None
    assert billing._plan_for(None) is None


def test_credits_for_rounding():
    """credits_for should round up correctly."""
    cfg = CONFIG  # 100 credits per USD
    assert billing.credits_for(0.0, cfg) == 0
    assert billing.credits_for(0.001, cfg) == 1  # rounds up
    assert billing.credits_for(0.005, cfg) == 1  # rounds up  
    assert billing.credits_for(0.01, cfg) == 1
    assert billing.credits_for(1.0, cfg) == 100
    assert billing.credits_for(1.001, cfg) == 101  # rounds up


def test_dev_plan_entitlement_unknown_plan_raises():
    """dev_plan_entitlement should raise for unknown plans."""
    with pytest.raises(ValueError, match="unknown plan"):
        billing.dev_plan_entitlement("free", now=T0)
    
    with pytest.raises(ValueError, match="unknown plan"):
        billing.dev_plan_entitlement("enterprise", now=T0)
    
    with pytest.raises(ValueError, match="unknown plan"):
        billing.dev_plan_entitlement("", now=T0)
