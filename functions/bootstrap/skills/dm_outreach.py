"""``send_dm_message`` — Ayma sending a direct message to another real person
on the user's behalf, with exactly ONE confirmation (founder scope request
2026-09-16; one-confirmation redesign 2026-10-26).

It reaches a third party irreversibly, so nothing is ever sent without the
user's explicit yes to the exact text, enforced here on the server rather than
trusted to the model:

1. ``confirmed=false`` (person + the exact message) resolves the recipient
   against the Explore roster (``explore.explore`` already drops blocked and
   paused people), records a pending send under the sender's own session doc
   (``users/{uid}/sessions/{id}.pending_dm``: id, recipient, text, time, the
   user's line at that moment) and returns the preview. Nothing reaches the
   recipient. The model calls this as soon as it has composed the text, then
   asks once.
2. ``confirmed=true`` sends the pending text only when the user's own latest
   message (read from the turn window, not the model's claim) is a NEW,
   explicit affirmative ("yes", "yeah send it", "do it", "go ahead", "send")
   with no negation or change request, the pending send is under
   ``_PENDING_TTL_SECONDS`` old, and any ``person`` given still names the same
   recipient. A changed ``message`` replaces the pending send and asks once
   more about the new text instead of sending.
3. If the model skipped step 1 but its previous reply showed the exact text
   to the same person and the user's newest line says yes, it sends too: the
   user saw and approved that exact text, so a second "draft first" round is
   never needed (founder test 2026-10-26: three confirmations for one DM).

After a send: the pending send is cleared (a repeated confirm answers
"already sent" and never sends twice), the app is told to open the DM thread
(``navigate`` app command, path from ``app_registry.json``), and the result
carries the thread id and tells the model to say "Sent.".

Moderation is the same as a user-typed DM: ``dm_moderation.moderate`` flags
but never blocks (see ``dm_moderation.py``).
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
import uuid
from pathlib import Path
from typing import Callable

from firebase_admin import firestore

import app_registry
import dm_moderation
import dm_ops
import explore
from pair_key import sorted_pair_key

from . import app_control
from ._base import Skill

logger = logging.getLogger("ayma.dm_outreach")

# How long a previewed message stays sendable with a yes.
_PENDING_TTL_SECONDS = 5 * 60

# Voice: the caller's transcript can land a moment after the model already
# called the tool on it, so the confirm waits this long for the new line.
_NEW_LINE_WAIT_SECONDS = 2.5
_NEW_LINE_POLL_SECONDS = 0.25

_AFFIRMATIVE = re.compile(
    r"\b(yes|yeah|yea|yep|yup|ya|sure|ok(ay)?|confirm(ed)?|do it|go ahead|"
    r"go for it|send( it)?|please do|definitely|absolutely|sounds good|"
    r"perfect|i'?m sure)\b",
    re.IGNORECASE,
)
# A negation or a change request in the same line means "not this text".
_NEGATIVE = re.compile(
    r"\b(no|nope|nah|don'?t|do not|not|cancel|stop|wait|hold on|"
    r"never ?mind|but|change|instead|edit|rewrite)\b",
    re.IGNORECASE,
)

_PROMPTS = Path(__file__).resolve().parent.parent / "prompts"

DECLARATION = {
    "name": "send_dm_message",
    "description": (_PROMPTS / "dm_send.md").read_text(encoding="utf-8").strip(),
    "parameters": {
        "type": "object",
        "properties": {
            "person": {"type": "string"},
            "message": {"type": "string", "description": "the exact text"},
            "confirmed": {"type": "boolean"},
            "pending_id": {"type": "string"},
        },
        "required": ["person"],
    },
}


def is_confirmation(text: str) -> bool:
    """True for an explicit yes to send ("Yeah, send it.", "yes", "do it",
    "go ahead", "send") with no negation or change request in it."""
    t = (text or "").strip()
    return bool(t) and bool(_AFFIRMATIVE.search(t)) and not _NEGATIVE.search(t)


def _session_doc(db, uid: str, session_id: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("sessions")
        .document(session_id or "_adhoc")
    )


def _resolve_target(db, uid: str, person: str) -> tuple[str, str] | None:
    """The uid + display name for ``person`` among everyone this user can reach
    through Explore (blocked either way and paused people are already out)."""
    want = person.strip().lower()
    if not want:
        return None
    try:
        # No filters, a large cap: a named person must be found in the whole
        # reachable roster, not only Explore's default first page.
        cards = explore.explore(db, uid, {}, limit=10_000)
    except Exception:  # noqa: BLE001 - a lookup failure just means "not found"
        logger.exception("explore lookup failed resolving a DM recipient")
        return None

    best: tuple[int, str, str] | None = None  # (strength, uid, name)
    for card in cards:
        if card.get("self"):
            continue
        name = str(card.get("name") or "").strip().lower()
        if not name:
            continue
        first = name.split(" ")[0]
        strength = 0
        if name == want:
            strength = 3
        elif first == want:
            strength = 2
        elif want in name or name in want:
            strength = 1
        if strength and (best is None or strength > best[0]):
            best = (strength, str(card["uid"]), str(card.get("name") or person))
    return (best[1], best[2]) if best else None


def _names_match(asked: str, have: str) -> bool:
    want, have = asked.strip().lower(), have.strip().lower()
    if not want or not have:
        return False
    return want == have or want == have.split(" ")[0] or want in have or have in want


def _norm(text: str) -> str:
    """Lower-case, straight quotes, single spaces, no surrounding quotes/dots,
    so a quoted message in a reply compares equal to the stored text."""
    t = (text or "").lower()
    for a, b in (("’", "'"), ("‘", "'"), ("“", '"'), ("”", '"')):
        t = t.replace(a, b)
    return " ".join(t.split()).strip(" \"'.")


def _user_lines(turns: list) -> list[str]:
    return [
        str(getattr(t, "text", "") or "").strip()
        for t in turns
        if getattr(t, "role", None) == "user" and str(getattr(t, "text", "") or "").strip()
    ]


def _is_new_line(turns: list, pending: dict) -> bool:
    lines = _user_lines(turns)
    if not lines:
        return False
    return len(lines) > int(pending.get("user_lines") or 0) or (
        lines[-1] != str(pending.get("quote") or "")
    )


def _shown_and_approved(turns: list, body: str, name: str) -> bool:
    """The model's previous reply showed exactly ``body`` addressed to ``name``
    and the user's newest line, after it, is an explicit yes."""
    last_ayma = last_user = -1
    for i, t in enumerate(turns):
        role = getattr(t, "role", None)
        if role == "user":
            last_user = i
        elif role == "ayma":
            last_ayma = i
    if last_ayma < 0 or last_user < last_ayma:
        return False
    shown = _norm(str(getattr(turns[last_ayma], "text", "")))
    first = name.strip().lower().split(" ")[0] if name.strip() else ""
    want = _norm(body)
    return (
        len(want) >= 2
        and want in shown
        and bool(first)
        and first in shown
        and is_confirmation(str(getattr(turns[last_user], "text", "")))
    )


