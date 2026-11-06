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


def test_delete_withdraw_purchase_and_clear_memory_are_navigate_only():
    acts = {a["key"]: a for a in app_registry.account_actions()}
    assert acts["delete_account"]["destination"] == "delete_account"
    assert acts["withdraw_consent"]["destination"] == "biometric_consent"
    # Clear memory joined the navigate-only set with the ACTION PARITY
    # exclusions config (founder, 2026-11-06): Ayma never wipes what she
    # has learned; she opens Ayma's settings and the user taps it.
    assert acts["wipe_memory"]["destination"] == "ayma_settings"
    for key in ("delete_account", "withdraw_consent", "wipe_memory"):
        assert acts[key]["handler"] == "navigate_only"
    assert {a["key"] for a in acts.values() if a["handler"] != "navigate_only"} == {
        "sign_out"
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


def test_story_edit_actions_resolve_uniquely_and_name_a_real_tool():
    import skills

    tools = {d["name"] for d in skills.session_tool_declarations()}
    seen: dict[str, str] = {}
    for a in app_registry.story_edit_actions():
        assert a["via"] in tools, f"story_edit_action {a['key']} -> unknown tool {a['via']}"
        for name in app_registry._names(a):
            owner = seen.setdefault(name, a["key"])
            assert owner == a["key"], f"'{name}' names both {owner} and {a['key']}"
        assert app_registry.find_story_edit_action(a["key"])["key"] == a["key"]


def test_story_edit_intent_routes_to_the_direct_tool_not_navigation():
    # A change/reword request -> edit_story_entry; a remove request ->
    # remove_story_entry. Never the Story page.
    for words in ("change my story", "fix my story", "reword my story section",
                  "edit my wiki"):
        a = app_registry.find_story_edit_action(words)
        assert a and a["via"] == "edit_story_entry", words
    for words in ("remove from my story", "take that off my story",
                  "delete my story section"):
        a = app_registry.find_story_edit_action(words)
        assert a and a["via"] == "remove_story_entry", words


def test_bare_open_my_story_is_still_a_navigation_not_an_edit():
    # Opening the story to look at it must NOT be captured as an edit intent.
    for words in ("open my story", "my story", "show me my story", "go to my story"):
        assert app_registry.find_story_edit_action(words) is None, words
        assert app_registry.find_destination(words)["key"] == "story", words


def test_model_selection_resolves_to_voice_preference():
    # Founder bug 2026-11-01: /settings/voice IS the model/brain picker
    # ("Ayma's models"), but its aliases omitted every word for the model
    # picker, so "open the model selection page" resolved to None and the
    # voice agent replied "no such page". Every model-picker phrasing must now
    # land on voice_preference (/settings/voice).
    for words in (
        "model selection", "models", "model", "brain", "ayma's models",
        "aymas models", "pick her brain", "her brain", "model stack",
        "change her brain", "the model selection page", "llm",
    ):
        d = app_registry.find_destination(words)
        assert d is not None, f"{words!r} -> None"
        assert d["key"] == "voice_preference", f"{words!r} -> {d['key']}"
        assert d["path"] == "/settings/voice", f"{words!r} -> {d}"


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


# --- resolution: no registration points nowhere --------------------------
#
# The other direction from ``test_every_router_route_is_registered...``: every
# registered destination must resolve BACK from the user's own words AND land
# on a route the router really has — so a dead/typo destination (a key or path
# that points nowhere) fails here, not silently at runtime as a "that page
# doesn't exist" to the user.

def test_every_destination_resolves_to_a_real_router_route():
    routes = _router_paths()
    for d in app_registry.destinations():
        path = d["path"].split("?")[0]
        assert path in routes, f"destination {d['key']} -> {path} is not a route"
        back = app_registry.find_destination(d["key"])
        assert back and back["key"] == d["key"], (
            f"destination {d['key']} doesn't resolve from its own key"
        )


def test_every_parameterized_route_names_a_real_route_and_a_tool():
    routes = _router_paths()
    import skills

    tools = {d["name"] for d in skills.session_tool_declarations()} | {
        s.name for s in skills.app_control.VOICE_SKILLS
    }
    for p in app_registry.registry()["parameterized"]:
        assert p["route"] in routes, f"parameterized {p['route']} is not a route"
        # ``via`` is free-form prose ("open_screen my_appearance") but must name
        # a tool the session actually exposes, so a typo can't orphan a route.
        assert any(t in p["via"] for t in tools), (
            f"parameterized {p['route']} via {p['via']!r} names no real tool"
        )


# --- imperative pushes: close the Navigator.push / MaterialPageRoute crack --
#
# The route-registration invariant above walks GoRoutes. A full screen pushed
# imperatively (``MaterialPageRoute(builder: (_) => XxxScreen())`` /
# ``Navigator.push`` / ``context.push`` of a widget) never appears as a
# GoRoute, so it could slip past unregistered — exactly how the date-sim /
# practice screens hid from Ayma. This enumerates every imperatively-pushed
# ``*Screen`` widget and requires each to be EITHER a registered route (it
# declares a ``static const path`` the registry knows) OR a listed sub-view
# with a reason below. A new imperative push of an unregistered screen fails.

# Sub-views and overlays that are intentionally NOT standalone routes: reached
# only from inside their parent screen's own flow, never navigable by Ayma.
_IMPERATIVE_SUBVIEWS = {
    "ManualProfileEditScreen": (
        "in-place profile editor pushed from My public profile; a sub-editor "
        "of that page, not a standalone route"
    ),
    "PracticeVoiceScreen": (
        "voice mode of a live Practice Date, pushed from the practice screen; "
        "part of that session, not a standalone page"
    ),
    "VoiceCallScreen": (
        "full-screen voice-call overlay pushed from the chat screen when a "
        "call starts; an overlay, not a navigable page"
    ),
}


def _imperatively_pushed_screens() -> set[str]:
    out: set[str] = set()
    for f in _SCREENS.parent.rglob("*.dart"):
        src = f.read_text(encoding="utf-8")
        out.update(
            re.findall(r"=>\s*(?:const\s+)?([A-Z]\w*Screen)\(", src)
        )
        out.update(
            re.findall(r"\.push(?:Named)?\(\s*(?:const\s+)?([A-Z]\w*Screen)\b", src)
        )
    return out


def test_imperative_pushes_target_registered_routes_or_listed_subviews():
    routes = _router_paths()
    paths_by_class = {
        name.split(".")[0]: path for name, path in _screen_paths().items()
    }
    pushed = _imperatively_pushed_screens()
    assert pushed, "the push scanner found nothing — the regex rotted"
    offenders = []
    for cls in sorted(pushed):
        if cls in _IMPERATIVE_SUBVIEWS:
            continue
        path = paths_by_class.get(cls)
        if path is None or path.split("?")[0] not in routes:
            offenders.append(cls)
    assert not offenders, (
        "screens pushed imperatively that are neither a registered route nor a "
        "listed sub-view — register them in app_registry.json or add a reason "
        f"to _IMPERATIVE_SUBVIEWS: {offenders}"
    )
    # Keep the allowlist honest: each entry is still pushed and still routeless.
    for cls in _IMPERATIVE_SUBVIEWS:
        assert cls in pushed, f"{cls} is no longer pushed; drop it from the list"
        assert cls not in paths_by_class, (
            f"{cls} now declares a route; register it instead of listing it"
        )


def test_guided_tour_resolves_from_the_users_own_words():
    # Antigravity review 2026-11-03: "open the tour" was denied as nonexistent
    # even though the guided_tour block exists — the overlay-only tour has no
    # route, so it can't be a destination/non_navigable (both are validated
    # against the router); instead its own key/label/aliases resolve it.
    for words in (
        "tour", "open the tour", "guided tour", "app tour",
        "tour of the app", "walkthrough", "app walkthrough",
        "walk me through the app", "give me a tour", "show me around",
    ):
        entry = app_registry.find_guided_tour(words)
        assert entry is not None, f"{words!r} -> None"
        assert entry["key"] == "guided_tour", f"{words!r} -> {entry}"
        assert entry.get("steps"), f"{words!r} -> entry has no steps"


def test_open_tour_redirects_to_the_tour_skill_instead_of_denying_it():
    # "Open the tour" is not a page — but it must redirect to the tour skill,
    # never the "doesn't exist" denial.
    from skills import app_control_navigation as nav

    msg = nav._not_a_page("open the tour")
    assert "start_guided_tour" in msg, msg
    assert "doesn't exist" not in msg, msg


def test_models_page_resolves_distinctly_not_to_generic_settings():
    # Founder bug 2026-11-02: "open my models" opened the generic Settings page;
    # STT also garbles "Ayma's" to AMS/iMAS. Every natural phrasing (and the
    # garbles) must land on voice_preference, never settings/ayma_settings.
    for words in (
        "my models", "the models page", "models", "models page", "models screen",
        "your models", "ayma's models", "aymas models", "ayma models",
        "ams models", "imas models", "open my models", "the models",
        "change your brain", "switch your brain", "your brain", "voice mode",
    ):
        d = app_registry.find_destination(words)
        assert d and d["key"] == "voice_preference", f"{words!r} -> {d}"
