import dataclasses

import pytest
import token_ledger
from config import CONFIG


class _Meta:
    def __init__(self, total=None, prompt=0, cand=0):
        self.total_token_count = total
        self.prompt_token_count = prompt
        self.candidates_token_count = cand


class _Resp:
    def __init__(self, meta):
        self.usage_metadata = meta


class _Inc:
    def __init__(self, n):
        self.n = n


class _Doc:
    def __init__(self, store):
        self._s = store

    def get(self):
        s = self._s
        class _S:
            exists = "token_usage" in s
            def to_dict(self_):
                return dict(s)
        return _S()

    def set(self, payload, merge=False):
        u = payload["token_usage"]
        cur = self._s.setdefault("token_usage", {"total": 0, "features": {}})
        if isinstance(u.get("total"), _Inc):
            cur["total"] += u["total"].n
        for k, v in (u.get("features") or {}).items():
            cur["features"][k] = cur["features"].get(k, 0) + (
                v.n if isinstance(v, _Inc) else v)


class _Db:
    def __init__(self, store):
        self._store = store

    def collection(self, _):
        return self

    def document(self, _):
        return _Doc(self._store)


@pytest.fixture(autouse=True)
def _patch(monkeypatch):
    store = {}
    monkeypatch.setattr(token_ledger, "get_db", lambda: _Db(store))

    import firebase_admin.firestore as fs
    monkeypatch.setattr(fs, "Increment", _Inc)
    monkeypatch.setattr(fs, "SERVER_TIMESTAMP", "TS")
    return store


def test_record_adds_total_and_feature(_patch):
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1200)))
    token_ledger.record("u1", "chat", _Resp(_Meta(total=800)))
    token_ledger.record("u1", "matching", _Resp(_Meta(total=500)))
    u = token_ledger.usage("u1")
    assert u["total"] == 2500
    assert u["features"] == {"chat": 2000, "matching": 500}
    assert u["cap"] == CONFIG.token_cap_per_user
    assert u["remaining"] == CONFIG.token_cap_per_user - 2500


def test_record_falls_back_to_prompt_plus_candidates(_patch):
    token_ledger.record("u1", "wiki", _Resp(_Meta(prompt=300, cand=100)))
    assert token_ledger.usage("u1")["total"] == 400


def test_record_is_noop_without_uid(_patch):
    token_ledger.record(None, "chat", _Resp(_Meta(total=999)))
    assert token_ledger.usage("u1")["total"] == 0


def test_check_raises_at_cap(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, token_cap_per_user=1000),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1000)))
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")


def test_check_passes_below_cap(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, token_cap_per_user=1000),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=999)))
    token_ledger.check("u1")  # no raise


def test_check_and_record_never_raise_on_db_error(monkeypatch):
    def _boom():
        raise RuntimeError("firestore down")

    monkeypatch.setattr(token_ledger, "get_db", _boom)
    token_ledger.check("u1")  # swallowed
    token_ledger.record("u1", "chat", _Resp(_Meta(total=10)))  # swallowed


def test_usage_reports_credits_on_the_free_grant(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=100
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=12000)))
    u = token_ledger.usage("u1")
    assert u["credits"] == {"grant": 100, "used": 12, "remaining": 88}
    assert u["tokens_per_credit"] == 1000


def test_credits_used_rounds_up_a_partial_credit(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, tokens_per_credit=1000),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1)))
    assert token_ledger.credits("u1") == {"grant": 100, "used": 1,
                                          "remaining": 99}


def test_credits_never_go_negative(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=5
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=99000)))
    assert token_ledger.credits("u1")["remaining"] == 0


def test_per_user_credit_grant_overrides_the_free_grant(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=100
        ),
    )
    _patch["credit_grant"] = 500
    token_ledger.record("u1", "chat", _Resp(_Meta(total=10000)))
    u = token_ledger.usage("u1")
    assert u["credits"] == {"grant": 500, "used": 10, "remaining": 490}


def test_usage_exposes_per_action_credit_costs(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, credit_cost_match_score=12, credit_cost_run_matching=5
        ),
    )
    costs = token_ledger.usage("u1")["costs"]
    assert costs == {"match_score": 12, "run_matching": 5}
