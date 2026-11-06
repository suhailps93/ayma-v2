"""The app-control registry: every page Ayma can open and every setting she can
change, loaded from ``app_registry.json`` (the single source of truth).

``skills/app_control.py`` builds its tool descriptions and validation from
this; the Flutter client navigates to the ``path`` each command carries, and
two tests (``tests/test_app_registry.py`` here, ``test/app_registry_test.dart``
in the app) fail when a GoRoute in ``app_router.dart`` is neither registered
nor listed as non-navigable with a reason.

Lookups accept the user's own words: a key, a label, or any alias, matched
after :func:`normalise` (lowercase, punctuation and filler words such as
"my", "the", "page", "screen", "card" removed).
"""

from __future__ import annotations

import functools
import json
import re
from pathlib import Path

_PATH = Path(__file__).with_name("app_registry.json")

# Words that carry no meaning in "open my profile completeness card please".
_FILLER = frozenset(
    "a an the my me your our to of for please open show go take "
    "page pages screen screens tab card section view".split()
)


@functools.lru_cache(maxsize=1)
def registry() -> dict:
    return json.loads(_PATH.read_text(encoding="utf-8"))


def destinations() -> list[dict]:
    return list(registry()["destinations"])


def settings() -> list[dict]:
    return list(registry()["settings"])


def account_actions() -> list[dict]:
    return list(registry()["account_actions"])


def report_actions() -> list[dict]:
    """Reports Ayma can run or re-run (Appearance, web research). Not pages or
    settings: each ``via`` names the chat/voice tool that actually runs it."""
    return list(registry().get("report_actions") or [])


def story_edit_actions() -> list[dict]:
    """Direct story/wiki edit + soft-remove actions Ayma does herself. Not
    pages: each ``via`` names the chat/voice tool that actually does it
    (``edit_story_entry`` / ``remove_story_entry``), so a "change/remove X from
    my story" request never navigates into the Story editor's passage popup."""
    return list(registry().get("story_edit_actions") or [])


def unavailable() -> list[dict]:
    return list(registry()["unavailable"])


def exclusions() -> list[dict]:
    """The ACTION PARITY exclusion config (founder, 2026-11-06): the
    controls Ayma must never activate (delete account, any purchase,
    clear memory). Enforcement lives in the command layer — the
    ``ui_action_policy`` deny rules and the navigate-only handlers named
    in each item's ``via`` — never in the system prompt. Returns the
    ``items`` list (empty when the registry predates the block)."""
    block = registry().get("exclusions") or {}
    return list(block.get("items") or [])


def exclusion_keys() -> set[str]:
    return {str(e.get("key") or "") for e in exclusions()}


def guided_tour() -> dict:
    """The Ayma-driven interactive tour config (ARCHITECTURE §11.2b): its
    metadata and the ordered ``steps`` Ayma narrates. Empty dict when the
    registry predates the feature (tolerant read)."""
    return dict(registry().get("guided_tour") or {})


def guided_tour_steps() -> list[dict]:
    """The predefined, ordered tour steps — each ``{anchor, tab?, headline,
    say}`` (``anchor`` a tour_anchors id, ``tab`` the shell tab or absent for a
    nav-bar anchor). The single source of truth for the driven tour's order and
    copy; ``skills/guided_tour.py`` reads it."""
    return list(guided_tour().get("steps") or [])


def navigation_actions() -> list[str]:
    """The session navigation actions Ayma can run (feedback item 15) —
    currently just ``go_back``. The client keeps the history itself
    (session-only, capped); this names the action for the graph/tests.
    Tolerant read, like :func:`guided_tour`."""
    nav = registry().get("navigation") or {}
    return list(nav.get("actions") or [])


def find_guided_tour(text: str) -> dict | None:
    """The driven-tour entry when ``text`` names the guided walkthrough in the
    user's own words ("open the tour", "walk me through the app", …), else
    ``None``. The tour is overlay-only — no route, so no destination entry —
    and ``open_screen`` redirects a match to the ``start_guided_tour`` skill
    instead of denying it (Antigravity review 2026-11-03)."""
    entry = guided_tour()
    if not entry or not entry.get("aliases"):
        return None
    return _lookup([entry], text)


def normalise(text: str) -> str:
    """Lowercase words with filler and numbers dropped, so the card's own
    text ("Your profile is 59% complete") matches its alias."""
    words = re.sub(r"[^a-z0-9]+", " ", text.lower().replace("'", "")).split()
    return " ".join(w for w in words if w not in _FILLER and not w.isdigit())


def _names(entry: dict) -> list[str]:
    names = [entry["key"], entry["key"].replace("_", " ")]
    if entry.get("label"):
        names.append(entry["label"])
    names.extend(entry.get("aliases") or [])
    return [n for n in (normalise(x) for x in names) if n]


def _lookup(entries: list[dict], text: str, exact: bool = False) -> dict | None:
    """Exact key/label/alias match first; otherwise (unless ``exact``) the
    entry whose longest name is contained in the request (or contains it), so
    "open the profile completeness card" finds ``complete_profile``. ``None``
    when nothing fits."""
    want = normalise(text)
    if not want:
        return None
    raw = text.strip().lower()
    for e in entries:
        if raw == e["key"] or want in _names(e):
            return e
    if exact:
        return None
    best: tuple[int, dict] | None = None
    for e in entries:
        for n in _names(e):
            if len(n) < 4:
                continue
            if re.search(rf"\b{re.escape(n)}\b", want) or (
                len(want) >= 6 and re.search(rf"\b{re.escape(want)}\b", n)
            ):
                if best is None or len(n) > best[0]:
                    best = (len(n), e)
    return best[1] if best else None


