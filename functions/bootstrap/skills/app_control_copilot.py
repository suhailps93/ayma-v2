"""Co-pilot voice bridge: ``copilot_locate`` / ``copilot_copy_draft``.

The co-pilot screen share (MediaProjection, per-session consent) used to
feed ONLY the co-pilot page's text ask — a voice session running at the
same time had zero screen context and Ayma honestly answered "I can't
see it" (founder finding, Nov 6, 2026: "Is the voice mode not using the
screen? Is it only chat?"). These two tools close that gap: they queue
one app command each at ``users/{uid}/app_commands/pending`` and the
Flutter client (``AppCommandService``) executes it against the LIVE
share:

* ``copilot_locate`` — the client takes its latest shared frame (the one
  it is holding right now; frames are never stored anywhere), runs the
  existing ``POST /copilot/locate`` vision pass on it, draws the
  highlight ring over the other app, and acks a compact spoken report
  (or an honest reason: share off, protected screen, no frame yet,
  vision failed). Frame-on-ask holds exactly as on the page: a frame
  leaves the device ONLY when this tool is called, i.e. when the user
  asked about their screen out loud.
* ``copilot_copy_draft`` — after a locate composed a draft for a text
  field and the user heard it read aloud and said yes, this queues the
  copy: the client puts its held draft on the clipboard. It never types
  or sends; the user long-presses and pastes in the other app.

Both lanes (text + voice) get the tools through ``COMMAND_SKILLS`` —
voice is the point of the fix. The separate in-call video/screen share
(realtime stacks) is untouched: this is the co-pilot MediaProjection
share meeting the voice session, nothing else.
"""

from __future__ import annotations

from typing import Callable

from .app_control_queue import _await_ack, _NOT_APPLIED, _prompt, _queue_command

# The client-side locate is a real vision round trip (frame upload +
# /copilot/locate + drawing the ring); the navigation-default 6s would
# cut healthy calls. Still bounded so a dead listener fails honestly.
_COPILOT_ACK_TIMEOUT_SECONDS = 30.0

_NOT_SHARING = (
    "The co-pilot screen share is NOT on, so you cannot see their screen. "
    "Tell the user exactly that, and how to start it: open Ayma's Screen "
    "co-pilot page (in Ayma's settings), tap Start sharing, switch back "
    "to the app they need help with, and ask again. Do NOT claim you can "
    "see anything on their screen."
)

_REASON_LINES = {
    "secure_paused": (
        "The user is on a protected screen (a banking or password "
        "screen), which Android shows to Ayma as black — you cannot see "
        "it, by design. Tell them that, and ask them to move to the "
        "screen they need help with and ask again."
    ),
    "screen_locked": (
        "The phone is locked, so the shared screen is paused and you "
        "cannot see it. Ask the user to unlock and ask again."
    ),
    "no_frame": (
        "The share is on but no clear frame has arrived yet. Ask the "
        "user to give it a second on the screen they mean and ask again."
    ),
    "vision_failed": (
        "You tried to look at the shared screen but the vision pass "
        "failed just now. Say so honestly — do NOT guess what is on the "
        "screen — and ask them to try again."
    ),
    "no_draft": (
        "There is no draft waiting to copy — a draft exists only right "
        "after copilot_locate found a text field and composed one. Look "
        "at the screen first with copilot_locate."
    ),
}

_NO_ANSWER = (
    "The app did NOT answer — the screen share may have stopped, or the "
    "app is not listening right now. Tell the user you could not reach "
    "the shared screen; do NOT claim you can see it."
)


def _bind_copilot_locate(db, uid: str) -> Callable[..., str]:
    async def copilot_locate(goal: str = "") -> str:
        g = (goal or "").strip()[:500]
        if not g:
            return (
                "Ask the user what they are trying to do on that screen "
                "first, then call copilot_locate again with their goal "
                "in their words."
            )
        cmd_id = _queue_command(
            db, uid, {"action": "copilot_locate", "goal": g}
        )
        ack = await _await_ack(
            db, uid, cmd_id, timeout=_COPILOT_ACK_TIMEOUT_SECONDS
        )
        if not ack:
            return _NO_ANSWER
        if not ack.get("ok"):
            reason = str(ack.get("reason") or "").strip()
            if reason == "not_sharing":
                return _NOT_SHARING
            return _REASON_LINES.get(reason, _NOT_APPLIED)
        result = str(ack.get("result") or "").strip()
        if result:
            # The client's report is written to be spoken: what the ring
            # is over, the guidance line, and (for a text field) the
            # draft readback + ask. Relay it faithfully.
            return result[:2000]
        return (
            "The app looked at the shared screen but sent back no "
            "description. Tell the user you could not read that screen "
            "and ask them to try again."
        )

    return copilot_locate


def _bind_copilot_copy_draft(db, uid: str) -> Callable[..., str]:
    async def copilot_copy_draft() -> str:
        cmd_id = _queue_command(db, uid, {"action": "copilot_copy_draft"})
        ack = await _await_ack(
            db, uid, cmd_id, timeout=_COPILOT_ACK_TIMEOUT_SECONDS
        )
        if not ack:
            return _NO_ANSWER
        if not ack.get("ok"):
            reason = str(ack.get("reason") or "").strip()
            if reason == "not_sharing":
                return _NOT_SHARING
            return _REASON_LINES.get(reason, _NOT_APPLIED)
        return (
            "Copied — the draft is on the user's clipboard now. Tell "
            "them: tap the text box in the other app, long-press, and "
            "paste. Do NOT say you typed or sent anything for them; "
            "pasting is their tap."
        )

    return copilot_copy_draft


_COPILOT_LOCATE = {
    "name": "copilot_locate",
    "description": _prompt("app_control_copilot_locate"),
    "parameters": {
        "type": "object",
        "properties": {
            "goal": {
                "type": "string",
                "description": (
                    "What the user wants to do on the shared screen, in "
                    "their words (e.g. 'reply to this message', 'pay "
                    "this bill', 'send this photo')."
                ),
            },
        },
        "required": ["goal"],
    },
}

_COPILOT_COPY_DRAFT = {
    "name": "copilot_copy_draft",
    "description": _prompt("app_control_copilot_copy_draft"),
    "parameters": {"type": "object", "properties": {}},
}
