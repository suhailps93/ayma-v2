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
        s = self._s
        if "credits_added" in payload:
            v = payload["credits_added"]
            # Increment sentinel adds; a plain int is an absolute set (topup
            # now writes the computed absolute value).
            s["credits_added"] = (
                s.get("credits_added", 0) + v.n if isinstance(v, _Inc)
                else int(v)
            )
        u = payload.get("token_usage")
        if u is None:
            return
        cur = s.setdefault(
            "token_usage",
            {"total": 0, "input": 0, "output": 0, "cost_usd": 0.0, "features": {}},
        )
        if isinstance(u.get("total"), _Inc):
            cur["total"] += u["total"].n
        if isinstance(u.get("input"), _Inc):
            cur["input"] = cur.get("input", 0) + u["input"].n
        if isinstance(u.get("output"), _Inc):
            cur["output"] = cur.get("output", 0) + u["output"].n
        if isinstance(u.get("cost_usd"), _Inc):
            cur["cost_usd"] = cur.get("cost_usd", 0.0) + u["cost_usd"].n
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


def test_record_falls_back_to_prompt_plus_candidates(_patch):
    token_ledger.record("u1", "wiki", _Resp(_Meta(prompt=300, cand=100)))
    u = token_ledger.usage("u1")
    assert u["total"] == 400
    assert u["input"] == 300
    assert u["output"] == 100


def test_record_splits_input_and_output_tokens(_patch):
    """The Firestore doc gets input/output alongside total — the fields a
    real-dollar cost audit needs (PLAN.md F1/F2), additive to (never
    replacing) the existing total used for credit charging."""
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1200, prompt=800, cand=400)))
    token_ledger.record("u1", "chat", _Resp(_Meta(total=600, prompt=500, cand=100)))
    u = token_ledger.usage("u1")
    assert u["total"] == 1800
    assert u["input"] == 1300
    assert u["output"] == 500


def test_record_keeps_total_larger_than_input_plus_output_when_present(_patch):
    """When the SDK's own total_token_count exceeds prompt+candidates (e.g.
    thinking/tool-use tokens folded in), total is trusted as-is for credit
    charging while input/output stay the plain prompt/candidates split."""
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1000, prompt=300, cand=200)))
    u = token_ledger.usage("u1")
    assert u["total"] == 1000
    assert u["input"] == 300
    assert u["output"] == 200


def test_record_without_usage_metadata_records_nothing(_patch):
    token_ledger.record("u1", "chat", _Resp(None))
    u = token_ledger.usage("u1")
    assert u["total"] == 0
    assert u["input"] == 0
    assert u["output"] == 0


def test_record_is_noop_without_uid(_patch):
    token_ledger.record(None, "chat", _Resp(_Meta(total=999)))
    assert token_ledger.usage("u1")["total"] == 0


def test_check_raises_when_out_of_credits(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=1
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1500)))  # used 2 > 1
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")


def test_check_passes_with_credits_left(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=5
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=999)))
    token_ledger.check("u1")  # no raise


def test_topup_adds_credits_and_clears_the_out_of_credits_gate(
    monkeypatch, _patch
):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=1
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1500)))  # used = 2
    with pytest.raises(token_ledger.TokenCapExceeded):
        token_ledger.check("u1")

    res = token_ledger.topup("u1", 100)

    # A reload gives *at least* `amount` usable credits, forgiving the overspend
    # (used 2 vs grant 1): new_added = max(0+100, 2-1+100) = 101 -> remaining 100.
    assert res["remaining"] == 100
    c = token_ledger.credits("u1")
    assert c["added"] == 101
    assert c["remaining"] == 100
    token_ledger.check("u1")  # no longer raises


def test_topup_from_a_deep_deficit_still_yields_exactly_amount(
    monkeypatch, _patch
):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=100
        ),
    )
    _patch["credits_added"] = 800
    token_ledger.record("u1", "voice", _Resp(_Meta(total=913_000)))  # used 913
    assert token_ledger.credits("u1")["remaining"] == 0  # 100 + 800 - 913

    token_ledger.topup("u1", 100)
    assert token_ledger.credits("u1")["remaining"] == 100  # one tap = 100 usable


