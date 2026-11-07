"""Ayma's permitted-action context, built from the app registry config.

The system prompt must learn what Ayma may do in the app from CONFIG, never
from prose hardcoded into a prompt file (founder architecture ruling,
2026-11-06 — the same rule ``plan_facts.py`` already follows for prices).
This module renders ``prompts/action_facts.md`` from
``app_registry`` (``functions/bootstrap/app_registry.json``): the pages she
can open, the settings she can change and the account actions she can run.

The registry's ``exclusions`` block — the maintained deny-list — is read
here too and applied as a FILTER: an excluded account action never appears
in the permitted list (even if its handler field were flipped to an
executable one), and no excluded label is ever rendered. The prompt learns
the refusal behaviour generically ("a few actions are user-only; follow the
tool's refusal") — which buttons are user-only lives only in the config,
where the command layer enforces it (``excluded_account_action_keys``).
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

import app_registry

_TEMPLATE_PATH = Path(__file__).resolve().parent / "prompts" / "action_facts.md"


def _pages_block() -> str:
    """Every navigable destination's label — the pages open_screen
    opens — minus the destinations the exclusions config reserves (a
    page that exists solely as an excluded control's own page never
    renders as permitted)."""
    excluded = app_registry.excluded_destination_keys()
    return ", ".join(
        d["label"] for d in app_registry.destinations()
        if d["key"] not in excluded
    )


def _settings_block() -> str:
    """Every setting's label — the settings app_action can change."""
    return ", ".join(s["label"] for s in app_registry.settings())


def _account_actions_block() -> str:
    """Account actions she may actually RUN: executable handlers only,
    minus anything the exclusions config lists (the deny-list applied)."""
    excluded = app_registry.excluded_account_action_keys()
    names = [
        a["key"].replace("_", " ")
        for a in app_registry.account_actions()
        if a.get("handler") == "client" and a["key"] not in excluded
    ]
    return ", ".join(names) if names else "none"


@lru_cache(maxsize=1)
def action_facts() -> str:
    """The rendered permitted-action block for Ayma's system prompt (voice
    + text). The registry only changes on a deploy, so this is cached
    process-wide, exactly like ``plan_facts``."""
    return (
        _TEMPLATE_PATH.read_text(encoding="utf-8")
        .strip()
        .replace("{{PAGES}}", _pages_block())
        .replace("{{SETTINGS}}", _settings_block())
        .replace("{{ACCOUNT_ACTIONS}}", _account_actions_block())
    )