def find_destination(text: str) -> dict | None:
    """An exact destination name wins; then an exact known-unavailable name
    ("google account") blocks a looser destination match ("account")."""
    exact = _lookup(destinations(), text, exact=True)
    if exact or find_unavailable(text, exact=True):
        return exact
    return _lookup(destinations(), text)


def find_setting(text: str) -> dict | None:
    return _lookup(settings(), text)


def find_account_action(text: str) -> dict | None:
    return _lookup(account_actions(), text)


def find_report_action(text: str) -> dict | None:
    """The report-run action an *explicit re-run* request names ("rerun /
    regenerate / recalculate the appearance report"), or ``None``.

    Matched strictly, by an exact name or a full re-run alias contained in the
    request — never the reverse (a bare "appearance report" is an *open*, not a
    re-run, so it must not match here and steal the navigation). Every alias
    carries its own re-run verb, so forward containment already encodes "this
    is a re-run". The app-driving path uses the match to actually run the report
    (``skills.app_control._run_report_action``), via the tool named in ``via``."""
    want = normalise(text)
    if not want:
        return None
    raw = text.strip().lower()
    for e in report_actions():
        if raw == e["key"] or want in _names(e):
            return e
    best: tuple[int, dict] | None = None
    for e in report_actions():
        for n in _names(e):
            if len(n) < 4:
                continue
            if re.search(rf"\b{re.escape(n)}\b", want):
                if best is None or len(n) > best[0]:
                    best = (len(n), e)
    return best[1] if best else None


def find_story_edit_action(text: str) -> dict | None:
    """The direct story-edit/remove action a "change / fix / reword / remove /
    delete … my story" request names, or ``None``.

    Matched strictly — like :func:`find_report_action` — by an exact name or a
    full alias contained in the request, never the reverse. Every alias carries
    its own edit/remove verb ("change my story", "remove from my story"), so a
    bare "open my story" / "my story" (an *open*) never matches and still
    navigates. The app-driving path uses the match to route to the direct tool
    named in ``via`` instead of opening the Story editor's passage popup."""
    want = normalise(text)
    if not want:
        return None
    raw = text.strip().lower()
    for e in story_edit_actions():
        if raw == e["key"] or want in _names(e):
            return e
    best: tuple[int, dict] | None = None
    for e in story_edit_actions():
        for n in _names(e):
            if len(n) < 4:
                continue
            if re.search(rf"\b{re.escape(n)}\b", want):
                if best is None or len(n) > best[0]:
                    best = (len(n), e)
    return best[1] if best else None


def find_unavailable(text: str, exact: bool = False) -> dict | None:
    return _lookup(unavailable(), text, exact)


def found_on(screen_key: str) -> list[str]:
    """Labels of everything that sits on one screen, for screen context."""
    out = []
    for group in (destinations(), settings(), account_actions()):
        for e in group:
            if e.get("found_on") == screen_key:
                out.append(e.get("on_screen") or e["label"])
    return out


def no_context_routes() -> dict[str, str]:
    """``{route: reason}`` for the routes that send no screen context."""
    return {
        n["route"]: n["reason"] for n in registry()["screen_context"]["no_context"]
    }


def destination_for_route(route: str) -> dict | None:
    r = route.strip().split("?")[0]
    for d in destinations():
        if d["path"].split("?")[0] == r:
            return d
    return None


def route_name(route: str) -> str:
    """A human name for a route pattern ("/settings" -> "Settings"), from
    the destination label or the parameterized/non-navigable reason; ``""``
    when the registry doesn't know it."""
    r = route.strip().split("?")[0]
    if not r:
        return ""
    dest = destination_for_route(r)
    if dest:
        return dest["label"]
    for entry in registry()["parameterized"] + registry()["non_navigable"]:
        if entry["route"] == r:
            return entry["reason"]
    return ""


def ui_policy() -> dict:
    return dict(registry()["ui_action_policy"])


def ui_denial(
    label: str, control_type: str = "", route: str = "", dialog_text: str = ""
) -> dict | None:
    """The ``ui_action_policy`` rule that forbids operating this control, as
    ``{"key", "say"}``, or ``None`` when Ayma may operate it. Mirrors the app
    executor's check (``screen_capture.dart`` ``uiDenial``)."""
    policy = ui_policy()
    text = " ".join(label.split()).strip()
    escape = re.fullmatch(policy["escape_pattern"], text, re.IGNORECASE)
    r = route.strip().split("?")[0]
    if not escape:
        for d in policy["deny_routes"]:
            if d["route"] == r:
                return {"key": "route", "say": f"Not on this page: {d['reason']}."}
        for rule in policy["deny"]:
            if dialog_text and not (rule.get("types") or rule.get("routes")) and (
                re.search(rule["pattern"], dialog_text, re.IGNORECASE)
            ):
                return {"key": rule["key"], "say": rule["say"]}
    for rule in policy["deny"]:
        if rule.get("routes") and r not in rule["routes"]:
            continue
        if rule.get("types") and control_type not in rule["types"]:
            continue
        if re.search(rule["pattern"], text, re.IGNORECASE):
            return {"key": rule["key"], "say": rule["say"]}
    if control_type == "field" and re.search(
        policy["secret_field_pattern"], text, re.IGNORECASE
    ):
        return {"key": "secret_field", "say": policy["secret_field_say"]}
    return None
