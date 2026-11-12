"""App-control settings: the ``app_action`` tool changes any registered setting.

Server-held settings are written where their screen saves them; client-held
settings go out as one UI command. Split out of ``skills/app_control.py``
(Tier-2 sweep item #8).
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from typing import Callable

import app_registry

from .app_control_navigation import (
    _navigate_only,
    _run_report_action,
    _unavailable_reply,
)
from .app_control_queue import (
    _await_ack,
    _NOT_APPLIED,
    _prompt,
    _queue_command,
)

logger = logging.getLogger("ayma.app_control")

# The earlier one-word action names, still accepted (and still the exact
# client command names, so an older app build keeps working): each maps to a
# registry setting and value.
_LEGACY_ACTIONS = {
    "dark_mode": ("theme", "dark"),
    "light_mode": ("theme", "light"),
    "system_theme": ("theme", "system"),
    "pause_matching": ("pause_matching", "on"),
    "resume_matching": ("pause_matching", "off"),
}

_ON = frozenset("on true yes enable enabled show unmute start 1".split())
_OFF = frozenset("off false no disable disabled hide mute stop 0".split())


# The app's default accent, reported as the current accent until the user has
# picked one. Mirrors ``AymaColors.accent`` in ayma_flutter/lib/theme.dart (the
# single source of truth); test_default_accent_matches_flutter_theme fails if
# the two diverge.
_DEFAULT_ACCENT = "#DA4B65"
_DEFAULT_ACCENT_NAME = "Cherry Fuchsia"
_ACCENT_RESET_WORDS = frozenset(
    "default reset original standard factory cherry fuchsia".split()
)
# What the app receives to reset: it runs the Accent Color screen's own
# "Reset to default" action, so the hex is never duplicated client-side.
_ACCENT_RESET_VALUE = "default"

_HEX_DIGITS = frozenset("0123456789abcdef")


def _resolve_accent(value: str) -> str | None:
    """Normalised ``#RRGGBB`` for a valid hex, else ``None``. Any colour is
    accepted exactly as given, with no snapping to a preset; Ayma translates
    names and descriptions into a hex herself."""
    raw = value.strip().lstrip("#").lower()
    if len(raw) == 6 and set(raw) <= _HEX_DIGITS:
        return "#" + raw.upper()
    return None


def _current_accent(db, uid: str) -> str:
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
        )
        data = snap.to_dict() if snap.exists else None
    except Exception:
        data = None
    hexcode = _resolve_accent(str((data or {}).get("ayma_accent_color") or ""))
    return hexcode or _DEFAULT_ACCENT


# How long the accent change path keeps re-reading the saved accent after
# the client's ack was lost, waiting to see whether the change landed
# anyway. The client applies a queued command the moment it sees it, but
# the ack can be missed (backgrounded app, stream hiccup) while the change
# itself — and its Firestore mirror — still goes through; the founder
# incident (2026-11-07) was exactly that shape: failure reported for a
# change that HAD applied, and the default colour asserted as current
# ever after. Module-level so tests can shrink them.
_ACCENT_CONFIRM_SECONDS = 1.5
_ACCENT_CONFIRM_POLL_SECONDS = 0.25


def accent_color_context(db, uid: str) -> str:
    """One labeled live fact for the system prompt: the app's CURRENT
    accent colour, read fresh from the saved profile — the same read
    ``get_accent_color`` reports. The persona and the ``app_action``
    description name only the DEFAULT (Cherry Fuchsia); with no current
    value standing in context, the model mistook the default for the
    current colour and asserted it even right after changing it
    (founder feedback, 2026-11-07). Never raises: ``_current_accent``
    already falls back to the default on a failed read."""
    if not uid:
        return ""
    current = _current_accent(db, uid)
    if current == _DEFAULT_ACCENT:
        now = f"currently {_DEFAULT_ACCENT_NAME} ({_DEFAULT_ACCENT}), the default"
    else:
        now = (
            f"currently {current} — changed from the default "
            f"({_DEFAULT_ACCENT_NAME} {_DEFAULT_ACCENT})"
        )
    return (
        "App accent colour: " + now + ". If you mention the accent "
        "colour, use the current value; the default is only the factory "
        "colour, never the current one unless it is the value above."
    )


async def _accent_after_missed_ack(
    db, uid: str, *, expected: str, before: str
) -> str:
    """The truthful result of an accent-colour change whose ack never
    confirmed it. Re-reads the SAVED accent briefly: if it moved to
    ``expected``, the change landed despite the lost ack and is reported
    as done (the exact words a confirmed change gets); if it already WAS
    ``expected``, the state is reported without claiming a change; only
    when the saved value never moved is the change honestly reported as
    not applied. A success or failure claim about the accent therefore
    always rests on the ack or on the saved value — never on neither."""
    deadline = time.monotonic() + _ACCENT_CONFIRM_SECONDS
    stored = await asyncio.to_thread(_current_accent, db, uid)
    while stored != expected and time.monotonic() < deadline:
        await asyncio.sleep(_ACCENT_CONFIRM_POLL_SECONDS)
        stored = await asyncio.to_thread(_current_accent, db, uid)
    if stored != expected:
        return _NOT_APPLIED
    if stored == before:
        return f"The app's accent colour is {expected}."
    if expected == _DEFAULT_ACCENT:
        return (
            "Reset the app's accent colour to the default, "
            f"{_DEFAULT_ACCENT_NAME} ({_DEFAULT_ACCENT})."
        )
    return f"Changed the app's accent colour to {expected}."


def _normalise_value(setting: dict, value: str) -> str | None:
    """The canonical value for ``setting`` (``on``/``off``, an enum member, a
    ``#RRGGBB`` hex, ``"min-max"``), or ``None`` when ``value`` isn't one."""
    kind = setting["kind"]
    v = value.strip().lower()
    if kind == "bool":
        return "on" if v in _ON else "off" if v in _OFF else None
    if kind == "hex":
        if v in _ACCENT_RESET_WORDS or v.replace("-", " ").replace("_", " ") in (
            "cherry fuchsia", "reset to default", "default colour",
            "default color",
        ):
            return _ACCENT_RESET_VALUE
        return _resolve_accent(value)
    if kind == "enum":
        v = re.sub(r"\s*(miles?|mi)\b", "", v).strip()
        v = {"auto": "system", "match system": "system", "any": "anywhere",
             "anywhere is fine": "anywhere"}.get(v, v)
        return v if v in setting["values"] else None
    if kind == "age_range":
        nums = [int(n) for n in re.findall(r"\d+", v)]
        return f"{nums[0]}-{nums[1]}" if len(nums) == 2 else None
    return None


def _apply_server_setting(db, uid: str, setting: dict, value: str) -> str:
    """Write a server-held setting exactly where its screen saves it. Returns
    the confirmation, or raises ``ValueError`` with a user-facing reason."""
    handler = setting["handler"]
    if handler == "notification_pref":
        import notifications_ops
        from notifications_schema import NOTIFICATION_TYPES

        cats = (
            NOTIFICATION_TYPES if setting["category"] == "*"
            else (setting["category"],)
        )
        for cat in cats:
            notifications_ops.set_pref(db, uid, cat, value == "on")
        return f"Done: {setting['label']} turned {value}."
    from . import questionnaire

    if handler == "partner_age_range":
        lo, hi = (int(n) for n in value.split("-"))
        questionnaire.save_partner_preferences(db, uid, age_min=lo, age_max=hi)
        return f"Done: partner age range set to {lo}-{hi}."
    if handler == "distance_pref":
        questionnaire.save_partner_preferences(db, uid, distance_pref=value)
        shown = "anywhere" if value == "anywhere" else f"{value} miles"
        return f"Done: distance preference set to {shown}."
    raise ValueError(f"no handler for {setting['key']}")


def _setting_line(s: dict) -> str:
    if s["kind"] == "enum":
        return f"{s['key']} ({'|'.join(s['values'])})"
    if s["kind"] == "hex":
        return f"{s['key']} (#RRGGBB)"
    if s["kind"] == "age_range":
        return f"{s['key']} (min-max, 18+)"
    return f"{s['key']} (on|off)"


def _bind_app_action(db, uid: str) -> Callable[..., str]:
    async def app_action(action: str = "", value: str = "") -> str:
        a = action.strip().lower()
        if a == "get_accent_color":
            return (
                f"The app's current accent colour is {_current_accent(db, uid)}. "
                f"The default accent is {_DEFAULT_ACCENT_NAME} "
                f"({_DEFAULT_ACCENT}); app_action accent_color with value "
                "'default' resets to it. Report the current colour above — "
                "the default is only the factory colour, never describe it "
                "as the current colour."
            )
        if a in _LEGACY_ACTIONS and (
            not value.strip() or a != _LEGACY_ACTIONS[a][0]
        ):
            a, value = _LEGACY_ACTIONS[a]
        gone = app_registry.find_unavailable(a, exact=True)
        if gone:
            return await _unavailable_reply(db, uid, gone)
        setting = app_registry.find_setting(a)
        if setting is None:
            report = app_registry.find_report_action(a)
            if report:
                # A re-run request routed here instead of to the tool: run it
                # ourselves (don't deflect) so the user gets the refreshed
                # report, not a pointer. The raw phrasing carries a match
                # report's "with X" partner.
                return await _run_report_action(db, uid, report, action.strip())
            act = app_registry.find_account_action(a)
            if act and act["handler"] == "navigate_only":
                return await _navigate_only(db, uid, act["destination"], act["say"])
            if act:
                return (
                    f"'{action.strip()}' is a destructive action — use "
                    f"account_action {act['key']}, which asks the user to "
                    "confirm first."
                )
            gone = app_registry.find_unavailable(a)
            if gone:
                return await _unavailable_reply(db, uid, gone)
            return (
                f"There is no '{action.strip()}' setting in the app — tell the "
                "user plainly. Settings that exist: "
                + ", ".join(s["key"] for s in app_registry.settings())
                + ", plus get_accent_color."
            )
        if setting["handler"] == "tool":
            return f"Use {setting['via']} for that ({setting['label']})."
        v = _normalise_value(setting, value)
        if v is None:
            if setting["kind"] == "hex":
                return (
                    f"'{value.strip()}' is not a valid colour. Pass any colour "
                    "as a #RRGGBB hex."
                )
            allowed = {
                "bool": "on or off",
                "age_range": "two ages like 25-35",
            }.get(setting["kind"], " / ".join(setting.get("values") or []))
            return f"'{value.strip()}' isn't a value for {setting['key']}: use {allowed}."
        if setting["handler"] != "client":
            try:
                return await asyncio.to_thread(
                    _apply_server_setting, db, uid, setting, v
                )
            except ValueError as exc:
                return f"Couldn't change that: {exc}."
            except Exception:  # noqa: BLE001
                logger.exception("setting %s failed for %s", setting["key"], uid)
                return _NOT_APPLIED
        command = setting["client_command"]
        payload = (
            {"action": "app_action", "name": command[v]}
            if isinstance(command, dict)
            else {"action": "app_action", "name": command, "value": v}
        )
        if setting["kind"] == "hex":
            # Accent colour: capture the saved value BEFORE queueing, so a
            # lost ack can be reconciled against it (see
            # _accent_after_missed_ack) instead of being reported as a
            # failure for a change that may have landed.
            before = await asyncio.to_thread(_current_accent, db, uid)
            cmd_id = _queue_command(db, uid, payload)
            ack = await _await_ack(db, uid, cmd_id)
            if not (ack and ack.get("ok")):
                return await _accent_after_missed_ack(
                    db,
                    uid,
                    expected=(
                        _DEFAULT_ACCENT if v == _ACCENT_RESET_VALUE else v
                    ),
                    before=before,
                )
            if v == _ACCENT_RESET_VALUE:
                return (
                    "Reset the app's accent colour to the default, "
                    f"{_DEFAULT_ACCENT_NAME} ({_DEFAULT_ACCENT})."
                )
            return f"Changed the app's accent colour to {v}."
        cmd_id = _queue_command(db, uid, payload)
        ack = await _await_ack(db, uid, cmd_id)
        if not (ack and ack.get("ok")):
            return _NOT_APPLIED
        done = (setting.get("done") or {}).get(v)
        return done or f"Done: {setting['label']} turned {v}."

    return app_action


_APP_ACTION = {
    "name": "app_action",
    "description": _prompt(
        "app_control_app_action",
        SETTINGS=", ".join(
            _setting_line(s) for s in app_registry.settings()
            if s["handler"] != "tool"
        ),
        VIA_TOOLS="; ".join(
            f"{s['via']}: {s['label']}" for s in app_registry.settings()
            if s["handler"] == "tool"
        ),
    ),
    "parameters": {
        "type": "object",
        "properties": {"action": {"type": "string"}, "value": {"type": "string"}},
        "required": ["action"],
    },
}
