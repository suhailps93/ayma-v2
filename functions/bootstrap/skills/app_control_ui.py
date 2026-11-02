"""App-control UI actions: ``ui_action`` operates any visible control.

Tap, toggle, pick, slide, type, scroll or back by the id the live screen
capture gave it — except what the registry's ``ui_action_policy`` denies
(checked here on the label and again by the app on the real control). Split
out of ``skills/app_control.py`` (Tier-2 sweep item #8).
"""

from __future__ import annotations

import asyncio
import re
from typing import Callable

import app_registry

from .app_control_mirror import _mirrored_route, _VISIBLE_MAX_CHARS
from .app_control_queue import (
    _await_ack,
    _NOT_APPLIED,
    _prompt,
    _queue_command,
)

# What ui_action accepts, and the control type each id prefix means (the
# app's ScreenCapture numbers controls as <prefix><n>, e.g. "s3").
_UI_OPS = frozenset(
    "tap long_press set_text increase decrease scroll_up scroll_down "
    "scroll_to_top scroll_to_bottom dismiss back".split()
)
_UI_ID_TYPES = {
    "b": "button", "s": "switch", "c": "checkbox", "r": "radio", "f": "field",
    "v": "slider", "l": "list", "k": "link", "t": "tab", "i": "item",
}
_UI_ID = re.compile(r"^([a-z])(\d{1,4})$")


def _bind_ui_action(db, uid: str) -> Callable[..., str]:
    async def ui_action(
        control: str = "", label: str = "", action: str = "tap", value: str = ""
    ) -> str:
        op = (action.strip().lower() or "tap").replace(" ", "_")
        if op not in _UI_OPS:
            return (
                f"'{action.strip()}' isn't a ui_action. Use one of: "
                + ", ".join(sorted(_UI_OPS)) + "."
            )
        cid = control.strip().strip("[]").lower()
        m = _UI_ID.match(cid)
        needs_control = op != "back" and not (op.startswith("scroll") and not cid)
        if needs_control and (not m or not label.strip()):
            return (
                "Pass the control's [id] and its exact label from the screen "
                "context (in a call, call current_screen first)."
            )
        ctype = _UI_ID_TYPES.get(m.group(1), "") if m else ""
        if op == "set_text" and ctype != "field":
            return "set_text only works on a field (an [f...] id)."
        route = await asyncio.to_thread(_mirrored_route, db, uid)
        denied = app_registry.ui_denial(label, ctype, route)
        if denied:
            return f"Not done, by design: {denied['say']}"
        cmd_id = _queue_command(db, uid, {
            "action": "ui_action", "control": cid,
            "label": label.strip()[:200], "op": op, "value": value[:500],
        })
        ack = await _await_ack(db, uid, cmd_id)
        if not ack:
            return _NOT_APPLIED
        if not ack.get("ok"):
            reason = str(ack.get("reason") or "").strip()
            return f"Not done: {reason}" if reason else _NOT_APPLIED
        done = f"Done: {op} on {label.strip() or 'the screen'}."
        result = str(ack.get("result") or "").strip()[:_VISIBLE_MAX_CHARS]
        return f"{done} Screen now: {result}" if result else done

    return ui_action


_UI_ACTION = {
    "name": "ui_action",
    "description": _prompt("app_control_ui_action"),
    "parameters": {
        "type": "object",
        "properties": {
            "control": {"type": "string"},
            "label": {"type": "string"},
            "action": {"type": "string"},
            "value": {"type": "string"},
        },
        "required": ["action"],
    },
}
