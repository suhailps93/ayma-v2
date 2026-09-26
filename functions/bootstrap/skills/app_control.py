"""Voice-only tools: let Ayma *see* and *drive* the app during a call (§5.6).

None of these are registered in the text tool set — ``/chat`` already carries
``viewing_profile_uid`` for context and can't move the user's screen. They are
added to :func:`skills.make_livekit_tools` only.

* ``current_screen`` — read the mirror that ``POST /voice/context`` keeps at
  ``users/{uid}/voice_context/current`` while a call is live, so Ayma knows
  what "them / this / here" refers to.
* ``open_screen`` / ``search_explore`` / ``open_profile`` / ``open_message_thread``
  / ``app_action`` — queue one UI command at ``users/{uid}/app_commands/pending``;
  the Flutter client (``AppCommandService``) watches that doc while the call is
  live, performs the navigation/action, then deletes it.

``open_screen`` covers every *fixed* destination in the app (§ founder bug
report — Ayma used to claim she could only reach 6 top-level tabs, then
"discovered" she could open Skills anyway; her own screen list was stale even
before that). Destinations that need a specific person/record instead of a
fixed key — a DM thread, a match/deep-dive/appearance/physical-attributes
report, someone's profile — aren't in ``_SCREENS``; ``open_profile`` and
``open_message_thread`` resolve those by name. ``app_action`` is the separate,
deliberately small set of common named actions (theme, pause matching) that
aren't navigation at all — see its own docstring below for why this stops
short of true generic UI automation.
"""

from __future__ import annotations

import time
from typing import Callable

import public_profile

from . import read_dm_thread
from ._base import Skill

# A mirror older than this is treated as "nothing open" — the user closed the
# app or moved on and the client stopped updating. The client re-pushes on a
# ~45s heartbeat for the whole call, so this only needs enough slack to ride
# out a missed beat or two (a backgrounded app, a flaky network).
_STALE_SECONDS = 300

# Every *fixed* screen Ayma can send the user to via ``open_screen`` — kept in
# lock-step with ``AppCommandService._pathFor``
# (ayma_flutter/lib/services/app_command_service.dart), which turns each key
# into a real GoRouter path. Left out on purpose:
# * Auth/onboarding screens (splash, sign-in, preboarding, complete-profile,
#   recovery) — nothing links to them for an already-signed-in user, so
#   "opening" one mid-conversation would just be confusing.
# * Google/Instagram account linking — built and working, but the product
#   deliberately hid both from the UI for v1 (see ``profile_tab_screen.dart``);
#   Ayma shouldn't resurface what the app itself is hiding.
# * A DM thread, or a match/deep-dive/appearance/physical-attributes report —
#   each needs a specific person/record, not a fixed key. ``open_profile`` and
#   ``open_message_thread`` resolve those by name instead.
_SCREENS = (
    "ayma",
    "explore",
    "messages",
    "profile",
    "matches",
    "story",
    "settings",
    "profile_details",
    "photos",
    "skills",
    "voice_preference",
    "credits",
    "accent_color",
    "notifications",
    "notification_settings",
    "feedback",
    "terms",
    "privacy",
    "release_notes",
)


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
    subject_uid = str(ctx.get("subject_uid") or "").strip()
    note = str(ctx.get("note") or "").strip()
    if screen == "profile":
        return (
            f"The user is looking at {subject}'s profile."
            if subject
            else "The user is looking at someone's profile."
        )
    if screen == "match_report":
        return (
            f"The user is looking at the match report for {subject}."
            if subject
            else "The user is looking at a match report."
        )
    if screen == "dm":
        return (
            f"The user is on their message thread with {subject}."
            if subject
            else "The user is in one of their message threads."
        )
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
    if screen == "story":
        return "The user is looking at their Story."
    if screen == "matches":
        return "The user is browsing their new matches."
    if screen == "skills":
        return "The user is on the Skills screen."
    if screen == "photo_management":
        return "The user is managing their profile photos."
    if screen == "deep_dive_report":
        return (
            f"The user is looking at a web-research report on {subject}."
            if subject
            else "The user is looking at a web-research report."
        )
    if screen == "appearance_report":
        return "The user is looking at an Appearance report."
    if screen == "physical_report":
        return "The user is looking at a physical-profile report."
    if subject:
        return f"The user is looking at {subject}."
    if subject_uid:
        return "The user is looking at someone's profile."
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
        screen = str(data.get("screen") or "").strip()
        subject_uid = str(data.get("subject_uid") or "").strip()
        # Text chat already gets a real briefing on the profile it's shown
        # (name/age/location, their public wiki, a private match read) via
        # `viewing_profile_uid` — give voice the same substance instead of a
        # bare name, so Ayma can answer detail questions instead of
        # fabricating them. Every other screen keeps the plain description.
        if screen == "profile" and subject_uid and subject_uid != uid:
            try:
                briefing = public_profile._viewing_profile_context(
                    db, uid, subject_uid
                )
            except Exception:  # noqa: BLE001
                briefing = ""
            if briefing:
                return briefing
        return _describe(data)

    return current_screen


# Friendly confirmation label for a screen key — only for the ones a plain
# ``.capitalize()`` on the key itself would render oddly (``profile_details``
# -> ``Profile_details``). Everything else falls through to ``.capitalize()``.
_SCREEN_LABELS = {
    "ayma": "our chat",
    "profile_details": "Profile Details",
    "voice_preference": "Ayma's voice",
    "accent_color": "Accent Color",
    "notification_settings": "Notification Settings",
    "release_notes": "What's New",
}


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
        return f"Opening {_SCREEN_LABELS.get(s, s.capitalize())}."

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


