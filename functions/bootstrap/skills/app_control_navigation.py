"""App-control navigation: open screens, profiles, threads, and reports.

``open_screen`` opens any registered destination; ``search_explore``,
``open_profile``, ``open_message_thread`` and ``open_match_report`` drive the
pages that need a query or a specific person/record. Every tool queues one UI
command and waits for the client's ack before reporting success. Split out of
``skills/app_control.py`` (Tier-2 sweep item #8).
"""

from __future__ import annotations

import asyncio
import difflib
import logging
from typing import Callable
from urllib.parse import quote

import app_registry
import public_profile
from pair_key import sorted_pair_key

from .app_control_mirror import _best_thread, _dm_threads, _LAST_INTENT
from .app_control_queue import (
    _await_ack,
    _await_result,
    _NOT_APPLIED,
    _NOT_NAVIGATED,
    _prompt,
    _queue_command,
)

logger = logging.getLogger("ayma.app_control")

# Every destination key ``open_screen`` accepts. Routes deliberately left out
# (auth/onboarding, hidden Google/Instagram linking, the developer panel, …)
# are listed with their reason under ``non_navigable`` in the registry.
_SCREENS = tuple(d["key"] for d in app_registry.destinations())

# The list the model actually reads to pick a destination. Bare keys left the
# mapping under-determined over the Meta API (founder bug 2026-10-27: "open the
# appearance report" went to Notifications, then Chat, before landing on
# my_appearance), so each key carries its own label — "appearance report" now
# has one unambiguous key to match (my_appearance), never a guess.
_SCREEN_LINES = "; ".join(
    f"{d['key']} ({d['label']})" for d in app_registry.destinations()
)

# A difflib ratio at/above this makes a near-identical spelling (user's
# "Sophia" vs profile "Sofia", ratio 0.727) resolve to that profile directly
# instead of the reject-then-confirm path (founder bug 2026-10-29). It sits
# below every exact/substring tier, so it only decides when nothing better
# matches, and the closest fuzzy candidate wins.
_FUZZY_NAME_THRESHOLD = 0.72


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
    best: tuple[float, str, str] | None = None  # (strength, uid, full name)
    want_first = want.split(" ")[0]
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
        if low == want:
            strength = 3.0
        elif first == want:
            strength = 2.0
        elif want in low or low in want:
            strength = 1.0
        else:
            ratio = max(
                difflib.SequenceMatcher(None, first, want_first).ratio(),
                difflib.SequenceMatcher(None, low, want).ratio(),
            )
            strength = ratio if ratio >= _FUZZY_NAME_THRESHOLD else 0.0
        if strength and (best is None or strength > best[0]):
            best = (strength, other, full)
    return (best[1], best[2]) if best else (None, "")


def _not_a_page(asked: str) -> str:
    """The honest answer for a request that matches no destination (known
    unavailable things, and report re-runs, are handled before this): a pointer
    to the right tool when it's a setting/action, otherwise "doesn't exist"
    with the real list."""
    act = app_registry.find_account_action(asked)
    if act:
        return (
            f"'{asked}' is an action, not a page — use account_action "
            f"{act['key']} (it asks the user to confirm first)."
        )
    setting = app_registry.find_setting(asked)
    if setting and setting["handler"] != "tool":
        return (
            f"'{asked}' is a setting — change it with app_action "
            f"{setting['key']}, or open the page it's on."
        )
    return (
        f"There is no '{asked}' page in the app — tell the user plainly it "
        "doesn't exist. Pages that do: "
        + ", ".join(f"{d['key']} ({d['label']})" for d in app_registry.destinations())
        + "."
    )


def _resolve_path(db, uid: str, dest: dict) -> tuple[str, str]:
    """``(path, label)`` for a destination. ``resolve`` entries point at the
    user's own latest report when one exists, otherwise at the registry
    ``path`` (Skills, where they can run one) — exactly what the You tab's
    own rows do."""
    kind = dest.get("resolve")
    label = dest["label"]
    try:
        if kind == "my_deep_dive":
            import deep_dive

            name = deep_dive.profile_full_name(db, uid)
            if name:
                rid = deep_dive.dive_report_id(name=name)
                if deep_dive.read_dive(db, uid, rid) is not None:
                    return f"/deep-dive/{quote(rid, safe='')}", label
        elif kind == "my_appearance":
            import appearance

            if appearance.history(db, uid, limit=1):
                return "/appearance/current", label
    except Exception:  # noqa: BLE001 - fall back to the run screen
        logger.exception("resolving %s for %s failed", kind, uid)
    if kind:
        return dest["path"], "Skills (no report yet — they can run one there)"
    return dest["path"], label


async def _navigate(db, uid: str, key: str, path: str, label: str) -> str:
    cmd_id = _queue_command(
        db, uid, {"action": "navigate", "screen": key, "path": path}
    )
    ack = await _await_ack(db, uid, cmd_id)
    if ack and ack.get("ok"):
        return f"navigated: screen={key} — the user is now on {label}."
    return _NOT_NAVIGATED


