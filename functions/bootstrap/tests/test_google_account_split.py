"""Tests verifying Tier-2 sweep monolith split #16 (google_account.py split).

Verifies that the google_account monolith is properly factored into:
- google_account_oauth (OAuth endpoints, auth_url, token lifecycle, status)
- google_account_gmail (Gmail domain exclude, quote stripping, body extraction, _gmail_facts)
- google_account_calendar (Calendar events fetch, _calendar_facts)
- google_account (facade re-exporting all symbols for 100% backward compatibility,
  plus sync/sweep orchestration)
"""

import os
from pathlib import Path

import pytest

import google_account
import google_account_calendar
import google_account_gmail
import google_account_oauth


def test_facade_reexports_all_oauth_symbols():
    oauth_symbols = [
        "GoogleAccountError",
        "_AUTH_ENDPOINT",
        "_TOKEN_ENDPOINT",
        "_REVOKE_ENDPOINT",
        "_USERINFO_ENDPOINT",
        "_SCOPES",
        "_TOKEN_COLLECTION",
        "_TOKEN_DOC",
        "_client_secret",
        "auth_url",
        "_post_form",
        "_get_json_auth",
        "_exchange_code",
        "_refresh_access_token",
        "_revoke",
        "_fetch_email",
        "_token_doc",
        "connect",
        "disconnect",
        "status",
    ]
    for sym in oauth_symbols:
        assert hasattr(google_account_oauth, sym), f"google_account_oauth missing {sym}"
        assert hasattr(google_account, sym), f"google_account facade missing {sym}"
        assert getattr(google_account, sym) is getattr(google_account_oauth, sym)


def test_facade_reexports_all_gmail_symbols():
    gmail_symbols = [
        "_GMAIL_BASE",
        "_GMAIL_BODY_MAX_CHARS",
        "_DEFAULT_GMAIL_EXCLUDE_DOMAINS",
        "_QUOTE_HEADER_RE",
        "_read_gmail_exclude_domains",
        "_domain_excluded",
        "_strip_quoted_lines",
        "_iter_text_plain_parts",
        "_decode_body_data",
        "_extract_gmail_body",
        "_gmail_facts",
    ]
    for sym in gmail_symbols:
        assert hasattr(google_account_gmail, sym), f"google_account_gmail missing {sym}"
        assert hasattr(google_account, sym), f"google_account facade missing {sym}"
        assert getattr(google_account, sym) is getattr(google_account_gmail, sym)


def test_facade_reexports_all_calendar_symbols():
    calendar_symbols = [
        "_CALENDAR_BASE",
        "_calendar_facts",
    ]
    for sym in calendar_symbols:
        assert hasattr(google_account_calendar, sym), f"google_account_calendar missing {sym}"
        assert hasattr(google_account, sym), f"google_account facade missing {sym}"
        assert getattr(google_account, sym) is getattr(google_account_calendar, sym)


def test_facade_reexports_dependencies_and_orchestration():
    deps = [
        "CONFIG",
        "schema",
        "Turn",
        "ROLE_USER",
        "iso_or_str",
        "logger",
    ]
    for dep in deps:
        assert hasattr(google_account, dep), f"google_account facade missing {dep}"

    orchestration_symbols = [
        "sync_user",
        "_safe_sync",
        "schedule_sync",
        "_age_hours",
        "sweep",
    ]
    for sym in orchestration_symbols:
        assert hasattr(google_account, sym), f"google_account facade missing {sym}"


def test_submodule_direct_oauth_auth_url(monkeypatch):
    import dataclasses

    cfg = dataclasses.replace(
        google_account_oauth.CONFIG,
        google_import_client_id="TEST_CLIENT",
        google_import_redirect_uri="https://ayma.example/callback",
    )
    monkeypatch.setattr(google_account_oauth, "CONFIG", cfg)
    monkeypatch.setenv("GOOGLE_IMPORT_CLIENT_SECRET", "TEST_SECRET")

    url = google_account_oauth.auth_url("state_test")
    assert "https://accounts.google.com/o/oauth2/v2/auth?" in url
    assert "client_id=TEST_CLIENT" in url
    assert "state=state_test" in url


def test_submodule_direct_gmail_domain_excluded():
    excluded = ["bank.com", "gov.org"]
    assert google_account_gmail._domain_excluded("bank.com", excluded) is True
    assert google_account_gmail._domain_excluded("sub.bank.com", excluded) is True
    assert google_account_gmail._domain_excluded("notbank.com", excluded) is False
    assert google_account_gmail._domain_excluded("safe.org", excluded) is False


def test_submodule_direct_gmail_strip_quotes():
    text = "Hello\n> Quoted line\nOn Mon, wrote:\nWorld"
    stripped = google_account_gmail._strip_quoted_lines(text)
    assert stripped == "Hello\nWorld"


def test_submodule_direct_calendar_facts_handles_network_error(monkeypatch):
    def _boom(url, token):
        raise RuntimeError("Network error")

    monkeypatch.setattr(google_account_calendar, "_get_json_auth", _boom)
    facts = google_account_calendar._calendar_facts("dummy_token")
    assert facts == []


def test_facade_line_count_reduction():
    facade_path = Path(google_account.__file__)
    lines = len(facade_path.read_text(encoding="utf-8").splitlines())
    # Monolith was ~701 lines; facade including full preserved docstring is ~360 lines
    assert lines <= 370, f"Facade line count {lines} exceeds 370 lines limit"
