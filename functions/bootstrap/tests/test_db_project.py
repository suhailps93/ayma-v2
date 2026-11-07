"""db._init_app: the LiveKit-agent SA branch pins the Firestore project.

The staging LiveKit worker held the PROD service-account key while its
GOOGLE_CLOUD_PROJECT said ayma-staging. Without an explicit projectId,
firebase-admin silently targets the key home project, so the staging
worker app_commands / bug_reports / raw_turns landed in prod Firestore
and every voice app-control ack timed out (2026-11-06). _init_app must
pass projectId from GOOGLE_CLOUD_PROJECT on the SA branch so a mismatched
key fails loudly against the configured project instead.
"""

import json

import db


def _capture(monkeypatch):
    calls = []
    monkeypatch.setattr(
        db.firebase_admin,
        "initialize_app",
        lambda *a, **k: calls.append((a, k)),
    )
    monkeypatch.setattr(
        db.credentials, "Certificate", lambda source: ("cert", source)
    )
    return calls


_SA_JSON = json.dumps({"type": "service_account", "project_id": "ayma-ai"})


def test_sa_branch_passes_project_id_from_env(monkeypatch):
    calls = _capture(monkeypatch)
    monkeypatch.setenv("LK_AGENT_FIRESTORE_SA", _SA_JSON)
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "ayma-staging")
    db._init_app()
    assert len(calls) == 1
    args, kwargs = calls[0]
    assert args[0][0] == "cert"  # the SA certificate credential
    assert args[1] == {"projectId": "ayma-staging"}
    assert kwargs == {}


def test_sa_branch_without_project_env_keeps_legacy_behaviour(monkeypatch):
    calls = _capture(monkeypatch)
    monkeypatch.setenv("LK_AGENT_FIRESTORE_SA", _SA_JSON)
    monkeypatch.delenv("GOOGLE_CLOUD_PROJECT", raising=False)
    db._init_app()
    args, kwargs = calls[0]
    assert len(args) == 1 and kwargs == {}


def test_adc_branch_is_unchanged(monkeypatch):
    # No SA secret (Cloud Run / local ADC): initialize_app() with no args,
    # even when GOOGLE_CLOUD_PROJECT is set - the runtime identity already
    # belongs to the right project.
    calls = _capture(monkeypatch)
    monkeypatch.delenv("LK_AGENT_FIRESTORE_SA", raising=False)
    monkeypatch.setenv("GOOGLE_CLOUD_PROJECT", "ayma-staging")
    db._init_app()
    assert calls == [((), {})]