async def _navigate_only(db, uid: str, dest_key: str, say: str) -> str:
    """Delete account, withdraw consent and every purchase never run from a
    tool: open the page where the user does it themselves and hand the model
    the kind, brief line to say."""
    dest = app_registry.find_destination(dest_key)
    path, label = await asyncio.to_thread(_resolve_path, db, uid, dest)
    nav = await _navigate(db, uid, dest["key"], path, label)
    if nav.startswith("navigated:"):
        return (
            f"Not done, by design: you never do this for the user. {nav} "
            f"Tell them kindly and briefly: \"{say}\""
        )
    return f"Not done, by design: you never do this for the user. {nav}"


async def _unavailable_reply(db, uid: str, gone: dict) -> str:
    if gone.get("navigate"):
        return await _navigate_only(db, uid, gone["navigate"], gone["say"])
    return f"Not available: {gone['say']}"


async def _run_report_action(db, uid: str, report: dict) -> str:
    """Actually (re)run the report a navigation/app_action request named, by
    invoking the same chat/voice tool (``report['via']``) that runs it — then
    return its real result (the ``[appearance:<id>]`` / ``[deep_dive:<id>]``
    card marker), not a text pointer telling the user to go use a tool.

    The app-driving path must DO the re-run, not deflect it (founder bug
    2026-10-28: "rerun the appearance report" either opened the existing report
    or returned "use the run_appearance_report tool", never re-running). The
    tool is bound here on ``(db, uid)`` alone, so it only ever touches this
    authenticated user's own report — no attachment, no third party."""
    via = report.get("via")
    if via == "run_appearance_report":
        from . import run_appearance_report as _report

        return await _report.SKILL.bind(db, uid)()
    if via == "deep_dive":
        from . import deep_dive as _report

        # A re-run of the user's own web research — self only (never a third
        # party from an app-control phrase); the bind resolves their profile
        # name, so no name is passed.
        return await _report.SKILL.bind(db, uid)(full_name="", subject="self")
    logger.error("report action %r has no runnable via (%r)", report.get("key"), via)
    return _NOT_APPLIED


def _story_edit_redirect(action: dict) -> str:
    """The directive handed back when an open_screen request is really a story
    edit/remove intent: do NOT navigate into the Story editor or its "Ask
    Ayma" passage popup — call the direct tool, which changes the user's own
    story straight from here (founder bug 2026-10-28)."""
    if action.get("via") == "remove_story_entry":
        return (
            "That's a story REMOVAL, not a page to open — do NOT navigate to "
            "the Story editor or open any passage popup. Call remove_story_entry "
            "with the section they mean; it soft-removes it directly (reversible) "
            "and you confirm from its result."
        )
    return (
        "That's a story EDIT, not a page to open — do NOT navigate to the Story "
        "editor or open any passage popup. Call edit_story_entry with the section, "
        "find_text (the one line they mean, quoted or closely paraphrased) and "
        "new_text (the corrected wording for ONLY that line — ask them for it if "
        "you don't have it yet). It changes just that one line in place, never the "
        "whole section, and you confirm the precise before -> after from its result."
    )


def _bind_open_screen(db, uid: str) -> Callable[..., str]:
    async def open_screen(screen: str = "") -> str:
        asked = screen.strip()
        # A "change / fix / reword / remove / delete … my story" request edits
        # the story in place via edit_story_entry / remove_story_entry — it must
        # NOT navigate into the Story editor's "Ask Ayma" passage popup, even
        # though its words also match the `story` destination (founder bug
        # 2026-10-28: "it shouldn't open that pop-up, it should just update it
        # directly"). Checked before find_destination so the direct edit wins; a
        # bare "open my story" (an open) doesn't match and still navigates below.
        story_edit = app_registry.find_story_edit_action(asked)
        if story_edit:
            return _story_edit_redirect(story_edit)
        # A re-run request ("rerun / regenerate / recalculate the appearance
        # report") must RUN the report, even though its words also match the
        # my_appearance destination — opening the old report is not re-running
        # it. Checked before find_destination so the re-run wins; a bare
        # "appearance report" (an open) does not match find_report_action and
        # still navigates below.
        report = app_registry.find_report_action(asked)
        if report:
            return await _run_report_action(db, uid, report)
        dest = app_registry.find_destination(screen)
        if dest is None:
            gone = app_registry.find_unavailable(asked)
            if gone:
                return await _unavailable_reply(db, uid, gone)
            return _not_a_page(asked)
        path, label = await asyncio.to_thread(_resolve_path, db, uid, dest)
        return await _navigate(db, uid, dest["key"], path, label)

    return open_screen


def _bind_open_match_report(db, uid: str) -> Callable[..., str]:
    async def open_match_report(name: str = "") -> str:
        other, full = await asyncio.to_thread(_resolve_person, db, uid, name)
        if not other:
            return (
                f"I couldn't find someone called {name.strip() or 'that'} "
                "in the app."
            )
        key = sorted_pair_key(uid, other)
        try:
            snap = await asyncio.to_thread(
                db.collection("matches").document(key).get
            )
            scored = bool(getattr(snap, "exists", False))
        except Exception:  # noqa: BLE001
            logger.exception("match lookup failed for %s", uid)
            scored = False
        if not scored:
            return (
                f"There's no match report with {full} yet — offer to open "
                "their profile, where they can run the match."
            )
        return await _navigate(
            db, uid, "match_report", f"/match/{key}",
            f"the match report with {full}",
        )

    return open_match_report


