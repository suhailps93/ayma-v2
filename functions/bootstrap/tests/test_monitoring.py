import monitoring


def test_init_is_noop_without_dsn(monkeypatch):
    monkeypatch.delenv("SENTRY_DSN", raising=False)
    assert monitoring.init_sentry("ayma-api") is False


def test_capture_is_noop_when_uninitialised():
    monitoring.capture_exception(RuntimeError("boom"))


def test_scrub_event_drops_bodies_and_user_content():
    event = {
        "request": {
            "url": "/chat",
            "data": {"text": "hi"},
            "cookies": {"a": "b"},
            "headers": {"Authorization": "x"},
            "query_string": "q=1",
        },
        "user": {"id": "u"},
        "breadcrumbs": {"values": [{"message": "m", "data": {"text": "secret"}}]},
    }
    out = monitoring.scrub_event(event)
    assert out["request"] == {"url": "/chat"}
    assert "user" not in out
    assert "data" not in out["breadcrumbs"]["values"][0]
