import builtins
import dataclasses
import sys

import monitoring


def test_init_is_noop_without_dsn(monkeypatch):
    monkeypatch.delenv("SENTRY_DSN", raising=False)
    assert monitoring.init_sentry("ayma-api") is False


def test_capture_is_noop_when_uninitialised(monkeypatch):
    """The no-op path must not need sentry_sdk at all (it is absent from the
    unit-test env); importing it unconditionally was the original failure."""
    real_import = builtins.__import__

    def guard(name, *a, **k):
        assert name != "sentry_sdk"
        return real_import(name, *a, **k)

    monkeypatch.setattr(monitoring, "_initialised", False)
    monkeypatch.setattr(builtins, "__import__", guard)
    monitoring.capture_exception(RuntimeError("boom"))
    monitoring.capture_message("drain with calls", tags={"active_jobs": "1"})


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


def test_scrub_event_redacts_pii_in_text():
    event = {
        "message": "mail me@x.com or +1 (408) 555-0199",
        "logentry": {
            "message": "hi %s",
            "formatted": "hi me@x.com",
            "params": ["a"],
        },
        "exception": {"values": [{"value": "bad jane.doe@mail.example.org"}]},
        "extra": {"draft": "secret"},
        "breadcrumbs": {"values": [{"message": "to a@b.co", "data": {"t": "x"}}]},
    }
    out = monitoring.scrub_event(event)
    assert out["message"] == "mail [email] or [phone]"
    assert out["logentry"] == {"message": "hi %s", "formatted": "hi [email]"}
    assert out["exception"]["values"][0]["value"] == "bad [email]"
    assert "extra" not in out
    assert out["breadcrumbs"]["values"][0] == {"message": "to [email]"}


class _FakeSdk:
    def __init__(self):
        self.init_kwargs = None
        self.captured = []

    def init(self, **kwargs):
        self.init_kwargs = kwargs

    def set_tag(self, *_a):
        pass

    def capture_exception(self, exc):
        self.captured.append((exc, dict(self.scope_tags)) if self.scope_tags else exc)

    scope_tags: dict = {}

    def new_scope(self):
        sdk = self

        class _Scope:
            def __enter__(self):
                sdk.scope_tags = {}
                return self

            def __exit__(self, *_a):
                sdk.scope_tags = {}

            def set_tag(self, key, value):
                sdk.scope_tags[key] = value

        return _Scope()


def _fake_sdk(monkeypatch):
    sdk = _FakeSdk()
    monkeypatch.setitem(sys.modules, "sentry_sdk", sdk)
    monkeypatch.setattr(monitoring, "_initialised", False)
    monkeypatch.setenv("SENTRY_DSN", "https://k@o.ingest.sentry.io/1")
    return sdk


def test_init_uses_low_sampling_and_no_pii(monkeypatch):
    sdk = _fake_sdk(monkeypatch)
    assert monitoring.init_sentry("ayma-agent") is True
    kw = sdk.init_kwargs
    assert kw["send_default_pii"] is False
    assert kw["traces_sample_rate"] == 0.05
    assert kw["sample_rate"] == 1.0
    assert kw["before_send"] is monitoring.scrub_event
    err = RuntimeError("x")
    monitoring.capture_exception(err)
    assert sdk.captured == [err]


def test_kill_switch_disables_init(monkeypatch):
    sdk = _fake_sdk(monkeypatch)
    monkeypatch.setenv("FLAG_SENTRY", "false")
    assert monitoring.init_sentry("ayma-api") is False
    assert sdk.init_kwargs is None
    monitoring.capture_exception(RuntimeError("x"))
    assert sdk.captured == []


def test_capture_tags_one_event_only(monkeypatch):
    sdk = _fake_sdk(monkeypatch)
    assert monitoring.init_sentry("ayma-agent") is True
    err = RuntimeError("swap")
    monitoring.capture_exception(err, tags={"session_id": "s-1", "voice_provider": "x"})
    monitoring.capture_exception(err)
    assert sdk.captured == [(err, {"session_id": "s-1", "voice_provider": "x"}), err]