def _bind_search_explore(db, uid: str) -> Callable[..., str]:
    async def search_explore(query: str = "") -> str:
        q = query.strip()
        if not q:
            return "Tell me what to search Explore for."
        cmd_id = _queue_command(
            db, uid, {"action": "search_explore", "query": q[:200]}
        )
        ack = await _await_ack(db, uid, cmd_id)
        if ack and ack.get("ok"):
            shown = await _await_result(db, uid, cmd_id)
            if shown:
                return (
                    f"navigated: screen=explore, searching for {q}. "
                    f"Explore now shows: {shown}"
                )
            return (
                f"navigated: screen=explore, searching for {q}. The results "
                "hadn't finished loading — call current_screen (voice) or "
                "ask the user what they see."
            )
        return _NOT_NAVIGATED

    return search_explore


def _bind_open_profile(db, uid: str) -> Callable[..., str]:
    async def open_profile(name: str = "") -> str:
        other, full = _resolve_person(db, uid, name)
        if not other:
            return (
                f"I couldn't find someone called {name.strip() or 'that'} "
                "in the app."
            )
        cmd_id = _queue_command(
            db, uid, {"action": "open_profile", "uid": other}
        )
        ack = await _await_ack(db, uid, cmd_id)
        if ack and ack.get("ok"):
            # Hand the model the same honest briefing the chat/voice screen
            # context gives — who they are, any public wiki, whether a match
            # was actually computed — so it can't talk up a stranger it just
            # opened as "a great match" off a bare "profile is open" line
            # (founder bug 2026-10-25).
            briefing = await asyncio.to_thread(
                public_profile._viewing_profile_context, db, uid, other
            )
            opened = f"navigated: screen=profile — {full}'s profile is open."
            return f"{opened}\n{briefing}" if briefing else opened
        return _NOT_NAVIGATED

    return open_profile


def _bind_open_message_thread(db, uid: str) -> Callable[..., str]:
    async def open_message_thread(name: str = "") -> str:
        # Scoped to the people this user already has a `dm_threads` doc with —
        # so this only ever opens a real, existing conversation. For someone
        # new (no thread yet) that's `open_profile` instead.
        threads = await asyncio.to_thread(_dm_threads, db, uid)
        if not threads:
            return "I couldn't find any existing conversations to open."
        asked = name.strip()
        if not asked or _LAST_INTENT.match(asked.lower()):
            # "the last / most recent conversation" — threads are most-recent
            # first, so the head is the one they mean.
            target = threads[0]
        else:
            target, ambiguous = _best_thread(threads, asked)
            if ambiguous:
                names = ", ".join(t["name"] for t in ambiguous)
                return (
                    f"There's more than one conversation that could be "
                    f"'{asked}': {names}. Ask the user which one they mean — "
                    "don't guess."
                )
            if target is None:
                return (
                    f"I couldn't find an existing conversation with "
                    f"{asked}."
                )
        cmd_id = _queue_command(
            db, uid, {"action": "open_dm_thread", "uid": target["other"]}
        )
        ack = await _await_ack(db, uid, cmd_id)
        if ack and ack.get("ok"):
            return (
                f"navigated: screen=dm — the conversation with "
                f"{target['name']} is open."
            )
        return _NOT_NAVIGATED

    return open_message_thread


# No schema enum on purpose: livekit's `function_tool(fn, name=...,
# description=...)` serializes the *signature*, never `parameters`, so the
# valid keys must live in the description text (the model's only view).
# Each bind validates against the registry regardless.
_OPEN_SCREEN = {
    "name": "open_screen",
    "description": _prompt(
        "app_control_open_screen",
        DESTINATIONS=_SCREEN_LINES,
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
        "Open Explore and run a natural-language people search "
        "('find people who love hiking'), in the user's own words. The "
        "return says whether the app actually navigated — relay it honestly."
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
        "Open a person's profile by name, as the user said it. "
        "The return says whether the app actually navigated — relay it "
        "honestly."
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
        "Open the user's existing DM thread with a match. Pass the person's "
        "name as the user said it (a partial or slightly-off name is matched "
        "to their conversations), or 'last' / 'most recent' to open their most "
        "recently active conversation. If they haven't messaged that person "
        "yet, use open_profile instead. If more than one conversation could "
        "match, the return asks you to check which — don't guess. The return "
        "says whether the app actually navigated — relay it honestly."
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

_OPEN_MATCH_REPORT = {
    "name": "open_match_report",
    "description": (
        "Open the user's match report with a person, by name. If they were "
        "never matched, the return says so. The return says whether the app "
        "actually navigated — relay it honestly."
    ),
    "parameters": {
        "type": "object",
        "properties": {"name": {"type": "string"}},
        "required": ["name"],
    },
}
