"""App-control tools: let Ayma *see* (voice) and *drive* (voice and text) the app.

``current_screen`` is voice-only — ``/chat`` already carries the screen the
user is on in its own request context. The five command tools
(:data:`COMMAND_SKILLS`) are registered in both the voice tool set
(:func:`skills.make_livekit_tools`) and the text chat tool set
(:func:`skills.make_session_tool_fns`): the Flutter client watches the command
doc whenever the app is foregrounded, not only during a call.

* ``current_screen`` — read the mirror that ``POST /voice/context`` keeps at
  ``users/{uid}/voice_context/current`` while a call is live, so Ayma knows
  what "them / this / here" refers to.
* ``open_screen`` / ``search_explore`` / ``open_profile`` / ``open_message_thread``
  / ``app_action`` — queue one UI command at ``users/{uid}/app_commands/pending``;
  the Flutter client (``AppCommandService``) watches that doc while the app is
  foregrounded (a live call or the chat page), performs the navigation/action, acks it at
  ``users/{uid}/app_commands/ack`` (``{id, ok}``), then deletes it.

Closing the loop (founder bug, 2026-09-26 — "I've opened your profile" while
the app never left the chat screen): a queued command is *intent*, not fact —
Firestore's watch stream on the phone can be down mid-call while the REST
mirror keeps working, so delivery is not guaranteed. Every command therefore
carries a unique ``id``, and each tool *waits* (bounded,
``_ACK_TIMEOUT_SECONDS``) for the client's ack of that exact id before
returning. Confirmed → ``navigated: …``; no ack in time → an explicit "the
app did NOT navigate" so the model tells the user the truth instead of
claiming success.

Every page and setting comes from ``app_registry.json`` (``app_registry``),
the single source of truth (founder bug, 2026-10-25: asked to open the "Your
profile is 59% complete" card, Ayma said no such page existed). ``open_screen``
opens any registered destination by key or the user's own words and sends the
client the route ``path`` to push; ``app_action`` changes any registered
setting; ``account_action`` runs the destructive ones (sign out, delete
account, withdraw consent, wipe memory) only after an explicit confirmation
in a later turn.
Pages that need a specific person/record go through ``open_profile``,
``open_message_thread`` and ``open_match_report``. Payment pages only ever
open; nothing here can buy anything.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
import uuid
from pathlib import Path
from typing import Callable
from urllib.parse import quote

import app_registry
import public_profile
from pair_key import sorted_pair_key

from . import read_dm_thread
from ._base import Skill, last_user_quote

logger = logging.getLogger("ayma.app_control")

# A mirror older than this is treated as "nothing open" — the user closed the
# app or moved on and the client stopped updating. The client re-pushes on a
# ~45s heartbeat for the whole call, so this only needs enough slack to ride
# out a missed beat or two (a backgrounded app, a flaky network).
_STALE_SECONDS = 300

# How long a command tool waits for the client's ack before reporting the
# navigation as NOT having happened. The client acks the instant it executes
# (one snapshot delivery + one write), so a healthy round trip is well under
# a second; 3s rides out one watch-stream hiccup without stalling the voice
# turn unnaturally long. Module-level so tests can shrink them.
_ACK_TIMEOUT_SECONDS = 3.0
_ACK_POLL_SECONDS = 0.25

# After a search_explore is acked, how long to wait for the client to report
# the loaded results (the feed is a network call after navigation) and the
# cap on how much of that report reaches the model.
_RESULT_TIMEOUT_SECONDS = 6.0
_RESULT_MAX_CHARS = 1500

# The shared honest-failure line for every navigation tool — the model must
# relay this, not soften it into a success.
_NOT_NAVIGATED = (
    "The app did NOT navigate — tell the user it didn't work and where to "
    "find it themselves."
)
_NOT_APPLIED = "The app did NOT apply that — tell the user it didn't work."

# Every destination key ``open_screen`` accepts. Routes deliberately left out
# (auth/onboarding, hidden Google/Instagram linking, the developer panel, …)
# are listed with their reason under ``non_navigable`` in the registry.
_SCREENS = tuple(d["key"] for d in app_registry.destinations())

_PROMPTS = Path(__file__).resolve().parent.parent / "prompts"


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


def _ack_doc(db, uid: str):
    return (
        db.collection("users")
        .document(uid)
        .collection("app_commands")
        .document("ack")
    )


def _queue_command(db, uid: str, payload: dict) -> str:
    """Write one UI command to the pending doc with a fresh unique ``id``
    (what the client's ack echoes back) and return that id."""
    cmd_id = uuid.uuid4().hex
    _command_doc(db, uid).set({**payload, "id": cmd_id, "ts": _server_ts()})
    return cmd_id


async def _await_ack(db, uid: str, cmd_id: str) -> dict | None:
    """Poll the ack doc until the client acknowledges ``cmd_id`` or the
    bounded wait runs out. Returns the ack dict (``{id, ok, …}``) or ``None``
    on timeout. Firestore reads run in a thread so the LiveKit agent's event
    loop (live audio) is never blocked by a poll."""
    deadline = time.monotonic() + _ACK_TIMEOUT_SECONDS
    while True:
        try:
            snap = await asyncio.to_thread(_ack_doc(db, uid).get)
            data = snap.to_dict() if getattr(snap, "exists", False) else None
        except Exception:  # noqa: BLE001
            data = None
        if data and str(data.get("id") or "") == cmd_id:
            return data
        if time.monotonic() >= deadline:
            return None
        await asyncio.sleep(_ACK_POLL_SECONDS)


async def _await_result(db, uid: str, cmd_id: str) -> str:
    """Poll the ack doc until the client adds the ``result`` text for
    ``cmd_id`` (what Explore shows after the search loaded), or the bounded
    wait runs out. Returns ``""`` on timeout."""
    deadline = time.monotonic() + _RESULT_TIMEOUT_SECONDS
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
        await asyncio.sleep(_ACK_POLL_SECONDS)


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


def _not_a_page(asked: str) -> str:
    """The honest answer for a request that matches no destination: the
    registry's own explanation when it's a known-unavailable thing, a pointer
    to the right tool when it's a setting/action, otherwise "doesn't exist"
    with the real list."""
    gone = app_registry.find_unavailable(asked)
    if gone:
        return f"Not available: {gone['say']}"
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


def _bind_open_screen(db, uid: str) -> Callable[..., str]:
    async def open_screen(screen: str = "") -> str:
        dest = app_registry.find_destination(screen)
        if dest is None:
            return _not_a_page(screen.strip())
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
            return f"navigated: screen=profile — {full}'s profile is open."
        return _NOT_NAVIGATED

    return open_profile


def _bind_open_message_thread(db, uid: str) -> Callable[..., str]:
    async def open_message_thread(name: str = "") -> str:
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
        cmd_id = _queue_command(
            db, uid, {"action": "open_dm_thread", "uid": other}
        )
        ack = await _await_ack(db, uid, cmd_id)
        if ack and ack.get("ok"):
            return (
                f"navigated: screen=dm — the conversation with "
                f"{name.strip()} is open."
            )
        return _NOT_NAVIGATED

    return open_message_thread


# The earlier one-word action names, still accepted (and still the exact
# client command names, so an older app build keeps working): each maps to a
# registry setting and value.
_LEGACY_ACTIONS = {
    "dark_mode": ("theme", "dark"),
    "light_mode": ("theme", "light"),
    "system_theme": ("theme", "system"),
    "pause_matching": ("pause_matching", "on"),
    "resume_matching": ("pause_matching", "off"),
}

_ON = frozenset("on true yes enable enabled show unmute start 1".split())
_OFF = frozenset("off false no disable disabled hide mute stop 0".split())


# The app's default accent (Cherry Fuchsia), reported as the current accent
# until the user has picked one.
_DEFAULT_ACCENT = "#DA4B65"

_HEX_DIGITS = frozenset("0123456789abcdef")


def _resolve_accent(value: str) -> str | None:
    """Normalised ``#RRGGBB`` for a valid hex, else ``None``. Any colour is
    accepted exactly as given, with no snapping to a preset; Ayma translates
    names and descriptions into a hex herself."""
    raw = value.strip().lstrip("#").lower()
    if len(raw) == 6 and set(raw) <= _HEX_DIGITS:
        return "#" + raw.upper()
    return None


def _current_accent(db, uid: str) -> str:
    try:
        snap = (
            db.collection("users")
            .document(uid)
            .collection("profile")
            .document("main")
            .get()
        )
        data = snap.to_dict() if snap.exists else None
    except Exception:
        data = None
    hexcode = _resolve_accent(str((data or {}).get("ayma_accent_color") or ""))
    return hexcode or _DEFAULT_ACCENT


def _normalise_value(setting: dict, value: str) -> str | None:
    """The canonical value for ``setting`` (``on``/``off``, an enum member, a
    ``#RRGGBB`` hex, ``"min-max"``), or ``None`` when ``value`` isn't one."""
    kind = setting["kind"]
    v = value.strip().lower()
    if kind == "bool":
        return "on" if v in _ON else "off" if v in _OFF else None
    if kind == "hex":
        return _resolve_accent(value)
    if kind == "enum":
        v = re.sub(r"\s*(miles?|mi)\b", "", v).strip()
        v = {"auto": "system", "match system": "system", "any": "anywhere",
             "anywhere is fine": "anywhere"}.get(v, v)
        return v if v in setting["values"] else None
    if kind == "age_range":
        nums = [int(n) for n in re.findall(r"\d+", v)]
        return f"{nums[0]}-{nums[1]}" if len(nums) == 2 else None
    return None


def _apply_server_setting(db, uid: str, setting: dict, value: str) -> str:
    """Write a server-held setting exactly where its screen saves it. Returns
    the confirmation, or raises ``ValueError`` with a user-facing reason."""
    handler = setting["handler"]
    if handler == "notification_pref":
        import notifications_ops
        from notifications_schema import NOTIFICATION_TYPES

        cats = (
            NOTIFICATION_TYPES if setting["category"] == "*"
            else (setting["category"],)
        )
        for cat in cats:
            notifications_ops.set_pref(db, uid, cat, value == "on")
        return f"Done: {setting['label']} turned {value}."
    from . import questionnaire

    if handler == "partner_age_range":
        lo, hi = (int(n) for n in value.split("-"))
        questionnaire.save_partner_preferences(db, uid, age_min=lo, age_max=hi)
        return f"Done: partner age range set to {lo}-{hi}."
    if handler == "distance_pref":
        questionnaire.save_partner_preferences(db, uid, distance_pref=value)
        shown = "anywhere" if value == "anywhere" else f"{value} miles"
        return f"Done: distance preference set to {shown}."
    raise ValueError(f"no handler for {setting['key']}")


def _bind_app_action(db, uid: str) -> Callable[..., str]:
    async def app_action(action: str = "", value: str = "") -> str:
        a = action.strip().lower()
        if a == "get_accent_color":
            return (
                f"The app's current accent colour is {_current_accent(db, uid)}."
            )
        if a in _LEGACY_ACTIONS and (
            not value.strip() or a != _LEGACY_ACTIONS[a][0]
        ):
            a, value = _LEGACY_ACTIONS[a]
        gone = app_registry.find_unavailable(a, exact=True)
        if gone:
            return f"Not available: {gone['say']}"
        setting = app_registry.find_setting(a)
        if setting is None:
            act = app_registry.find_account_action(a)
            if act:
                return (
                    f"'{action.strip()}' is a destructive action — use "
                    f"account_action {act['key']}, which asks the user to "
                    "confirm first."
                )
            gone = app_registry.find_unavailable(a)
            if gone:
                return f"Not available: {gone['say']}"
            return (
                f"There is no '{action.strip()}' setting in the app — tell the "
                "user plainly. Settings that exist: "
                + ", ".join(s["key"] for s in app_registry.settings())
                + ", plus get_accent_color."
            )
        if setting["handler"] == "tool":
            return f"Use {setting['via']} for that ({setting['label']})."
        v = _normalise_value(setting, value)
        if v is None:
            if setting["kind"] == "hex":
                return (
                    f"'{value.strip()}' is not a valid colour. Pass any colour "
                    "as a #RRGGBB hex."
                )
            allowed = {
                "bool": "on or off",
                "age_range": "two ages like 25-35",
            }.get(setting["kind"], " / ".join(setting.get("values") or []))
            return f"'{value.strip()}' isn't a value for {setting['key']}: use {allowed}."
        if setting["handler"] != "client":
            try:
                return await asyncio.to_thread(
                    _apply_server_setting, db, uid, setting, v
                )
            except ValueError as exc:
                return f"Couldn't change that: {exc}."
            except Exception:  # noqa: BLE001
                logger.exception("setting %s failed for %s", setting["key"], uid)
                return _NOT_APPLIED
        command = setting["client_command"]
        payload = (
            {"action": "app_action", "name": command[v]}
            if isinstance(command, dict)
            else {"action": "app_action", "name": command, "value": v}
        )
        cmd_id = _queue_command(db, uid, payload)
        ack = await _await_ack(db, uid, cmd_id)
        if not (ack and ack.get("ok")):
            return _NOT_APPLIED
        if setting["kind"] == "hex":
            return f"Changed the app's accent colour to {v}."
        done = (setting.get("done") or {}).get(v)
        return done or f"Done: {setting['label']} turned {v}."

    return app_action


# How long a proposed destructive action stays confirmable, and (voice, where
# the tool can't see the transcript) the minimum gap between asking and the
# confirmation — so a model can't ask and confirm inside one turn.
_CONFIRM_TTL_SECONDS = 180.0
_CONFIRM_MIN_GAP_SECONDS = 4.0
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
        confirmed = confirmed is True or str(confirmed).strip().lower() in (
            "true", "yes", "1"
        )
        act = app_registry.find_account_action(action)
        if act is None:
            gone = app_registry.find_unavailable(action)
            if gone:
                return f"Not available: {gone['say']}"
            return (
                f"There is no '{action.strip()}' account action — tell the user "
                "plainly. Actions that exist: "
                + ", ".join(a["key"] for a in app_registry.account_actions())
                + "."
            )
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
        elif age < _CONFIRM_MIN_GAP_SECONDS:
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
        if act["key"] == "withdraw_consent":
            return (
                "Done: consent withdrawal started — face data is deleted, then "
                "the account, and the app is signing them out."
            )
        if act["key"] == "delete_account":
            return (
                "Done: account deletion started; the app is signing them out. "
                "They can recover it by signing back in within 30 days."
            )
        return "Done: signing them out now."

    return account_action


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

def _prompt(name: str, **fill: str) -> str:
    """A tool description from ``prompts/<name>.md`` with its ``{{KEY}}``
    slots filled from the registry, so the capability list the model reads is
    always the registry itself."""
    text = (_PROMPTS / f"{name}.md").read_text(encoding="utf-8").strip()
    for key, value in fill.items():
        text = text.replace("{{" + key + "}}", value)
    return text


def _setting_line(s: dict) -> str:
    if s["kind"] == "enum":
        return f"{s['key']} ({'|'.join(s['values'])})"
    if s["kind"] == "hex":
        return f"{s['key']} (#RRGGBB)"
    if s["kind"] == "age_range":
        return f"{s['key']} (min-max, 18+)"
    return f"{s['key']} (on|off)"


# No schema enum on purpose: livekit's `function_tool(fn, name=...,
# description=...)` serializes the *signature*, never `parameters`, so the
# valid keys must live in the description text (the model's only view).
# Each bind validates against the registry regardless.
_OPEN_SCREEN = {
    "name": "open_screen",
    "description": _prompt(
        "app_control_open_screen",
        DESTINATIONS=", ".join(_SCREENS),
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
        "Open the user's existing DM thread with a match, by "
        "name. If they haven't messaged that person yet, use open_profile "
        "instead. The return says whether the app actually navigated — "
        "relay it honestly."
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
    "description": _prompt(
        "app_control_app_action",
        SETTINGS=", ".join(
            _setting_line(s) for s in app_registry.settings()
            if s["handler"] != "tool"
        ),
        VIA_TOOLS="; ".join(
            f"{s['via']}: {s['label']}" for s in app_registry.settings()
            if s["handler"] == "tool"
        ),
    ),
    "parameters": {
        "type": "object",
        "properties": {"action": {"type": "string"}, "value": {"type": "string"}},
        "required": ["action"],
    },
}

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


# Shared by voice and text chat: each queues one command and waits for the
# client's ack of that exact id (or, for server-held settings, writes them).
COMMAND_SKILLS: list[Skill] = [
    Skill(declaration=_OPEN_SCREEN, bind=_bind_open_screen),
    Skill(declaration=_SEARCH_EXPLORE, bind=_bind_search_explore),
    Skill(declaration=_OPEN_PROFILE, bind=_bind_open_profile),
    Skill(declaration=_OPEN_MESSAGE_THREAD, bind=_bind_open_message_thread),
    Skill(declaration=_OPEN_MATCH_REPORT, bind=_bind_open_match_report),
    Skill(declaration=_APP_ACTION, bind=_bind_app_action),
    Skill(declaration=_ACCOUNT_ACTION, bind=_bind_account_action),
]

VOICE_SKILLS: list[Skill] = [
    Skill(declaration=_CURRENT_SCREEN, bind=_bind_current_screen),
    *COMMAND_SKILLS,
]
