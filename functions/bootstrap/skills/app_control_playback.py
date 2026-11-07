"""App-control playback: ``play_voice_clip`` plays a voice clip in the chat.

The ACTION PARITY pilot (founder, 2026-11-06, feedback items 7+8): the
user could tap a voice clip's play button, but Ayma had no command for
it, so she answered "I can't play it". This tool queues one
``play_voice_clip`` UI command at ``users/{uid}/app_commands/pending``;
the Flutter client (``AppCommandService`` + ``VoiceClipPlayback``)
resolves the clip in the open Ayma chat, plays it on the chat's own
player, and acks once playback has started — with ``voice_paused`` set
when a live voice session was disconnected to play the clip (the client
reconnects the same session, with context, when the clip finishes;
playback never runs inside the LiveKit room). Split out of
``skills/app_control.py`` following the Tier-2 family layout.
"""

from __future__ import annotations

from typing import Callable

from .app_control_queue import _await_ack, _prompt, _queue_command

# The selectors the client registry understands. Anything else is
# normalised to ``latest`` rather than refused: the user's phrasing
# ("play it", "play that again") almost always means the most recent
# clip, and a wrong guess is visible (the ack names what is playing).
_WHICH = {
    "": "latest",
    "latest": "latest",
    "last": "latest",
    "it": "latest",
    "that": "latest",
    "again": "latest",
    "previous": "previous",
    "prev": "previous",
    "mine": "mine",
    "my": "mine",
    "user": "mine",
    "ayma": "ayma",
    "aymas": "ayma",
    "hers": "ayma",
    "her": "ayma",
    "yours": "ayma",
}


def _bind_play_voice_clip(db, uid: str) -> Callable[..., str]:
    async def play_voice_clip(which: str = "") -> str:
        selector = _WHICH.get(which.strip().lower(), "latest")
        cmd_id = _queue_command(db, uid, {
            "action": "play_voice_clip", "which": selector,
        })
        # The client's ack waits for the announcement grace + (on a live
        # call) the disconnect before playback starts, so this tool gets
        # a longer bounded wait than a navigation's 6s.
        from skills import app_control as _facade  # deferred: owns the knobs

        ack = await _await_ack(
            db, uid, cmd_id, timeout=_facade._PLAYBACK_ACK_TIMEOUT_SECONDS
        )
        if not ack:
            return (
                "The app did NOT play anything — tell the user it didn't "
                "work and that they can tap the clip's play button."
            )
        if not ack.get("ok"):
            reason = str(ack.get("reason") or "").strip()
            return (
                f"Not played: {reason}" if reason else
                "The app did NOT play anything — tell the user it didn't work."
            )
        result = str(ack.get("result") or "Playing the voice message now.")
        return result[:500]

    return play_voice_clip


_PLAY_VOICE_CLIP = {
    "name": "play_voice_clip",
    "description": _prompt("app_control_play_voice_clip"),
    "parameters": {
        "type": "object",
        "properties": {
            "which": {
                "type": "string",
                "description": (
                    "Which clip: 'latest' (default), 'previous', 'mine' "
                    "(the user's own latest voice message) or 'ayma' "
                    "(Ayma's latest voice message)."
                ),
            }
        },
    },
}
