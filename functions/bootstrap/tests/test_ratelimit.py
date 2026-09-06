import dataclasses

import ratelimit
from config import CONFIG
from fastapi import FastAPI
from fastapi.testclient import TestClient


def test_parse_rate():
    assert ratelimit.parse_rate("20/minute") == (20, 60)
    assert ratelimit.parse_rate("5/second") == (5, 1)
    assert ratelimit.parse_rate("100/hour") == (100, 3600)
    assert ratelimit.parse_rate("garbage") == (60, 60)


def test_rate_for_longest_prefix_and_default(monkeypatch):
    monkeypatch.setattr(
        ratelimit, "CONFIG",
        dataclasses.replace(CONFIG, rate_dm_send="7/minute",
                            rate_default="99/minute"),
    )
    assert ratelimit.rate_for("/dm/a__b/messages") == "7/minute"
    assert ratelimit.rate_for("/chat") == CONFIG.rate_chat_text
    assert ratelimit.rate_for("/nothing-here") == "99/minute"


def test_chat_history_has_its_own_bucket_not_the_send_limit():
    # Regression: `/chat/history` used to fall under the `/chat` prefix and
    # share `POST /chat`'s allowance, so a swallowed 429 on tab-open showed as
    # an empty transcript. It must resolve to its own, separate rate + bucket.
    assert ratelimit.rate_for("/chat/history") == CONFIG.rate_chat_history
    # Distinct prefix => distinct fixed-window bucket from `POST /chat`.
    assert ratelimit._match_prefix("/chat/history") == "/chat/history"
    assert ratelimit._match_prefix("/chat") == "/chat"


def test_middleware_returns_429_past_the_limit(monkeypatch):
    monkeypatch.setattr(ratelimit, "ENABLED", True)
    monkeypatch.setattr(
        ratelimit, "_route_rates",
        lambda: {"/ping": "3/minute"},
    )

    app = FastAPI()
    app.add_middleware(ratelimit.RateLimiter)

    @app.get("/ping")
    def ping():
        return {"ok": True}

    client = TestClient(app)
    codes = [client.get("/ping").status_code for _ in range(5)]
    assert codes[:3] == [200, 200, 200]
    assert codes[3] == 429 and codes[4] == 429
    assert "Retry-After" in client.get("/ping").headers


def test_disabled_flag_bypasses_the_limiter(monkeypatch):
    monkeypatch.setattr(ratelimit, "ENABLED", False)
    monkeypatch.setattr(ratelimit, "_route_rates", lambda: {"/ping": "1/minute"})

    app = FastAPI()
    app.add_middleware(ratelimit.RateLimiter)

    @app.get("/ping")
    def ping():
        return {"ok": True}

    client = TestClient(app)
    assert [client.get("/ping").status_code for _ in range(5)] == [200] * 5
