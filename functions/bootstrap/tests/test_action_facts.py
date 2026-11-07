"""ACTION PARITY (founder, 2026-11-06): the system prompt's picture of
what Ayma may do in the app is rendered from CONFIG at build time —
``action_facts`` reads ``app_registry.json`` the way ``plan_facts``
reads the plan config. Nothing about buttons is hardcoded into prompt
text, and the exclusions deny-list is applied as a filter: a user-only
action never appears in the permitted context, by label or by key.
"""

from __future__ import annotations

import pytest

import action_facts
import app_registry
import prompt


@pytest.fixture(autouse=True)
def _fresh_render():
    action_facts.action_facts.cache_clear()
    yield
    action_facts.action_facts.cache_clear()


def test_block_renders_the_real_registry():
    block = action_facts.action_facts()
    # A destination label and a setting label straight from the config.
    assert app_registry.destinations()[0]["label"] in block
    assert app_registry.settings()[0]["label"] in block
    # The one executable account action, rendered from its key.
    assert "sign out" in block


def test_exclusions_never_render():
    block = action_facts.action_facts()
    for item in app_registry.exclusions():
        assert item["label"] not in block, item["key"]
    # The excluded account actions' (annotated) labels stay out too.
    acts = {a["key"]: a for a in app_registry.account_actions()}
    for key in app_registry.excluded_account_action_keys():
        assert acts[key]["label"] not in block, key
    assert "Delete account" not in block
    assert "Wipe what Ayma has learned" not in block


def test_deny_list_shapes_the_permitted_set(monkeypatch):
    """Config-driven proof: exclude sign_out in the config and it drops
    out of the prompt's permitted context at build time — with no
    prompt-text edit anywhere."""
    monkeypatch.setattr(
        app_registry, "excluded_account_action_keys", lambda: {"sign_out"}
    )
    block = action_facts.action_facts()
    assert "sign out" not in block
    assert "Account actions you can run** (account_action): none" in block


def test_deny_list_filters_pages_too(monkeypatch):
    """The Delete account page — a destination that exists solely as
    an excluded control's own page — never renders as a permitted
    page, while the general pages exclusions merely live on (Plan,
    Ayma's settings) stay listed: she may open them, just not act."""
    block = action_facts.action_facts()
    assert "Plan (your plan and credits)" in block
    # Excluding a destination in config removes it at build time.
    monkeypatch.setattr(
        app_registry, "excluded_destination_keys", lambda: {"credits"}
    )
    action_facts.action_facts.cache_clear()
    assert "Plan (your plan and credits)" not in action_facts.action_facts()


def test_new_config_entries_render_without_a_prompt_edit(monkeypatch):
    real = app_registry.destinations
    monkeypatch.setattr(
        app_registry,
        "destinations",
        lambda: real() + [{"key": "zebra", "label": "Zebra Page",
                           "path": "/zebra"}],
    )
    assert "Zebra Page" in action_facts.action_facts()


def test_compose_includes_the_block_in_both_surfaces():
    for variant in ("text", "voice"):
        text = prompt.compose_system_prompt(variant=variant)
        assert "your permitted actions" in text, variant
        assert text.count("your permitted actions") == 1, variant
        # Stable prefix: it lands after the plan facts, before any
        # per-user context — byte-stable across turns and users.
        assert text.index("Ayma plans and credits") < text.index(
            "your permitted actions"), variant
        assert "Delete account" not in text, variant
