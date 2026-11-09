"""App-control command queue: the primitives every app-driving tool shares.

One UI command is queued at ``users/{uid}/app_commands/pending`` and the tool
*waits* (bounded) for the client's ack of that exact id at
``users/{uid}/app_commands/ack`` before returning — a queued command is
*intent*, not fact (founder bug, 2026-09-26). Split out of
``skills/app_control.py`` (Tier-2 sweep item #8); ``app_control.py`` stays the
facade and keeps the timeout knobs (tests patch them there).

Also home to the shared tool-description loader (:func:`_prompt`) and the
honest-failure lines, which every action family imports from here.
"""

from __future__ import annotations

import asyncio
import time
import uuid
from pathlib import Path

_PROMPTS = Path(__file__).resolve().parent.parent / "prompts"


def _prompt(name: str, **fill: str) -> str:
    """A tool description from ``prompts/<name>.md`` with its ``{{KEY}}``
    slots filled from the registry, so the capability list the model reads is
    always the registry itself."""
    text = (_PROMPTS / f"{name}.md").read_text(encoding="utf-8").strip()
    for key, value in fill.items():
        text = text.replace("{{" + key + "}}", value)
    return text


# The cap on how much of the client's search-results report reaches the model.
_RESULT_MAX_CHARS = 1500

# The shared honest line for every navigation tool when unconfirmed — the model
# must relay this truthfully without claiming a false failure or false success.
_NOT_NAVIGATED = (
    "The app has not confirmed the navigation yet — tell the user it "
    "hasn't switched yet and where to find it in the menu if it doesn't "
    "open shortly."
)
_NOT_APPLIED = "The app did NOT apply that — tell the user it didn't work."


def _server_ts():
    from firebase_admin import firestore

    return firestore.SERVER_TIMESTAMP


def _command_doc(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("app_commands")
        .document("pending")
    )


def _ack_doc(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("app_commands")
        .document("ack")
    )


# The last command queued per user: uid -> {"id": cmd_id, "payload": payload, "ts": time.monotonic()}
_LAST_QUEUED: dict[str, dict] = {}


def get_last_queued(uid: str) -> dict | None:
    """The most recent command queued for ``uid``, if any."""
    return _LAST_QUEUED.get(uid)


def _queue_command(db, uid: str, payload: dict) -> str:
    """Write one UI command to the pending doc with a fresh unique ``id``
    (what the client's ack echoes back) and return that id."""
    cmd_id = uuid.uuid4().hex
    _command_doc(db, uid).set({**payload, "id": cmd_id, "ts": _server_ts()})
    _LAST_QUEUED[uid] = {
        "id": cmd_id,
        "payload": payload,
        "ts": time.monotonic(),
    }
    return cmd_id


async def watch_late_ack(
    db,
    uid: str,
    cmd_id: str,
    on_ack,
    timeout: float = 90.0,
) -> None:
    """Poll the ack doc in the background for a late ack on ``cmd_id`` (up to
    the client's 90s stale window). If ``cmd_id`` acks with ok: True and has not
    been superseded by a newer command, invokes ``on_ack(data)``."""
    from skills import app_control  # deferred: the facade owns the knobs

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        last = _LAST_QUEUED.get(uid)
        if last and last.get("id") != cmd_id:
            return  # Superseded by a newer command

        try:
            snap = await asyncio.to_thread(_ack_doc(db, uid).get)
            data = snap.to_dict() if getattr(snap, "exists", False) else None
        except Exception:  # noqa: BLE001
            data = None

        if data and str(data.get("id") or "") == cmd_id:
            last = _LAST_QUEUED.get(uid)
            if last and last.get("id") != cmd_id:
                return
            if data.get("ok"):
                res = on_ack(data)
                if asyncio.iscoroutine(res):
                    await res
            return

        await asyncio.sleep(app_control._ACK_POLL_SECONDS)


# Other skills queue a UI command without waiting for the ack (send_dm_message
# opens the thread it just sent to).
queue_command = _queue_command


async def _await_ack(
    db, uid: str, cmd_id: str, timeout: float | None = None
) -> dict | None:
    """Poll the ack doc until the client acknowledges ``cmd_id`` or the
    bounded wait runs out. Returns the ack dict (``{id, ok, …}``) or ``None``
    on timeout. ``timeout`` overrides the default ``_ACK_TIMEOUT_SECONDS`` for
    a slower command (a scroll-to-end op repeats on the client for ~20s before
    it can ack). Firestore reads run in a thread so the LiveKit agent's event
    loop (live audio) is never blocked by a poll.

    With the default window (``timeout=None``) a silent first window is
    followed by ONE re-wait of the same length on the SAME command id before
    giving up: the client's command watch can be down for ~10s while it
    resubscribes after a stream error, or while the phone recovers from the
    network churn around a dropped voice call, and the queued command stays
    executable client-side for 90s, so its late ack still lands on this id.
    This is the ONE ack wait every app command shares — the navigation tools
    above, and the self-check's nav checks, which await through this helper
    with no window of their own — so a real turn and a self-check judge a
    navigation by exactly the same patience (founder, 2026-11-07: a
    self-check passed every nav minutes before a real "open Explore" ask
    failed, because the check privately waited twice as long as the tool).
    Callers that pass an explicit timeout keep exactly that single window.
    """
    windows = 2 if timeout is None else 1
    for _ in range(windows):
        ack = await _await_ack_window(db, uid, cmd_id, timeout)
        if ack is not None:
            return ack
    return None


async def _await_ack_window(
    db, uid: str, cmd_id: str, timeout: float | None
) -> dict | None:
    """One bounded poll window for ``cmd_id``'s ack (see :func:`_await_ack`)."""
    from skills import app_control  # deferred: the facade owns the knobs

    wait = app_control._ACK_TIMEOUT_SECONDS if timeout is None else timeout
    deadline = time.monotonic() + wait
    while True:
        try:
            snap = await asyncio.to_thread(_ack_doc(db, uid).get)
            data = snap.to_dict() if getattr(snap, "exists", False) else None
        except Exception:  # noqa: BLE001
            data = None
        if data and str(data.get("id") or "") == cmd_id:
            return data
        if time.monotonic() >= deadline:
            # One final read before giving up, so an ack arriving on the boundary
            # is never lost to a race.
            try:
                snap = await asyncio.to_thread(_ack_doc(db, uid).get)
                data = snap.to_dict() if getattr(snap, "exists", False) else None
                if data and str(data.get("id") or "") == cmd_id:
                    return data
            except Exception:  # noqa: BLE001
                pass
            return None
        await asyncio.sleep(app_control._ACK_POLL_SECONDS)


async def _await_result(db, uid: str, cmd_id: str) -> str:
    """Poll the ack doc until the client adds the ``result`` text for
    ``cmd_id`` (what Explore shows after the search loaded), or the bounded
    wait runs out. Returns ``""`` on timeout."""
    from skills import app_control  # deferred: the facade owns the knobs

    deadline = time.monotonic() + app_control._RESULT_TIMEOUT_SECONDS
    while True:
        try:
            snap = await asyncio.to_thread(_ack_doc(db, uid).get)
            data = snap.to_dict() if getattr(snap, "exists", False) else None
        except Exception:  # noqa: BLE001
            data = None
        if data and str(data.get("id") or "") == cmd_id:
            result = str(data.get("result") or "").strip()
            if result:
                return result[:_RESULT_MAX_CHARS]
        if time.monotonic() >= deadline:
            return ""
        await asyncio.sleep(app_control._ACK_POLL_SECONDS)