def test_topup_for_a_user_in_the_black_just_adds_amount(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, tokens_per_credit=1000, credits_free_grant=100
        ),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=42_000)))  # used 42
    assert token_ledger.credits("u1")["remaining"] == 58

    token_ledger.topup("u1", 100)
    assert token_ledger.credits("u1")["remaining"] == 158


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
    assert u["credits"] == {"grant": 100, "added": 0, "used": 12, "remaining": 88}
    assert u["tokens_per_credit"] == 1000


def test_credits_used_rounds_up_a_partial_credit(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, tokens_per_credit=1000),
    )
    token_ledger.record("u1", "chat", _Resp(_Meta(total=1)))
    assert token_ledger.credits("u1") == {"grant": 100, "added": 0, "used": 1,
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
    assert u["credits"] == {
        "grant": 500, "added": 0, "used": 10, "remaining": 490,
    }


def test_usage_starts_cost_usd_at_zero_for_a_fresh_user(_patch):
    assert token_ledger.usage("u1")["cost_usd"] == 0


def test_record_accumulates_real_dollar_cost_from_input_output_split(_patch):
    """chat/wiki/matching/etc. all bill against gemini-3.7-flash: $0.75/1M
    input, $3.75/1M output (see token_ledger._MODEL_PRICING)."""
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=1_000_000, cand=1_000_000))
    )
    assert token_ledger.usage("u1")["cost_usd"] == pytest.approx(0.75 + 3.75)

    # Start from zero and add as calls come in — a second call adds more.
    token_ledger.record(
        "u1", "chat", _Resp(_Meta(prompt=500_000, cand=0))
    )
    assert token_ledger.usage("u1")["cost_usd"] == pytest.approx(
        0.75 + 3.75 + 0.375
    )


def test_record_from_pre_split_usage_contributes_zero_cost(_patch):
    """A response with only total_token_count (no prompt/candidates split —
    how every usage doc looked before commit 278c562) must not be guessed
    into a dollar figure: cost_usd stays exactly 0."""
    token_ledger.record("u1", "chat", _Resp(_Meta(total=50_000)))
    u = token_ledger.usage("u1")
    assert u["total"] == 50_000
    assert u["cost_usd"] == 0


def test_cost_usd_for_voice_uses_audio_input_and_output_rates(_patch):
    # Gemini Live native-audio: $3.00/1M input (audio), $12.00/1M output.
    cost = token_ledger.cost_usd_for(
        token_ledger.FEATURE_VOICE, 1_000_000, 1_000_000
    )
    assert cost == pytest.approx(3.00 + 12.00)


def test_cost_usd_for_photo_edit_prices_input_only(_patch):
    """gemini-2.5-flash-image bills output per generated image, not per
    output token — the ledger only counts tokens, so output cost is left
    unpriced (0) rather than guessed at a tokens-per-image ratio; input
    ($0.30/1M) is still priced."""
    cost = token_ledger.cost_usd_for(
        token_ledger.FEATURE_PHOTO_EDIT, 1_000_000, 1_000_000
    )
    assert cost == pytest.approx(0.30)


def test_cost_usd_for_unpriced_model_is_zero_not_guessed(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(CONFIG, gemini_model="some-future-unpriced-model"),
    )
    assert token_ledger.cost_usd_for("chat", 1_000_000, 1_000_000) == 0.0


def test_cost_usd_for_zero_tokens_is_zero(_patch):
    assert token_ledger.cost_usd_for("chat", 0, 0) == 0.0


def test_usage_lists_only_token_spending_actions_in_costs(monkeypatch, _patch):
    monkeypatch.setattr(
        token_ledger, "CONFIG",
        dataclasses.replace(
            CONFIG, credit_cost_match_score=12, credit_cost_photo_edit=5,
        ),
    )
    # Pass-1 pool matching is heuristic-only (no Gemini) -> not a credit cost.
    assert token_ledger.usage("u1")["costs"] == {
        "match_score": 12, "photo_edit": 5,
    }
