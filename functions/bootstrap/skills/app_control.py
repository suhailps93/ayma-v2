"""Voice-only tools: let Ayma *see* and *drive* the app during a call (§5.6).

None of these are registered in the text tool set — ``/chat`` already carries
``viewing_profile_uid`` for context and can't move the user's screen. They are
added to :func:`skills.make_livekit_tools` only.

* ``current_screen`` — read the mirror that ``POST /voice/context`` keeps at
  ``users/{uid}/voice_context/current`` while a call is live, so Ayma knows
  what "them / this / here" refers to.
* ``open_screen`` / ``search_explore`` / ``open_profile`` — queue one UI command
  at ``users/{uid}/app_commands/pending``; the Flutter client watches that doc
  while the call is live and performs the navigation, then deletes it.
"""

from __future__ import annotations

import time
from typing import Callable

from ._base import Skill

# A mirror older than this is treated as "nothing open" — the user closed the
# app or moved on and the client stopped updating.
_STALE_SECONDS = 120

_SCREENS = ("explore", "messages", "profile", "matches", "story", "settings")


def _server_ts():
    from firebase_admin import firestore

    return firestore.SERVER_TIMESTAMP


def _voice_context_doc(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("voice_context")
        .document("current")
    )


def _command_doc(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("app_commands")
        .document("pending")
    )


def _is_fresh(updated_at) -> bool:
    """True when a mirror timestamp is within the staleness window. Handles a
    Firestore ``Timestamp``/``datetime`` and tolerates a missing value."""
    if updated_at is None:
        return False
    try:
        ts = updated_at.timestamp()
    except AttributeError:
        return False
    return (time.time() - ts) <= _STALE_SECONDS


def _describe(ctx: dict) -> str:
    screen = str(ctx.get("screen") or "").strip()
    subject = str(ctx.get("subject_name") or "").strip()
    note = str(ctx.get("note") or "").strip()
    if screen == "profile" and subject:
        return f"The user is looking at {subject}'s profile."
    if screen == "match_report" and subject:
        return f"The user is looking at the match report for {subject}."
    if screen == "dm" and subject:
        return f"The user is on their message thread with {subject}."
    if screen == "explore":
        return (
            f"The user is on the Explore screen, searching for '{note}'."
            if note
            else "The user is browsing the Explore screen."
        )
    if screen == "messages":
        return "The user is on their Messages list."
    if screen in ("ayma", "chat"):
        return "The user is on the main chat screen with you."
    if screen == "profile_tab":
        return "The user is on their own profile screen."
    if subject:
        return f"The user is looking at {subject}."
    if screen:
        return f"The user is on the {screen} screen."
    return "The user hasn't opened anything specific."


def _resolve_person(db, uid: str, name: str) -> tuple[str | None, str]:
    """Best profile-name match for ``name`` across the roster (same scan Explore
    uses). Returns ``(uid, full_name)`` or ``(None, "")``."""
    want = name.strip().lower()
    if not want:
        return None, ""
    try:
        users = list(db.collection("users").stream())
    except Exception:  # noqa: BLE001
        return None, ""
    best: tuple[int, str, str] | None = None  # (strength, uid, full name)
    for u in users:
        other = u.id
        if other == uid:
            continue
        try:
            prof = (
                db.collection("users")
                .document(other)
                .collection("profile")
                .document("main")
                .get()
                .to_dict()
            ) or {}
        except Exception:  # noqa: BLE001
            continue
        full = str(prof.get("name") or "").strip()
        low = full.lower()
        if not low:
            continue
        first = low.split(" ")[0]
        strength = (
            3 if low == want
            else 2 if first == want
            else 1 if (want in low or low in want)
            else 0
        )
        if strength and (best is None or strength > best[0]):
            best = (strength, other, full)
    return (best[1], best[2]) if best else (None, "")


def _bind_current_screen(db, uid: str) -> Callable[..., str]:
    def current_screen() -> str:
        try:
            snap = _voice_context_doc(db, uid).get()
        except Exception:  # noqa: BLE001
            return "The user hasn't opened anything specific."
        data = snap.to_dict() if getattr(snap, "exists", False) else None
        data = data or {}
        if not data or not _is_fresh(data.get("updated_at")):
            return "The user hasn't opened anything specific."
        return _describe(data)

    return current_screen


def _bind_open_screen(db, uid: str) -> Callable[..., str]:
    def open_screen(screen: str = "") -> str:
        s = screen.strip().lower()
        if s not in _SCREENS:
            return (
                f"I can open {', '.join(_SCREENS)} — not '{screen.strip()}'."
            )
        _command_doc(db, uid).set(
            {"action": "navigate", "screen": s, "ts": _server_ts()}
        )
        return f"Opening {s.capitalize()}."

    return open_screen


def _bind_search_explore(db, uid: str) -> Callable[..., str]:
    def search_explore(query: str = "") -> str:
        q = query.strip()
        if not q:
            return "Tell me what to search Explore for."
        _command_doc(db, uid).set(
            {"action": "search_explore", "query": q[:200], "ts": _server_ts()}
        )
        return f"Searching Explore for {q}."

    return search_explore


def _bind_open_profile(db, uid: str) -> Callable[..., str]:
    def open_profile(name: str = "") -> str:
        other, full = _resolve_person(db, uid, name)
        if not other:
            return (
                f"I couldn't find someone called {name.strip() or 'that'} "
                "in the app."
            )
        _command_doc(db, uid).set(
            {"action": "open_profile", "uid": other, "ts": _server_ts()}
        )
        return f"Opening {full}'s profile."

    return open_profile


_CURRENT_SCREEN = {
    "name": "current_screen",
    "description": (
        "VOICE ONLY. Find out what screen or person the user is looking at in "
        "the app right now. Call this the moment they say 'them', 'this "
        "person', 'here', 'this one', 'this profile' without naming who — then "
        "answer using what it tells you."
    ),
    "parameters": {"type": "object", "properties": {}},
}

_OPEN_SCREEN = {
    "name": "open_screen",
    "description": (
        "VOICE ONLY. Move the user to a main screen of the app so they don't "
        "have to touch the phone. Use when they ask you to take them somewhere "
        "('show me my matches', 'go to settings')."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "screen": {
                "type": "string",
                "enum": list(_SCREENS),
                "description": "which screen to open",
            }
        },
        "required": ["screen"],
    },
}

_SEARCH_EXPLORE = {
    "name": "search_explore",
    "description": (
        "VOICE ONLY. Open Explore and run a natural-language search for the "
        "user ('find people who love hiking', 'search for someone in Austin "
        "who wants kids'). Pass their request as the query."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "the search, in the user's own words",
            }
        },
        "required": ["query"],
    },
}

_OPEN_PROFILE = {
    "name": "open_profile",
    "description": (
        "VOICE ONLY. Open a specific person's profile for the user by name "
        "('pull up Jordan's profile'). Pass the name as they said it."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "name": {
                "type": "string",
                "description": "the person's name, as the user refers to them",
            }
        },
        "required": ["name"],
    },
}


VOICE_SKILLS: list[Skill] = [
    Skill(declaration=_CURRENT_SCREEN, bind=_bind_current_screen),
    Skill(declaration=_OPEN_SCREEN, bind=_bind_open_screen),
    Skill(declaration=_SEARCH_EXPLORE, bind=_bind_search_explore),
    Skill(declaration=_OPEN_PROFILE, bind=_bind_open_profile),
]
