"""Take a picture: ``take_picture`` captures a photo with the phone camera.

Founder feedback item 12 (Nov 6, 2026): when the user asks Ayma to take a
picture, she first CONFIRMS which camera — front or back — and only then
captures. The two-step shape mirrors ``account_action``'s confirm-first
discipline, but the confirmation is conversational rather than a stored
pending doc: called without a ``camera`` (or with anything that is not
``front``/``back``), the tool queues NOTHING and returns the question the
model must ask; called again with the user's answer, it queues one
``take_picture`` app command (action-parity / APP_ACTION_GRAPH entry name:
``take_picture``) at ``users/{uid}/app_commands/pending``.

The Flutter client (``AppCommandService``) executes the command with the
app's existing camera plumbing (``image_picker``, the same picker the
chat's "Take a photo" attachment uses), uploads the capture as a chat
image and posts it into the conversation through the existing ``/chat``
vision path — the same path a manually attached photo takes — so Ayma
has actually seen the picture. The client's ack therefore carries, on
success, the capture's ``image_path`` and, when the vision reaction
landed, its text as ``result``; this tool relays that reaction so the
voice model can react to what the photo shows instead of merely
announcing the capture. When the ack carries no ``result`` the tool says
so plainly: capture shipped, vision reaction did not land — never a
fabricated description.

The ack wait is longer than the navigation default: the user has to
interact with the system camera UI, upload the photo and (best effort)
wait for the vision reaction before the client can ack.
"""

from __future__ import annotations

from typing import Callable

from .app_control_queue import _await_ack, _NOT_APPLIED, _prompt, _queue_command

# How long the tool waits for the client's ack of a capture command. The
# client acks only once the photo is in the conversation (capture +
# upload + the best-effort vision reaction), so this is sized for a real
# camera interaction, still bounded so the turn never hangs.
_TAKE_PICTURE_ACK_TIMEOUT_SECONDS = 90.0

_CAMERAS = ("front", "back")


def _bind_take_picture(db, uid: str) -> Callable[..., str]:
    async def take_picture(camera: str = "") -> str:
        cam = (camera or "").strip().lower()
        if cam not in _CAMERAS:
            # Confirm first (founder spec): no command is queued until the
            # user has chosen a camera. The model asks this question with
            # its own voice/text and calls again with the answer.
            return (
                "Do NOT take a picture yet. Ask the user this one question "
                "and wait for their answer: 'Front or back camera?' When "
                "they answer, call take_picture again with camera set to "
                "'front' or 'back' exactly as they chose."
            )
        cmd_id = _queue_command(db, uid, {
            "action": "take_picture", "camera": cam,
        })
        ack = await _await_ack(
            db, uid, cmd_id, timeout=_TAKE_PICTURE_ACK_TIMEOUT_SECONDS
        )
        if not ack:
            return (
                "The app did NOT take a picture — tell the user it didn't "
                "work (the app may be in the background) and that they can "
                "take the photo themselves with the camera button in the "
                "chat's attachment menu."
            )
        if not ack.get("ok"):
            reason = str(ack.get("reason") or "").strip()
            if reason == "cancelled":
                return (
                    "The camera was closed before a picture was taken — "
                    "tell the user no picture was taken."
                )
            if reason == "camera_unavailable":
                return (
                    "The camera could not be opened (permission denied or "
                    "no camera available) — tell the user to check that "
                    "Ayma has camera permission and ask again."
                )
            return _NOT_APPLIED
        image_path = str(ack.get("image_path") or "").strip()
        result = str(ack.get("result") or "").strip()
        done = (
            f"Done: took a picture with the {cam} camera and it is now in "
            "the conversation as a photo the user can see."
        )
        if image_path:
            done += f" (image_path: {image_path})"
        if result:
            return (
                f"{done} You already reacted to it in the chat with this "
                f"vision-based reply, so react consistently with it now: "
                f"{result[:1000]}"
            )
        return (
            f"{done} You could not see this one — the vision reaction did "
            "not land — so do NOT describe what is in the photo; just "
            "confirm it was taken and is in the chat."
        )

    return take_picture


_TAKE_PICTURE = {
    "name": "take_picture",
    "description": _prompt("app_control_take_picture"),
    "parameters": {
        "type": "object",
        "properties": {
            "camera": {
                "type": "string",
                "enum": ["front", "back"],
                "description": (
                    "Which camera the user chose after being asked "
                    "'Front or back camera?'. Omit until they answer."
                ),
            },
        },
        "required": [],
    },
}