def _preview_reply(name: str, body: str, pending_id: str) -> str:
    return (
        f'PREVIEW ONLY, nothing sent yet. Show the exact text and ask once: '
        f'To {name}: "{body}" Send it? When they say yes in any form, call '
        f'send_dm_message with confirmed=true and pending_id="{pending_id}" '
        "right away, without asking again."
    )


def _dm_path(thread_id: str) -> str:
    """The DM thread route from the app registry with the id filled in."""
    for entry in app_registry.registry().get("parameterized", []):
        route = str(entry.get("route") or "")
        if route.startswith("/dm/"):
            return re.sub(r":\w+", thread_id, route)
    raise ValueError("app_registry.json has no /dm/ route")


def _open_thread(db, uid: str, thread_id: str) -> None:
    """Ask the app to open the DM thread so the user sees the sent message.
    Best effort: a failed command never undoes or hides a sent message."""
    try:
        app_control.queue_command(
            db, uid, {"action": "navigate", "screen": "dm", "path": _dm_path(thread_id)}
        )
    except Exception:  # noqa: BLE001
        logger.exception("could not queue the DM-thread navigation for %s", uid)


def _bind_send(
    db,
    uid: str,
    *,
    session_id: str = "",
    turns: list | Callable[[], list] | None = None,
) -> Callable[..., object]:
    """``turns`` is the conversation window: a list (text chat, fixed for the
    turn) or a callable returning the live window (voice, still growing)."""

    def _window() -> list:
        if callable(turns):
            return list(turns())
        return list(turns or [])

    async def _await_new_line(pending: dict) -> list:
        window = _window()
        if not callable(turns):
            return window
        deadline = time.monotonic() + _NEW_LINE_WAIT_SECONDS
        while not _is_new_line(window, pending) and time.monotonic() < deadline:
            await asyncio.sleep(_NEW_LINE_POLL_SECONDS)
            window = _window()
        return window

    def _record_pending(sess, other_uid: str, other_name: str, body: str) -> str:
        window = _window()
        lines = _user_lines(window)
        pending_id = uuid.uuid4().hex[:12]
        sess.set(
            {
                "pending_dm": {
                    "id": pending_id,
                    "other_uid": other_uid,
                    "other_name": other_name,
                    "body": body,
                    "at": time.time(),
                    "quote": lines[-1] if lines else "",
                    "user_lines": len(lines),
                }
            },
            merge=True,
        )
        return pending_id

    async def _deliver(sess, other_uid: str, other_name: str, body: str) -> str:
        moderation = await dm_moderation.moderate(body)
        try:
            await asyncio.to_thread(
                dm_ops.post_message, db, uid, other_uid, "text", body, None, moderation
            )
        except PermissionError:
            sess.set({"pending_dm": firestore.DELETE_FIELD}, merge=True)
            return f"Not sent: you and {other_name} can't message each other."
        except ValueError as exc:
            return f"Not sent: {exc}"
        except Exception:  # noqa: BLE001 - never crash the turn on a send failure
            logger.exception("DM send failed for %s", uid)
            return "Not sent: something went wrong. Tell the user it didn't go through."
        thread_id = sorted_pair_key(uid, other_uid)
        sess.set(
            {
                "pending_dm": firestore.DELETE_FIELD,
                "last_dm_sent": {
                    "other_name": other_name,
                    "body": body,
                    "thread_id": thread_id,
                    "at": time.time(),
                },
            },
            merge=True,
        )
        _open_thread(db, uid, thread_id)
        return (
            f'SENT to {other_name}: "{body}" (thread_id={thread_id}; the app is '
            'opening that conversation). Reply with exactly: "Sent."'
        )

    async def send_dm_message(
        person: str = "",
        message: str = "",
        confirmed: bool = False,
        pending_id: str = "",
    ) -> str:
        confirmed = confirmed is True or str(confirmed).strip().lower() in (
            "true", "yes", "1"
        )
        body = (message or "").strip()
        sess = _session_doc(db, uid, session_id)
        snap = sess.get()
        doc = (snap.to_dict() or {}) if snap.exists else {}
        pending = doc.get("pending_dm") or None
        if pending and time.time() - float(pending.get("at") or 0) > _PENDING_TTL_SECONDS:
            sess.set({"pending_dm": firestore.DELETE_FIELD}, merge=True)
            pending = None

        if not confirmed or (pending and body and _norm(body) != _norm(pending.get("body", ""))):
            # A preview, or the user changed the text: (re)record and ask once.
            target = _resolve_target(db, uid, person) if person.strip() else None
            if target is None and pending and not person.strip():
                target = (str(pending["other_uid"]), str(pending["other_name"]))
            if target is None:
                return f"I couldn't find anyone named '{person}' to message. Check the name."
            if not body:
                return "Ask what they'd like to say to them."
            new_id = _record_pending(sess, target[0], target[1], body)
            return _preview_reply(target[1], body, new_id)

        if pending is None:
            last = doc.get("last_dm_sent") or {}
            if last and time.time() - float(last.get("at") or 0) <= _PENDING_TTL_SECONDS and (
                not body or _norm(body) == _norm(last.get("body", ""))
            ):
                return f'Already sent to {last.get("other_name", "them")}. Say only: "Sent."'
            target = _resolve_target(db, uid, person) if person.strip() else None
            if target and body and _shown_and_approved(_window(), body, target[1]):
                return await _deliver(sess, target[0], target[1], body)
            if target and body:
                new_id = _record_pending(sess, target[0], target[1], body)
                return _preview_reply(target[1], body, new_id)
            return (
                "Not sent: no message is waiting for a yes. Call with "
                "confirmed=false, the person and the exact text first."
            )

        other_name = str(pending.get("other_name") or "them")
        if person.strip() and not _names_match(person, other_name):
            return (
                f"Not sent: the waiting message is for {other_name}, not "
                f"{person.strip()}. Ask the user who they meant."
            )
        if pending_id.strip() and pending_id.strip() != pending.get("id"):
            return _preview_reply(other_name, str(pending["body"]), str(pending["id"]))
        window = await _await_new_line(pending)
        lines = _user_lines(window)
        if not _is_new_line(window, pending) or not is_confirmation(lines[-1] if lines else ""):
            return (
                "Not sent: the user hasn't clearly said yes to this exact text "
                "in a new message. Wait for their answer."
            )
        return await _deliver(
            sess, str(pending["other_uid"]), other_name, str(pending["body"])
        )

    return send_dm_message


SEND_SKILL = Skill(declaration=DECLARATION, bind=_bind_send)
SKILLS = [SEND_SKILL]
