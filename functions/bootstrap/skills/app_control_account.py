"""App-control account actions: ``account_action`` runs sign out and wipe memory.

Only after an explicit confirmation in a later turn — and delete account,
withdraw face-matching consent and every purchase stay navigate-only (founder
rule, 2026-10-25): the tool opens the page and the user acts there themselves.
Split out of ``skills/app_control.py`` (Tier-2 sweep item #8).
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from typing import Callable

import app_registry

from ._base import last_user_quote
from .app_control_navigation import _navigate_only, _unavailable_reply
from .app_control_queue import (
    _await_ack,
    _NOT_APPLIED,
    _prompt,
    _queue_command,
)

logger = logging.getLogger("ayma.app_control")

# How long a proposed destructive action stays confirmable. (The voice minimum
# gap between asking and the confirmation lives on the app_control facade with
# the other timeout knobs, where tests patch it.)
_CONFIRM_TTL_SECONDS = 180.0
_AFFIRMATIVE = re.compile(
    r"\b(yes|yeah|yep|yup|sure|confirm(ed)?|do it|go ahead|i'?m sure|"
    r"please do|definitely|absolutely|ok(ay)?)\b",
    re.IGNORECASE,
)
_NEGATIVE = re.compile(
    r"\b(no|nope|nah|don'?t|do not|not|cancel|stop|wait|never ?mind)\b",
    re.IGNORECASE,
)


def _pending_doc(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("app_commands")
        .document("account_action_pending")
    )


def _run_account_action(db, uid: str, act: dict) -> str:
    """The server-side destructive actions (wipe memory). Raises on failure."""
    if act["handler"] == "wipe_memory":
        import knowledge_wipe

        knowledge_wipe.wipe_knowledge(db, uid)
        return (
            "Done: wiped what Ayma had learned (wiki and history). The "
            "account, profile and photos stay."
        )
    raise ValueError(f"no server handler for {act['key']}")


def _bind_account_action(
    db, uid: str, *, turns: list | None = None, **_session
) -> Callable[..., str]:
    async def account_action(action: str = "", confirmed: bool = False) -> str:
        from skills import app_control  # deferred: the facade owns the knobs

        confirmed = confirmed is True or str(confirmed).strip().lower() in (
            "true", "yes", "1"
        )
        act = app_registry.find_account_action(action)
        if act is None:
            gone = app_registry.find_unavailable(action)
            if gone:
                return await _unavailable_reply(db, uid, gone)
            return (
                f"There is no '{action.strip()}' account action — tell the user "
                "plainly. Actions that exist: "
                + ", ".join(a["key"] for a in app_registry.account_actions())
                + "."
            )
        if act["handler"] == "navigate_only":
            return await _navigate_only(db, uid, act["destination"], act["say"])
        quote_now = last_user_quote(turns)
        ref = _pending_doc(db, uid)
        if not confirmed:
            ref.set({
                "action": act["key"],
                "at": time.time(),
                "quote": quote_now,
            })
            return (
                f"Not done yet. Ask the user: \"{act['question']} Say "
                f"'{act['confirm_phrase']}' to go ahead.\" Only call again "
                "with confirmed=true after they clearly say yes in their next "
                "message."
            )
        try:
            snap = ref.get()
            pending = snap.to_dict() if getattr(snap, "exists", False) else None
        except Exception:  # noqa: BLE001
            pending = None
        age = time.time() - float((pending or {}).get("at") or 0)
        if not pending or pending.get("action") != act["key"] or (
            age > _CONFIRM_TTL_SECONDS
        ):
            return (
                "Not done: the user hasn't been asked to confirm this yet. "
                "Call with confirmed=false first and ask them."
            )
        if turns is not None:
            if (
                quote_now == pending.get("quote")
                or not _AFFIRMATIVE.search(quote_now)
                or _NEGATIVE.search(quote_now)
            ):
                return (
                    "Not done: wait for the user's own explicit yes in a new "
                    "message before confirming."
                )
        elif age < app_control._CONFIRM_MIN_GAP_SECONDS:
            return (
                "Not done: ask the user and wait for their spoken yes before "
                "confirming."
            )
        ref.delete()
        if act["handler"] != "client":
            try:
                return await asyncio.to_thread(_run_account_action, db, uid, act)
            except Exception:  # noqa: BLE001
                logger.exception("account action %s failed for %s", act["key"], uid)
                return _NOT_APPLIED
        cmd_id = _queue_command(
            db, uid, {"action": "app_action", "name": act["key"]}
        )
        ack = await _await_ack(db, uid, cmd_id)
        if not (ack and ack.get("ok")):
            return _NOT_APPLIED
        return "Done: signing them out now."

    return account_action


_ACCOUNT_ACTION = {
    "name": "account_action",
    "description": _prompt(
        "app_control_account_action",
        ACCOUNT_ACTIONS=", ".join(
            f"{a['key']} ({a['label']})" for a in app_registry.account_actions()
        ),
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "action": {"type": "string"},
            "confirmed": {"type": "boolean"},
        },
        "required": ["action"],
    },
}