def _bind_open_message_thread(db, uid: str) -> Callable[..., str]:
    def open_message_thread(name: str = "") -> str:
        # Reuses `read_dm_thread`'s own name resolution, which is scoped to
        # people this user already has a `dm_threads` doc with — so this only
        # ever opens a real, existing conversation. For someone new (no
        # thread yet) that's `open_profile` instead.
        other = read_dm_thread._resolve_other_uid(db, uid, name)
        if not other:
            return (
                f"I couldn't find an existing conversation with "
                f"{name.strip() or 'that person'}."
            )
        _command_doc(db, uid).set(
            {"action": "open_dm_thread", "uid": other, "ts": _server_ts()}
        )
        return f"Opening your conversation with {name.strip()}."

    return open_message_thread


# Curated, common in-app actions Ayma can trigger directly — NOT generic UI
# automation. Each key maps to one real handler already wired to a button's
# `onPressed`/`onChanged` in the Flutter app (`SettingsScreen`'s theme radios
# and "Pause matching" switch); this list only grows when a new action is a
# similarly simple, unambiguous, no-side-effect-surprise toggle. Anything that
# needs per-screen state (which match report is open, which photo to re-crop)
# or is destructive (wiping the wiki, deleting the account, signing out) stays
# a manual tap — reachable by navigating there with `open_screen`, not by a
# blind remote action.
_APP_ACTIONS = {
    "dark_mode": "Switched you to dark mode.",
    "light_mode": "Switched you to light mode.",
    "system_theme": "Matched the app's theme to your system setting.",
    "pause_matching": "Paused matching — you're hidden from Explore and new match sourcing.",
    "resume_matching": "Resumed matching — you're visible again.",
}


def _bind_app_action(db, uid: str) -> Callable[..., str]:
    def app_action(action: str = "") -> str:
        a = action.strip().lower()
        if a not in _APP_ACTIONS:
            return (
                f"I can do {', '.join(_APP_ACTIONS)} — not '{action.strip()}'."
            )
        _command_doc(db, uid).set(
            {"action": "app_action", "name": a, "ts": _server_ts()}
        )
        return _APP_ACTIONS[a]

    return app_action


_CURRENT_SCREEN = {
    "name": "current_screen",
    "description": (
        "VOICE ONLY. What screen/person the user is looking at right now (a "
        "full briefing when it's someone's profile). ALWAYS call it before "
        "answering anything about their screen, and the moment they say "
        "'them / this person / here / this one' without naming who — never "
        "claim you can't see their screen without calling it."
    ),
    "parameters": {"type": "object", "properties": {}},
}

# The schema enum is deliberately omitted: these voice-only tools reach the
# model through livekit's `function_tool(fn, name=..., description=...)`,
# which serializes the *signature*, never this declaration's `parameters` —
# so the valid keys must live in the description text (the model's only view)
# and an enum here would only re-bill the same list. `_bind_open_screen`
# validates against `_SCREENS` regardless.
_OPEN_SCREEN = {
    "name": "open_screen",
    "description": (
        "VOICE ONLY. Move the user to a fixed screen; `screen` is one of: "
        + ", ".join(_SCREENS)
        + " (ayma = back to this chat). Never say you can't open a screen "
        "without checking this list; a person's profile or DM thread goes "
        "via open_profile / open_message_thread."
    ),
    "parameters": {
        "type": "object",
        "properties": {"screen": {"type": "string"}},
        "required": ["screen"],
    },
}

_SEARCH_EXPLORE = {
    "name": "search_explore",
    "description": (
        "VOICE ONLY. Open Explore and run a natural-language people search "
        "('find people who love hiking'), in the user's own words."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
            }
        },
        "required": ["query"],
    },
}

_OPEN_PROFILE = {
    "name": "open_profile",
    "description": (
        "VOICE ONLY. Open a person's profile by name, as the user said it."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "name": {
                "type": "string",
            }
        },
        "required": ["name"],
    },
}


_OPEN_MESSAGE_THREAD = {
    "name": "open_message_thread",
    "description": (
        "VOICE ONLY. Open the user's existing DM thread with a match, by "
        "name. If they haven't messaged that person yet, use open_profile "
        "instead."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "name": {
                "type": "string",
            }
        },
        "required": ["name"],
    },
}

_APP_ACTION = {
    "name": "app_action",
    "description": (
        "VOICE ONLY. Trigger one named in-app action: dark_mode / light_mode "
        "/ system_theme, pause_matching / resume_matching (hide/show them in "
        "Explore). Only these — not general UI control."
    ),
    "parameters": {
        "type": "object",
        "properties": {"action": {"type": "string"}},
        "required": ["action"],
    },
}


VOICE_SKILLS: list[Skill] = [
    Skill(declaration=_CURRENT_SCREEN, bind=_bind_current_screen),
    Skill(declaration=_OPEN_SCREEN, bind=_bind_open_screen),
    Skill(declaration=_SEARCH_EXPLORE, bind=_bind_search_explore),
    Skill(declaration=_OPEN_PROFILE, bind=_bind_open_profile),
    Skill(declaration=_OPEN_MESSAGE_THREAD, bind=_bind_open_message_thread),
    Skill(declaration=_APP_ACTION, bind=_bind_app_action),
]
