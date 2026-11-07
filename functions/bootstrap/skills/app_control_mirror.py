"""App-control screen mirror: read what the user is looking at.

``current_screen`` (voice-only) reads the mirror ``POST /voice/context``
keeps at ``users/{uid}/voice_context/current`` while a call is live;
``list_conversations`` lists the user's own DM threads for Ayma to relay.
Split out of ``skills/app_control.py`` (Tier-2 sweep item #8).
"""

from __future__ import annotations

import asyncio
import difflib
import logging
import re
import time
from typing import Callable

import app_registry
import public_profile

from .app_control_queue import _RESULT_MAX_CHARS

logger = logging.getLogger("ayma.app_control")

# A mirror older than this is treated as "nothing open" — the user closed the
# app or moved on and the client stopped updating. The client re-pushes on a
# ~45s heartbeat for the whole call, so this only needs enough slack to ride
# out a missed beat or two (a backgrounded app, a flaky network).
_STALE_SECONDS = 300


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


_NOTHING_OPEN = "The user hasn't opened anything specific."

# The generic capture (route, headings, text, controls) is two halves of at
# most ~1,500 characters each on the client; this caps what reaches a prompt.
_VISIBLE_MAX_CHARS = 3200


def _describe(ctx: dict) -> str:
    """One description of the user's screen: the screen's own slug-based line,
    the route's registry name and what can be opened from it, then the live
    capture of what is on it (text and operable controls)."""
    base = _describe_screen(ctx)
    route = str(ctx.get("route") or "").strip()
    visible = str(ctx.get("visible") or "").strip()[:_VISIBLE_MAX_CHARS]
    name = app_registry.route_name(route) if route else ""
    if base == _NOTHING_OPEN and name:
        base = f"The user is on {name}."
    parts = [base]
    if route:
        parts.append(f"Route: {route}" + (f" ({name})." if name else "."))
        dest = app_registry.destination_for_route(route)
        items = app_registry.found_on(dest["key"]) if dest else []
        if items and dest["key"] != "profile":
            parts.append("On this page: " + "; ".join(items) + ".")
    prev_label = str(ctx.get("previous_label") or "").strip()
    prev_route = str(ctx.get("previous_route") or "").strip()
    if not prev_label and prev_route:
        prev_label = app_registry.route_name(prev_route)
    if prev_label:
        parts.append(
            f"Previous page: {prev_label} — if the user says 'go back' or "
            "'take me back', call go_back to return there."
        )
    if str(ctx.get("copilot_share") or "").strip() == "active":
        parts.append(
            "Co-pilot screen share is ACTIVE: the user is sharing their "
            "phone screen (they are likely in another app). You CAN see "
            "that shared screen — call copilot_locate with what they want "
            "to do to look at the current frame and highlight what to "
            "tap. Never say you cannot see their screen while the share "
            "is active; if copilot_locate reports the share stopped or "
            "the screen is protected, relay exactly that."
        )
    if visible:
        parts.append(
            "On screen now (live; controls read [id] type \"label\" = state "
            "and ui_action operates them by id): " + visible
        )
    return " ".join(parts)


def _describe_screen(ctx: dict) -> str:
    screen = str(ctx.get("screen") or "").strip()
    subject = str(ctx.get("subject_name") or "").strip()
    subject_uid = str(ctx.get("subject_uid") or "").strip()
    note = str(ctx.get("note") or "").strip()
    detail = str(ctx.get("detail") or "").strip()[:_RESULT_MAX_CHARS]
    if screen == "explore":
        base = (
            f"The user is on the Explore screen, searching for '{note}'."
            if note
            else "The user is browsing the Explore screen."
        )
        return f"{base} On screen now: {detail}" if detail else base
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
        return (
            "The user is on their own You tab. It shows, top to bottom: "
            + "; ".join(app_registry.found_on("profile"))
            + ". 'This card' / 'that' means one of these — the completeness "
            "card at the top opens with open_screen complete_profile."
        )
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
    return _NOTHING_OPEN


def _voice_context_doc(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("voice_context")
        .document("current")
    )


def _mirrored_route(db, uid: str) -> str:
    """The route of the fresh voice mirror, or ``""`` (text chat, no call)."""
    try:
        snap = _voice_context_doc(db, uid).get()
        data = snap.to_dict() if getattr(snap, "exists", False) else None
    except Exception:  # noqa: BLE001
        return ""
    if not data or not _is_fresh(data.get("updated_at")):
        return ""
    return str(data.get("route") or "").strip()


# "open the last / most recent conversation" — a request to open the most
# recently active thread rather than name a person.
_LAST_INTENT = re.compile(
    r"^(the\s+|my\s+)?(last|latest|most[\s-]*recent|newest|previous)"
    r"(\s+(one|conversation|chat|thread|message|messages|dm|dms))?$"
)


def _epoch(ts) -> float:
    """Seconds-since-epoch for a Firestore ``Timestamp``/``datetime``; ``0.0``
    when it is missing or not a timestamp (sorts such a thread oldest)."""
    try:
        return ts.timestamp()
    except AttributeError:
        return 0.0


