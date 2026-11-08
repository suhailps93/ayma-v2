"""APP ACTION GRAPH coverage sanity (ACTION PARITY, founder 2026-11-06).

``docs/APP_ACTION_GRAPH.md`` is the living map of every tappable control
in the app and the command Ayma uses for it. These checks keep it from
rotting mechanically:

* every tool in Ayma's full surface (text superset + voice) is named in
  the graph — a new tool ships with its graph entry;
* every backticked snake_case name in the graph is a real tool or a
  known registry/client identifier — a renamed or deleted tool fails
  here instead of silently leaving a stale command in the doc;
* the exclusions config (the controls Ayma must never activate) is
  consistent across the registry: each excluded key has a navigate-only
  or unavailable enforcement path and a ``ui_action`` refusal, and the
  graph marks it EXCLUDED.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

import app_registry
import skills
from skills import app_control

_REPO = Path(__file__).resolve().parents[3]
_GRAPH = _REPO / "docs" / "APP_ACTION_GRAPH.md"

# Backticked names in the graph that are deliberately NOT tools:
# registry blocks/keys, destination keys, setting keys, client command
# actions, and names the graph itself proposes for future GAP work.
_NON_TOOL_NAMES = {
    # registry structure / blocks
    "destinations", "parameterized", "non_navigable", "unavailable",
    "exclusions", "async_voice", "connection_banner",
    # a real tool on v2; on staging it lands via the self-check port
    # (fleet/self-check-staging), so the graph may name it already
    "set_notification_filter",
    # exclusions config field names
    "account_actions", "deny_keys", "excluded_account_action_keys",
    # destination keys named as open_screen arguments
    "ayma_settings", "complete_profile", "credits", "feedback",
    "invite_friends", "my_appearance", "my_public_profile",
    "my_web_research", "privacy", "profile_details", "settings",
    "story", "terms",
    # setting keys / handlers
    "distance_preference", "partner_age_range",
    # exclusion + unavailable keys
    "clear_memory", "delete_account", "purchase", "developer_panel",
    # deny rule keys named in the graph
    "delete", "block_report", "dismiss_all",
    # client-internal identifiers: AppCommandService command actions
    # and the app_action names it executes
    "tour_step", "tour_event", "resume_matching", "end_call",
    "dm_assist", "plan_facts",
    "navigate", "open_dm_thread", "tour_end", "sign_out",
    "dark_mode", "light_mode", "system_theme", "accent_color",
    "pause_matching",
    # proposed in the GAP register, not yet built (GAP-3 / GAP-5)
    "play_voice_preview", "swipe",
    # the family name for the set_* stack tools
    "set_model_stack",
}


def _graph_text() -> str:
    if not _GRAPH.exists():
        pytest.skip("action graph not checked out next to the backend")
    return _GRAPH.read_text(encoding="utf-8")


def _tool_names() -> set[str]:
    names = {
        d["name"]
        for d in skills.session_tool_declarations(
            story=True, profile_edit=True, photo=True,
            deep_dive=True, appearance=True,
        )
    }
    names |= {s.name for s in app_control.VOICE_SKILLS}
    names |= {s.name for s in app_control.COMMAND_SKILLS}
    # recall is flag-gated (context_opt) so the declarations above only
    # carry it when the flag is on; it is a real tool either way.
    names.add(skills.recall.SKILL.name)
    return names


def test_every_tool_is_named_in_the_graph():
    text = _graph_text()
    missing = sorted(n for n in _tool_names() if n not in text)
    assert not missing, (
        "tools missing from docs/APP_ACTION_GRAPH.md "
        f"(add each with its screen entry): {missing}"
    )


def test_every_backticked_name_in_the_graph_is_real():
    text = _graph_text()
    known = _tool_names() | _NON_TOOL_NAMES
    unknown = set()
    for span in re.findall(r"`([^`]+)`", text):
        first = span.strip().split()[0] if span.strip() else ""
        if re.fullmatch(r"[a-z][a-z0-9_]*", first) and first not in known:
            unknown.add(first)
    assert not unknown, (
        "names in docs/APP_ACTION_GRAPH.md that are neither a tool nor "
        f"a known identifier (renamed/removed?): {sorted(unknown)}"
    )


def test_exclusions_config_is_complete_and_enforced():
    keys = app_registry.exclusion_keys()
    assert keys == {
        "delete_account", "purchase", "clear_memory",
        "delete_photo_everywhere", "block_report",
        "dismiss_all_suggestions",
    }
    acts = {a["key"]: a for a in app_registry.account_actions()}
    # Delete account: navigate-only, and its page is a ui_action deny route.
    assert acts["delete_account"]["handler"] == "navigate_only"
    deny_routes = {
        d["route"] for d in app_registry.registry()["ui_action_policy"]["deny_routes"]
    }
    assert "/settings/delete-account" in deny_routes
    # Purchase: the unavailable entry only ever opens the Plan page, and a
    # ui_action deny rule refuses the controls themselves.
    purchase = next(
        u for u in app_registry.unavailable() if u["key"] == "purchase"
    )
    assert purchase["navigate"] == "credits"
    deny_keys = {
        r["key"] for r in app_registry.registry()["ui_action_policy"]["deny"]
    }
    assert "purchase" in deny_keys
    # Clear memory: wipe_memory is navigate-only and a deny rule refuses
    # the control itself.
    assert acts["wipe_memory"]["handler"] == "navigate_only"
    assert acts["wipe_memory"]["destination"] == "ayma_settings"
    assert "clear_memory" in deny_keys
    # Founder-confirmed 2026-11-06 (19:41 PT): the three proposed
    # exclusions are wired the same way — each names a deny rule that
    # exists, and none of them is an account action.
    for item in app_registry.exclusions():
        assert set(item["deny_keys"]) <= deny_keys, item["key"]
    for key in ("block_report", "dismiss_all"):
        assert key in deny_keys
    # No server-side account handler may remain executable.
    assert {a["key"] for a in acts.values() if a["handler"] not in (
        "navigate_only", "client")} == set()


def test_exclusions_are_marked_excluded_in_the_graph():
    text = _graph_text()
    assert "EXCLUDED" in text
    for label in ("Delete account", "Clear Ayma memory"):
        assert label in text


def test_voice_clip_playback_registry_block_matches_the_command():
    block = app_registry.registry()["voice_clip_playback"]
    assert block["operated_by_ayma"] is True
    assert block["command"] == "play_voice_clip"
    assert block["client_action"] == "play_voice_clip"
    assert "play_voice_clip" in {s.name for s in app_control.COMMAND_SKILLS}


def test_persona_never_enumerates_the_exclusions():
    """Founder ruling, final form (2026-11-06): the forbidden buttons
    live in the config, NOT in Ayma's system instructions. The base
    prompt (both rendered variants) names none of them; it carries
    only the generic permitted-action-set line."""
    import prompt

    raw = prompt._PERSONA_PATH.read_text(encoding="utf-8")
    assert "user-only actions" not in raw
    assert "Actions that are never yours to take" not in raw
    for variant in ("text", "voice"):
        text = prompt.load_persona(variant)
        assert "permitted action set" in text, variant
        assert "Deleting their account" not in text, variant
        assert "Clearing your memory of them" not in text, variant
        assert "Paying for anything" not in text, variant


def test_exclusion_config_names_its_enforcement_surfaces():
    """The config is load-bearing: each item lists the account actions
    and deny rules it blocks, and the derived sets match the registry
    data they guard."""
    import app_registry as reg

    assert reg.excluded_account_action_keys() == {
        "delete_account", "wipe_memory"}
    assert reg.excluded_deny_keys() == {
        "delete", "purchase", "clear_memory", "block_report",
        "dismiss_all"}
    assert reg.excluded_destination_keys() == {"delete_account"}
    deny_keys = {
        r["key"] for r in reg.registry()["ui_action_policy"]["deny"]}
    assert reg.excluded_deny_keys() <= deny_keys
    acts = {a["key"]: a for a in reg.account_actions()}
    for key in reg.excluded_account_action_keys():
        assert acts[key]["handler"] == "navigate_only", key
