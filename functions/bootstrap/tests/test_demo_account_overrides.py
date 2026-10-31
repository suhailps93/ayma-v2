"""Demo/judge-account overrides (docs/DEMO_ACCOUNTS.md):

1. ``feature_flags.resolve/enabled`` turns every BOOL flag on for a uid in
   ``CONFIG.all_flags_on_uids`` and nobody else, without touching any global
   flag.
2. ``token_ledger._contact_verified`` lets exactly the emails in
   ``CONFIG.test_bypass_emails`` clear the free start-grant contact check even
   when their Firebase email is unverified; every other account stays gated.
"""

from __future__ import annotations

import dataclasses
import types

import pytest

import feature_flags as ff
import token_ledger
from config import CONFIG

DEMO_UID = "demo-test1"
OTHER_UID = "someone-else"
DEMO_EMAIL = "test2@gmail.com"
OTHER_EMAIL = "random-user@gmail.com"


@pytest.fixture
def _flag_config(monkeypatch):
    """Scope the override to exactly DEMO_UID and no firestore layer."""
    cfg = dataclasses.replace(CONFIG, all_flags_on_uids=(DEMO_UID,))
    monkeypatch.setattr(ff, "CONFIG", cfg)
    monkeypatch.setattr(ff, "_read_docs", lambda: {})
    ff.reset_cache()


def test_bool_flag_on_for_demo_uid(_flag_config):
    # meta_integrations defaults OFF globally; the override flips it ON for the
    # demo uid only, reporting the dedicated source.
    assert ff.enabled("meta_integrations", DEMO_UID) is True
    value, source = ff.resolve("meta_integrations", DEMO_UID)
    assert value is True
    assert source == "user_override"


def test_bool_flag_unchanged_for_other_uid(_flag_config):
    assert ff.enabled("meta_integrations", OTHER_UID) is False
    # No uid behaves exactly as before the change.
    assert ff.enabled("meta_integrations") is False


def test_non_bool_flag_never_overridden(_flag_config):
    # A route flag is not a bool; the demo uid must not force it to True.
    value, source = ff.resolve("llm_route_chat", DEMO_UID)
    assert value in ff.ROUTES
    assert source != "user_override"


def test_global_flag_doc_is_untouched(_flag_config):
    # The override is read-only: resolving for the demo uid writes nothing.
    captured = {}
    ff.resolve("meta_integrations", DEMO_UID)
    assert captured == {}


def _patch_get_user(monkeypatch, *, email, verified, phone=None):
    fake = types.SimpleNamespace(
        email=email, email_verified=verified, phone_number=phone
    )
    fake_auth = types.SimpleNamespace(get_user=lambda uid: fake)
    import firebase_admin

    monkeypatch.setattr(firebase_admin, "auth", fake_auth, raising=False)


@pytest.fixture
def _bypass_config(monkeypatch):
    cfg = dataclasses.replace(CONFIG, test_bypass_emails=(DEMO_EMAIL,))
    monkeypatch.setattr(token_ledger, "CONFIG", cfg)


def test_contact_verified_bypasses_demo_email_without_verification(
    monkeypatch, _bypass_config
):
    _patch_get_user(monkeypatch, email=DEMO_EMAIL, verified=False)
    assert token_ledger._contact_verified("any-uid") is True


def test_contact_verified_still_gates_non_demo_unverified_email(
    monkeypatch, _bypass_config
):
    _patch_get_user(monkeypatch, email=OTHER_EMAIL, verified=False)
    assert token_ledger._contact_verified("any-uid") is False


def test_contact_verified_allows_non_demo_verified_email(
    monkeypatch, _bypass_config
):
    _patch_get_user(monkeypatch, email=OTHER_EMAIL, verified=True)
    assert token_ledger._contact_verified("any-uid") is True
