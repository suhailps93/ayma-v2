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
# The real lookup, captured before conftest's autouse fixture stubs it.
_real_contact_verified = token_ledger._contact_verified
_real_grant_status = token_ledger._grant_status


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
    monkeypatch.setattr(token_ledger, "_grant_status", lambda uid, data: status[0])
    return d


def test_ineligible_account_gets_only_the_daily_allowance(monkeypatch):
    d = _new_user_db(monkeypatch, [token_ledger.GRANT_PENDING])
    assert token_ledger.credits("n1")["remaining"] == 25
    assert d.docs[("users", "n1")]["billing"]["start_grant_unlocked"] is False


def test_becoming_eligible_later_unlocks_the_start_grant(monkeypatch):
    st = [token_ledger.GRANT_PENDING]
    d = _new_user_db(monkeypatch, st)
    assert token_ledger.credits("n1")["remaining"] == 25
    st[0] = token_ledger.GRANT_OK
    assert token_ledger.credits("n1")["remaining"] == 500
    assert d.docs[("users", "n1")]["billing"]["start_grant_unlocked"] is True


def test_duplicate_face_is_blocked_permanently_without_rechecks(monkeypatch):
    st = [token_ledger.GRANT_DUPLICATE]
    d = _new_user_db(monkeypatch, st)
    assert token_ledger.credits("n1")["remaining"] == 25
    b = d.docs[("users", "n1")]["billing"]
    assert b["start_grant_unlocked"] is False and b["start_grant_blocked"] is True
    monkeypatch.setattr(
        token_ledger, "_grant_status",
        lambda uid, data: pytest.fail("blocked accounts are not re-checked"),
    )
    assert token_ledger.credits("n1")["remaining"] == 25


def test_unlocked_account_is_not_relocked_and_skips_lookup(monkeypatch):
    _new_user_db(monkeypatch, [token_ledger.GRANT_OK])
    assert token_ledger.credits("n1")["remaining"] == 500
    monkeypatch.setattr(
        token_ledger, "_grant_status",
        lambda uid, data: pytest.fail("no lookup once unlocked"),
    )
    assert token_ledger.credits("n1")["remaining"] == 500


def test_account_initialised_before_the_gate_stays_unlocked(db):
    b = db.user()["billing"]
    del b["start_grant_unlocked"]
    assert token_ledger.credits("u1")["remaining"] == 500


def test_contact_verified_rules(monkeypatch):
    from types import SimpleNamespace as NS

    from firebase_admin import auth as firebase_auth

    cases = [
        (NS(phone_number="+15551234567", email=None, email_verified=False), True),
        (NS(phone_number=None, email="a@b.c", email_verified=True), True),
        (NS(phone_number=None, email="a@b.c", email_verified=False), False),
        (NS(phone_number=None, email=None, email_verified=False), False),
    ]
    for user, expect in cases:
        monkeypatch.setattr(firebase_auth, "get_user", lambda uid, u=user: u)
        assert _real_contact_verified("x") is expect

    def boom(uid):
        raise RuntimeError("down")

    monkeypatch.setattr(firebase_auth, "get_user", boom)
    assert _real_contact_verified("x") is False


_SELFIE = {"face_verification": {"embedding": [1.0, 0.0, 0.0]}}


def _status(monkeypatch, data, contact=True, duplicate=False, uid="s1"):
    token_ledger._pending_until.clear()
    monkeypatch.setattr(token_ledger, "_contact_verified", lambda u: contact)
    monkeypatch.setattr(
        token_ledger, "_is_duplicate_face", lambda db, u, e: duplicate
    )
    monkeypatch.setattr(token_ledger, "get_db", lambda: object())
    return _real_grant_status(uid, data)


def test_grant_status_needs_selfie_contact_and_no_duplicate(monkeypatch):
    assert _status(monkeypatch, _SELFIE) == token_ledger.GRANT_OK
    assert _status(monkeypatch, {}) == token_ledger.GRANT_PENDING  # no selfie
    assert _status(monkeypatch, _SELFIE, contact=False) == token_ledger.GRANT_PENDING
    assert _status(monkeypatch, _SELFIE, duplicate=True) == token_ledger.GRANT_DUPLICATE


def test_grant_status_fails_closed_on_lookup_error(monkeypatch):
    def boom(db, u, e):
        raise RuntimeError("no vector index")

    token_ledger._pending_until.clear()
    monkeypatch.setattr(token_ledger, "_contact_verified", lambda u: True)
    monkeypatch.setattr(token_ledger, "_is_duplicate_face", boom)
    monkeypatch.setattr(token_ledger, "get_db", lambda: object())
    assert _real_grant_status("s1", _SELFIE) == token_ledger.GRANT_PENDING


class _NearSnap:
    def __init__(self, uid, emb, unlocked=True):
        self.id = uid
        self._d = {
            "face_verification": {"embedding": emb},
            "billing": {"start_grant_unlocked": unlocked},
        }

    def to_dict(self):
        return self._d


class _NearDb:
    def __init__(self, snaps):
        self._snaps = snaps

    def collection(self, name):
        return self

    def find_nearest(self, **kw):
        assert kw["vector_field"] == "face_verification.embedding"
        return self

    def stream(self):
        return iter(self._snaps)


def test_duplicate_face_uses_the_deep_dive_threshold():
    import deep_dive_images

    me = [1.0, 0.0]
    same = [1.0, 0.0]
    other = [0.0, 1.0]
    assert deep_dive_images._cosine(me, other) < deep_dive_images._VERIFY_THRESHOLD
    f = token_ledger._is_duplicate_face
    assert f(_NearDb([_NearSnap("a", same)]), "me", me) is True
    assert f(_NearDb([_NearSnap("a", other)]), "me", me) is False
    assert f(_NearDb([_NearSnap("me", same)]), "me", me) is False  # itself
    # a match that never got the grant is not "the original"
    assert f(_NearDb([_NearSnap("a", same, unlocked=False)]), "me", me) is False


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
