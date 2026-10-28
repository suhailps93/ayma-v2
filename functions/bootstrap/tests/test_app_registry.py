"""``app_registry.json`` is the single source of truth for what Ayma can open
and change. These checks fail when a GoRoute in the app's router is neither a
registered destination nor listed (with a reason) as parameterized or
non-navigable, so a new screen can't silently be unreachable by voice/chat."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

import app_registry
from notifications_schema import NOTIFICATION_TYPES

_REPO = Path(__file__).resolve().parents[3]
_ROUTER = _REPO / "ayma_flutter" / "lib" / "routing" / "app_router.dart"
_SCREENS = _REPO / "ayma_flutter" / "lib" / "screens"


def _screen_paths() -> dict[str, str]:
    """``{"XScreen.path": "/x", ...}`` from every ``static const`` path."""
    out: dict[str, str] = {}
    for f in _SCREENS.parent.rglob("*.dart"):
        current = ""
        for line in f.read_text(encoding="utf-8").splitlines():
            m = re.match(r"\s*class (\w+)\b", line)
            if m:
                current = m.group(1)
            m = re.search(r"static const (\w*[pP]ath) = '([^']+)'", line)
            if m and current:
                out[f"{current}.{m.group(1)}"] = m.group(2)
    return out


def _router_paths() -> set[str]:
    if not _ROUTER.exists():
        pytest.skip("Flutter app not checked out next to the backend")
    src = _ROUTER.read_text(encoding="utf-8")
    consts = _screen_paths()
    paths: set[str] = set()
    for expr in re.findall(r"\bpath:\s*([\w.]+|'[^']+')", src):
        if expr.startswith("'"):
            paths.add(expr.strip("'"))
        elif expr != "legacy":  # the legacy-redirect loop, parsed below
            assert expr in consts, f"can't resolve route path {expr}"
            paths.add(consts[expr])
    legacy = re.search(r"for \(final legacy in const \[(.*?)\]\)", src, re.S)
    if legacy:
        paths.update(re.findall(r"'([^']+)'", legacy.group(1)))
    return paths


def _registered_routes() -> dict[str, str]:
    reg = app_registry.registry()
    out = {}
    for d in reg["destinations"]:
        out.setdefault(d["path"].split("?")[0], f"destination {d['key']}")
    for p in reg["parameterized"]:
        assert p["reason"] and p["via"], p
        out[p["route"]] = "parameterized"
    for n in reg["non_navigable"]:
        assert n["reason"].strip(), n
        out[n["route"]] = "non_navigable"
    return out


def test_every_router_route_is_registered_or_explicitly_excluded():
    routes = _router_paths()
    assert len(routes) > 30  # the parser really found the router's routes
    known = _registered_routes()
    missing = sorted(routes - set(known))
    assert not missing, (
        "routes missing from functions/bootstrap/app_registry.json "
        f"(add a destination, or a non_navigable entry with a reason): {missing}"
    )


def test_every_registered_route_still_exists_in_the_router():
    routes = _router_paths()
    stale = sorted(set(_registered_routes()) - routes)
    assert not stale, f"registry routes no longer in app_router.dart: {stale}"


def test_destination_keys_and_aliases_are_unambiguous():
    seen: dict[str, str] = {}
    for d in app_registry.destinations():
        for name in app_registry._names(d):
            owner = seen.setdefault(name, d["key"])
            assert owner == d["key"], f"'{name}' names both {owner} and {d['key']}"
        assert app_registry.find_destination(d["key"]) is d or (
            app_registry.find_destination(d["key"])["key"] == d["key"]
        )


def test_notification_settings_cover_every_category():
    cats = {
        s["category"] for s in app_registry.settings()
        if s["handler"] == "notification_pref"
    }
    assert set(NOTIFICATION_TYPES) | {"*"} == cats


def test_settings_and_actions_are_complete():
    for s in app_registry.settings():
        assert s["kind"] in {"bool", "enum", "hex", "age_range", "tool"}, s
        if s["handler"] == "client":
            assert s["client_command"], s
        if s["kind"] == "enum":
            assert s["values"], s
    for a in app_registry.account_actions():
        if a["handler"] == "navigate_only":
            # Never executed by a tool: only opens the page, with a kind line.
            assert app_registry.find_destination(a["destination"]), a
            assert a["say"].strip() and "confirm_phrase" not in a, a
            continue
        assert a["confirm_phrase"].startswith("yes"), a
        assert a["question"].endswith(("?", ".")), a


def test_delete_withdraw_and_purchase_are_navigate_only():
    acts = {a["key"]: a for a in app_registry.account_actions()}
    assert acts["delete_account"]["destination"] == "delete_account"
    assert acts["withdraw_consent"]["destination"] == "biometric_consent"
    for key in ("delete_account", "withdraw_consent"):
        assert acts[key]["handler"] == "navigate_only"
    assert {a["key"] for a in acts.values() if a["handler"] != "navigate_only"} == {
        "sign_out", "wipe_memory"
    }
    purchase = next(u for u in app_registry.unavailable() if u["key"] == "purchase")
    assert purchase["navigate"] == "credits"


def test_every_router_route_sends_screen_context_or_has_a_reason():
    """The app captures every route's screen context generically; a route may
    only opt out with a reason, and only routes the router really has."""
    routes = _router_paths()
    opted_out = app_registry.no_context_routes()
    assert all(r.strip() for r in opted_out.values()), opted_out
    assert set(opted_out) <= routes, set(opted_out) - routes
    for route in routes - set(opted_out):
        assert app_registry.route_name(route), (
            f"{route} sends screen context but the registry can't name it"
        )


@pytest.mark.parametrize("label,ctype,route,dialog", [
    ("Delete account", "button", "/settings", ""),
    ("Delete photo", "button", "/profile/me/public", ""),
    ("Withdraw consent", "button", "/settings/biometric-consent", ""),
    ("Upgrade to Pro", "button", "/profile/plan", ""),
    ("Switch to Plus", "button", "/profile/plan", ""),
    ("Start free trial", "button", "/profile/plan", ""),
    ("Subscribe", "button", "/profile/usage/trial", ""),
    ("$9.99 / month", "item", "/profile/plan", ""),
    ("I agree", "button", "/consent", ""),
    ("Continue", "button", "/consent", ""),
    ("I accept the Terms", "checkbox", "/preboarding", ""),
    ("Password", "field", "/settings", ""),
    ("Verification code", "field", "/signin", ""),
    ("Card number", "field", "/profile/plan", ""),
    ("Confirm", "button", "/settings", "Delete your account? This can't be undone."),
    ("Sign out", "button", "/profile", ""),
])
def test_ui_denial_blocks_the_denylist(label, ctype, route, dialog):
    assert app_registry.ui_denial(label, ctype, route, dialog), label


@pytest.mark.parametrize("label,ctype,route,dialog", [
    ("Dark mode", "switch", "/settings", ""),
    ("Pause matching", "switch", "/settings", ""),
    ("Hiking", "item", "/explore", ""),
    ("First name", "field", "/settings/profile", ""),
    ("Max", "tab", "/profile/plan", ""),
    ("Restore purchases", "button", "/profile/plan", ""),
    ("Manage in store", "button", "/profile/plan", ""),
    ("Cancel", "button", "/settings", "Delete your account?"),
    ("Back", "button", "/settings/delete-account", ""),
    ("Direct messages", "switch", "/notifications/prefs", ""),
    # The quiet chip's Unmute control is not a delete/purchase/consent control.
    ("Unmute Ayma", "button", "/home", ""),
    ("Ayma is quiet, double tap to unmute", "button", "/home", ""),
])
def test_ui_denial_allows_everything_else(label, ctype, route, dialog):
    assert app_registry.ui_denial(label, ctype, route, dialog) is None, label


def test_appearance_report_destination_is_deterministic():
    # Founder bug 2026-10-27: "open the appearance report" misrouted to
    # Notifications then Chat. Every natural phrasing must land on exactly one
    # key, my_appearance — never Notifications, Chat or anything else.
    for words in (
        "appearance report", "the appearance report", "my appearance",
        "looks report", "my looks report", "report card", "my report card",
        "face report", "body report", "share my appearance report",
    ):
        d = app_registry.find_destination(words)
        assert d and d["key"] == "my_appearance", f"{words!r} -> {d}"


def test_open_screen_description_lists_each_key_with_its_label():
    # The model reads this; bare keys left "appearance report" under-determined.
    from skills import app_control

    desc = app_control._OPEN_SCREEN["description"]
    for d in app_registry.destinations():
        assert f"{d['key']} ({d['label']})" in desc, d["key"]


def test_report_actions_resolve_uniquely_and_name_a_real_tool():
    import skills

    tools = {d["name"] for d in skills.session_tool_declarations()} | {
        s.name for s in skills.app_control.VOICE_SKILLS
    }
    seen: dict[str, str] = {}
    for a in app_registry.report_actions():
        assert a["via"] in tools, f"report_action {a['key']} -> unknown tool {a['via']}"
        for name in app_registry._names(a):
            owner = seen.setdefault(name, a["key"])
            assert owner == a["key"], f"'{name}' names both {owner} and {a['key']}"
        assert app_registry.find_report_action(a["key"])["key"] == a["key"]


def test_rerun_appearance_resolves_to_the_run_tool():
    for words in ("rerun appearance report", "regenerate appearance report",
                  "recalculate appearance report", "run my appearance report again"):
        a = app_registry.find_report_action(words)
        assert a and a["key"] == "rerun_appearance" and a["via"] == "run_appearance_report", words


def test_profile_completeness_card_resolves_to_complete_profile():
    for words in ("profile completeness", "Your profile is 59% complete"):
        assert app_registry.find_destination(words)["key"] == "complete_profile"
    assert "the 'Your profile is N% complete' card at the top" in (
        app_registry.found_on("profile")
    )


def test_tool_descriptions_list_the_registry():
    from skills import app_control

    screen_desc = app_control._OPEN_SCREEN["description"]
    for d in app_registry.destinations():
        assert d["key"] in screen_desc
    action_desc = app_control._APP_ACTION["description"]
    for s in app_registry.settings():
        assert (s["key"] if s["handler"] != "tool" else s["via"]) in action_desc
    acct_desc = app_control._ACCOUNT_ACTION["description"]
    for a in app_registry.account_actions():
        assert a["key"] in acct_desc
    for desc in (screen_desc, action_desc, acct_desc):
        assert "{{" not in desc
