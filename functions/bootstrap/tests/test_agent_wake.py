"""agent_wake.wake_agent — the scale-to-zero ayma-agent "wake" ping fired by
/bootstrap and /welcome/token (docs/deploy.md §12.2)."""

import dataclasses
import urllib.error

import agent_wake
from config import CONFIG


def test_wake_agent_is_a_noop_when_agent_url_unset(monkeypatch):
    monkeypatch.setattr(agent_wake, "CONFIG", dataclasses.replace(CONFIG, agent_url=""))
    calls = []
    monkeypatch.setattr(
        agent_wake.google_id_token, "fetch_id_token", lambda *a, **k: calls.append(1)
    )
    agent_wake.wake_agent()
    assert calls == []


def test_wake_agent_sends_an_authenticated_get_to_the_agent_url(monkeypatch):
    monkeypatch.setattr(
        agent_wake, "CONFIG",
        dataclasses.replace(CONFIG, agent_url="https://ayma-agent.example.run.app"),
    )
    monkeypatch.setattr(
        agent_wake.google_id_token, "fetch_id_token", lambda *a, **k: "id-token-value"
    )
    seen = {}

    class _Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b""

    def _fake_urlopen(req, timeout=None):
        seen["url"] = req.full_url
        seen["auth"] = req.get_header("Authorization")
        seen["timeout"] = timeout
        return _Resp()

    monkeypatch.setattr(agent_wake.urllib.request, "urlopen", _fake_urlopen)
    agent_wake.wake_agent()

    assert seen["url"] == "https://ayma-agent.example.run.app"
    assert seen["auth"] == "Bearer id-token-value"
    assert seen["timeout"] == agent_wake._TIMEOUT_SECONDS


def test_wake_agent_treats_an_http_error_response_as_a_successful_wake(monkeypatch):
    """Any HTTP response — even a 404/403 from the worker's bare route — proves
    Cloud Run already routed the request to a container, which is all a wake
    ping needs; it must not raise."""
    monkeypatch.setattr(
        agent_wake, "CONFIG",
        dataclasses.replace(CONFIG, agent_url="https://ayma-agent.example.run.app"),
    )
    monkeypatch.setattr(agent_wake.google_id_token, "fetch_id_token", lambda *a, **k: "tok")

    def _raise(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url, 404, "not found", None, None)

    monkeypatch.setattr(agent_wake.urllib.request, "urlopen", _raise)
    agent_wake.wake_agent()  # must not raise


def test_wake_agent_swallows_any_other_failure(monkeypatch):
    monkeypatch.setattr(
        agent_wake, "CONFIG",
        dataclasses.replace(CONFIG, agent_url="https://ayma-agent.example.run.app"),
    )

    def _raise(*a, **k):
        raise RuntimeError("no metadata server here")

    monkeypatch.setattr(agent_wake.google_id_token, "fetch_id_token", _raise)
    agent_wake.wake_agent()  # must not raise