def _ago(ts) -> str:
    """A short relative age for a thread's last-message time (no exact time, no
    message text — just recency for Ayma to relay)."""
    secs = _epoch(ts)
    if not secs:
        return "recently"
    delta = time.time() - secs
    if delta < 90:
        return "just now"
    mins = int(delta // 60)
    if mins < 60:
        return f"{mins} minute{'s' if mins != 1 else ''} ago"
    hours = int(delta // 3600)
    if hours < 24:
        return f"{hours} hour{'s' if hours != 1 else ''} ago"
    days = int(delta // 86400)
    if days < 2:
        return "yesterday"
    if days < 7:
        return f"{days} days ago"
    weeks = days // 7
    if weeks < 5:
        return f"{weeks} week{'s' if weeks != 1 else ''} ago"
    months = days // 30
    return f"{months} month{'s' if months != 1 else ''} ago"


def _dm_threads(db, uid: str) -> list[dict]:
    """The signed-in user's own DM threads, most-recent first. Each entry is
    ``{other, name, last_at, unread}`` — the other person's uid and profile
    name, the last-message timestamp, and whether this user has unread messages
    in it. Scoped to this uid's own threads (``participants`` contains them) and
    excludes threads they've hidden (a block). No message bodies are read —
    privacy-safe by construction (§6.6, §6.8)."""
    try:
        snaps = list(
            db.collection("dm_threads")
            .where("participants", "array_contains", uid)
            .stream()
        )
    except Exception:  # noqa: BLE001
        logger.exception("listing dm threads failed for %s", uid)
        return []
    out: list[dict] = []
    for t in snaps:
        d = t.to_dict() or {}
        if uid in (d.get("hidden_for") or []):
            continue
        parts = d.get("participants") or []
        other = next((p for p in parts if p != uid), None)
        if not other:
            continue
        try:
            prof = (
                db.collection("users").document(other)
                .collection("profile").document("main").get().to_dict()
            ) or {}
        except Exception:  # noqa: BLE001
            prof = {}
        name = str(prof.get("name") or "").strip() or "Someone"
        unread = int((d.get("unread") or {}).get(uid, 0) or 0) > 0
        out.append({
            "other": other,
            "name": name,
            "last_at": d.get("last_message_at"),
            "unread": unread,
        })
    out.sort(key=lambda t: _epoch(t["last_at"]), reverse=True)
    return out


def _thread_strength(name: str, want: str) -> int:
    """How strongly a thread's person name matches what the user said: 3 exact
    full name, 2 exact first name, 1 substring or a close fuzzy match (typos /
    near-spellings), 0 no match."""
    low = name.strip().lower()
    if not low:
        return 0
    first = low.split(" ")[0]
    if low == want:
        return 3
    if first == want:
        return 2
    if want in low or low in want:
        return 1
    if difflib.SequenceMatcher(None, first, want).ratio() >= 0.8:
        return 1
    return 0


def _best_thread(
    threads: list[dict], asked: str
) -> tuple[dict | None, list[dict]]:
    """Best fuzzy match for ``asked`` among ``threads``. Returns
    ``(thread, [])`` for a single clear winner, ``(None, candidates)`` when
    more than one is equally plausible (the caller asks which), or
    ``(None, [])`` when nothing matches."""
    want = asked.strip().lower()
    scored = [(_thread_strength(t["name"], want), t) for t in threads]
    best = max((s for s, _ in scored), default=0)
    if best == 0:
        return None, []
    top = [t for s, t in scored if s == best]
    return (top[0], []) if len(top) == 1 else (None, top)


def _bind_list_conversations(db, uid: str) -> Callable[..., str]:
    async def list_conversations() -> str:
        threads = await asyncio.to_thread(_dm_threads, db, uid)
        if not threads:
            return (
                "The user has no message threads yet — no one is in their "
                "conversations. Don't invent names."
            )
        lines = [
            f"{t['name']} (last message {_ago(t['last_at'])}"
            + (", unread)" if t["unread"] else ")")
            for t in threads
        ]
        n = len(lines)
        unread = sum(1 for t in threads if t["unread"])
        head = (
            f"The user's {n} conversation{'s' if n != 1 else ''}, most recent "
            "first"
        )
        if unread:
            head += f" ({unread} with unread messages)"
        return head + ": " + "; ".join(lines) + "."

    return list_conversations


def _bind_current_screen(db, uid: str) -> Callable[..., str]:
    def current_screen() -> str:
        try:
            snap = _voice_context_doc(db, uid).get()
        except Exception:  # noqa: BLE001
            return _NOTHING_OPEN
        data = snap.to_dict() if getattr(snap, "exists", False) else None
        data = data or {}
        if not data or not _is_fresh(data.get("updated_at")):
            return _NOTHING_OPEN
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
                extra = _describe(data) if data.get("visible") else ""
                return f"{briefing}\n{extra}".strip()
        return _describe(data)

    return current_screen


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


_LIST_CONVERSATIONS = {
    "name": "list_conversations",
    "description": (
        "List the user's own existing DM conversations — who they are talking "
        "to, how recently, and which have unread messages — most recent first. "
        "Use it to answer 'who has messaged me?', 'who's in my conversations?', "
        "or before opening 'the last conversation'. It returns names and "
        "recency only, never message text (use read_dm_thread for the "
        "messages). If it says there are none, tell the user that plainly — "
        "never invent names."
    ),
    "parameters": {"type": "object", "properties": {}},
}
