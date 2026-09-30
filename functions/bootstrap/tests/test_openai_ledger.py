"""Ledger pricing + plan/api billing for the OpenAI provider
(docs/chatgpt-provider.md)."""

import pytest
import token_ledger
from config import CONFIG


class _Inc:
    def __init__(self, n):
        self.n = n


class _Events:
    def __init__(self, sink):
        self._sink = sink

    def add(self, data):
        self._sink.append(dict(data))

    def count(self):
        n = len(self._sink)

        class _Agg:
            @staticmethod
            def get():
                class _V:
                    value = n

                return [[_V()]]

        return _Agg()


class _UserRef:
    def __init__(self, sink):
        self._sink = sink

    def set(self, payload, merge=False):
        self._sink["sets"].append(payload)

    def collection(self, _name):
        return _Events(self._sink["events"])


class _Db:
    def __init__(self, sink):
        self._sink = sink

    def collection(self, _):
        return self

    def document(self, _):
        return _UserRef(self._sink)


@pytest.fixture
def sink(monkeypatch):
    s = {"sets": [], "events": []}
    monkeypatch.setattr(token_ledger, "get_db", lambda: _Db(s))
    import firebase_admin.firestore as fs

    monkeypatch.setattr(fs, "Increment", _Inc)
    monkeypatch.setattr(fs, "SERVER_TIMESTAMP", "TS")
    return s


def test_pricing_for_text_and_image_models():
    # $2 in / $10 out per 1M
    assert token_ledger.cost_usd_for(
        "chat", 1_000_000, 1_000_000, model="gpt-6.1-sol"
    ) == pytest.approx(12.0)
    # cached input uses the model's own cached rate ($0.10), not a factor
    assert token_ledger.cost_usd_for(
        "chat", 1_000_000, 0, cached_input_tokens=1_000_000, model="gpt-6.1-sol"
    ) == pytest.approx(0.10)
    assert token_ledger.cost_usd_for(
        "chat", 0, 1_000_000, model="gpt-6-luna"
    ) == pytest.approx(0.50)
    assert token_ledger.cost_usd_for(
        "misc", 0, 1_000_000, model="gpt-image-2.5-sunburst"
    ) == pytest.approx(30.0)


def test_realtime_models_are_unpriced_rather_than_guessed():
    for m in ("gpt-realtime-2.1", "gpt-realtime-2.1-mini"):
        assert token_ledger.cost_usd_for(
            "voice", 1_000_000, 1_000_000, model=m
        ) == 0.0


def test_gemini_pricing_is_untouched():
    assert token_ledger.cost_usd_for(
        "chat", 1_000_000, 1_000_000, model=CONFIG.gemini_model
    ) > 0
    assert CONFIG.gemini_model in token_ledger._MODEL_PRICING


def test_usage_from_openai_understands_all_three_shapes():
    assert token_ledger.usage_from_openai(
        {"input_tokens": 10, "output_tokens": 5,
         "input_tokens_details": {"cached_tokens": 4}}
    ) == (10, 5, 15, 4)
    assert token_ledger.usage_from_openai(
        {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 11,
         "prompt_tokens_details": {"cached_tokens": 2}}
    ) == (7, 3, 11, 2)
    assert token_ledger.usage_from_openai(
        {"input_tokens": 8, "output_tokens": 2,
         "input_token_details": {"cached_tokens": 99}}
    ) == (8, 2, 10, 8)  # cached clamped to input
    assert token_ledger.usage_from_openai(None) == (0, 0, 0, 0)
    assert token_ledger.usage_from_openai({}) == (0, 0, 0, 0)


def test_plan_billing_never_touches_credits_or_real_money(sink):
    token_ledger.record_openai(
        "u1", "chat",
        {"input_tokens": 1000, "output_tokens": 500},
        model="gpt-6.1-sol", billing=token_ledger.BILLING_PLAN,
        session_id="s-1",
    )
    (payload,) = [s["token_usage"] for s in sink["sets"]]
    assert "total" not in payload
    assert "cost_usd" not in payload
    assert "real_money_usd" not in payload
    assert payload["plan_total"].n == 1500
    assert payload["plan_features"]["chat"].n == 1500
    assert payload["plan_list_cost_usd"].n == pytest.approx(0.007)
    (event,) = sink["events"]
    assert event["billing"] == "plan"
    assert event["provider"] == "openai"
    assert event["cost_usd"] == 0.0
    assert event["list_cost_usd"] == pytest.approx(0.007)
    assert event["session_id"] == "s-1"


def test_api_billing_is_metered_like_gemini(sink):
    token_ledger.record_openai(
        "u1", "chat",
        {"input_tokens": 1000, "output_tokens": 500},
        model="gpt-6.1-sol", billing=token_ledger.BILLING_API,
    )
    (payload,) = [s["token_usage"] for s in sink["sets"]]
    assert payload["total"].n == 1500
    assert payload["cost_usd"].n == pytest.approx(0.007)
    assert payload["real_money_usd"].n == pytest.approx(0.007)
    (event,) = sink["events"]
    assert event["billing"] == "api" and event["provider"] == "openai"


def test_web_search_calls_are_priced_as_extra_cost(sink):
    token_ledger.record_openai(
        "u1", "research", {"input_tokens": 0, "output_tokens": 0},
        model="gpt-6.1-sol", billing=token_ledger.BILLING_API,
        extra_cost_usd=2 * token_ledger.OPENAI_WEB_SEARCH_USD_PER_CALL,
    )
    (payload,) = [s["token_usage"] for s in sink["sets"]]
    assert payload["cost_usd"].n == pytest.approx(0.02)


def test_check_is_skipped_for_plan_billing(monkeypatch):
    monkeypatch.setattr(
        token_ledger, "_read",
        lambda uid: pytest.fail("plan billing must not read credits"),
    )
    token_ledger.check("u1", billing=token_ledger.BILLING_PLAN)


def test_provider_limit_is_a_token_cap_error():
    assert issubclass(
        token_ledger.ProviderLimitReached, token_ledger.TokenCapExceeded
    )
