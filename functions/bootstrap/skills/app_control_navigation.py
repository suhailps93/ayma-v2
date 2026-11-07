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
import re
from typing import Callable
from urllib.parse import quote

import app_registry
import public_profile
from pair_key import sorted_pair_key

from notifications_schema import NOTIF_DM, NOTIFICATIONS_COLLECTION

from .app_control_mirror import _best_thread, _dm_threads, _epoch, _LAST_INTENT
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
    if app_registry.find_guided_tour(asked):
        return _tour_redirect(asked)
    return (
        f"There is no '{asked}' page in the app — tell the user plainly it "
        "doesn't exist. Pages that do: "
        + ", ".join(f"{d['key']} ({d['label']})" for d in app_registry.destinations())
        + "."
    )


def _tour_redirect(asked: str) -> str:
    """The directive handed back when an open_screen request names the guided
    walkthrough: it is overlay-only (no page to open), so do NOT deny it —
    start it with the tour skill, which spotlights each control and waits for
    the user's real tap (Antigravity review 2026-11-03)."""
    return (
        f"'{asked}' isn't a page — it's the guided walkthrough, and there is "
        "no tour screen to open. Call start_guided_tour to begin it now (it "
        "spotlights each control in turn and waits for the user to tap); tell "
        "the user you're starting the tour."
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
    if via == "rerun_web_research":
        from . import rerun_web_research as _report

        # A re-run of the user's own web research — self only (never a third
        # party from an app-control phrase). Queues the SAME background refresh
        # the report screen's "Search again" button does and returns at once,
        # so this path never blocks on an inline search (founder bug 2026-11-03).
        return await _report.SKILL.bind(db, uid)()
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
        # F3: A mid-tour question must not hijack the tour with screen navigation
        from . import guided_tour
        tour_state = guided_tour._read_state(db, uid)
        if tour_state.get("active") and not guided_tour._state_expired(tour_state):
            return (
                "The guided tour is currently active — answer the user's question "
                "inline without navigating away or opening other screens."
            )
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


# --- deterministic pre-model navigation intent (brain-agnostic) ---------------
#
# The open-weights voice/chat brain (Llama-3.1-8B over the Modal vLLM endpoint,
# scripts/modal_open_weights.py --tool-call-parser llama3_json) is weak at
# tool-calling: it frequently emits the function NAME as plain assistant content
# ("open_model_page", "openamodelspace") instead of a structured tool call the
# parser recognises, so nothing runs and the raw token leaks as the reply
# (founder bug 2026-11-03). Mirroring set_model_stack.detect_stack_command (and
# the #28 provenance determinism), main._prepare_chat runs this matcher BEFORE
# the model, so a clear "open / go to <known page>" command fires the correct
# app-command regardless of which brain is active — and the weak brain never
# gets the chance to garble it. The capable brains (Gemini, Meta gateway) still
# emit the tool reliably; for them this only short-circuits the exact same
# navigation a hair sooner.
#
# Kept strict: a navigation verb AND a destination that resolves in the registry
# (app_registry.find_destination — the single source of truth), so ordinary chat
# is never intercepted. Story-edit and report-re-run phrasings (which also carry
# a verb and brush a destination's words) are deliberately excluded here so they
# still reach their own tools / the model with full context.
_APP_NAV_VERB = re.compile(
    r"\b(?:"
    r"open(?:\s+up|\s+back)?|"
    r"go(?:\s+back)?\s+to|goto|"
    r"take\s+me(?:\s+back)?\s+to|"
    r"bring\s+(?:me\s+)?(?:up|to)|pull\s+up|"
    r"show\s+me|"
    r"navigate(?:\s+back)?\s+to|"
    r"jump(?:\s+back)?\s+to|"
    r"back\s+to|"
    r"switch\s+to"
    r")\b",
    re.IGNORECASE,
)


def detect_app_command(message: str) -> str | None:
    """A clear, unambiguous "open / go to <known page>" command → the registry
    destination ``key`` to navigate to, else ``None``.

    Strict by design (so ordinary chat is never hijacked): requires a navigation
    verb AND a destination that resolves in ``app_registry``. A story-edit or a
    report-re-run request is excluded — those carry their own intent and must
    still reach their own tools / the model. :func:`run_app_command` executes the
    match through the same bound ``open_screen`` the model would call."""
    m = (message or "").strip()
    if not m or len(m) > 200:
        return None
    if not _APP_NAV_VERB.search(m):
        return None
    # A "change/remove … my story" or "rerun the appearance report" also brushes
    # a destination's words — leave those for their own tools / the model.
    if app_registry.find_story_edit_action(m) or app_registry.find_report_action(m):
        return None
    dest = app_registry.find_destination(m)
    if dest is None:
        return None
    return str(dest["key"])


async def run_app_command(db, uid: str, dest_key: str) -> str:
    """Execute a detected navigation command through the SAME bound
    ``open_screen`` the model would call, then translate its model-facing return
    into a short, honest line to show the user directly (the deterministic path
    has no model turn to relay it). A confirmed navigation reads as a plain
    "opening X"; anything else is relayed as an honest "couldn't switch" rather
    than a false success."""
    dest = app_registry.find_destination(dest_key)
    label = dest["label"] if dest else dest_key
    result = await _bind_open_screen(db, uid)(screen=dest_key)
    if isinstance(result, str) and result.startswith("navigated:"):
        return f"Opening {label} for you."
    return (
        f"I tried to open {label}, but the app didn't switch screens just now — "
        "you can also reach it yourself from the menu."
    )


# --- deterministic pre-model named-profile intent ---------------------------
#
# "open Sofia's profile" brushes the registry's own-profile destination, so
# detect_app_command claims it for the You tab and the name is dropped (Scout
# retest 2026-11-03, staging text lane — the voice lane resolves the same ask
# correctly through the skill's open_profile). A profile ask that NAMES a
# member is a different intent: detect it here and run it through the SAME
# bound open_profile (and its _resolve_person) the model / voice path uses —
# no second resolver. This detector runs BEFORE detect_app_command in the
# text lane's pre-model net (main._prepare_chat). A profile ask with no name
# returns None and keeps the existing route to the user's own profile; a name
# that resolves to nobody surfaces open_profile's own couldn't-find line — a
# clarification, never a silent landing on the You tab.
#
# The name is only ever read from AFTER the navigation verb, so the verb
# itself ("open Sofia's profile") can never leak into the captured name.
_PROFILE_TOKEN = r"[A-Za-z][A-Za-z.-]*"
_PROFILE_POSSESSIVE = re.compile(
    rf"\b(?P<name>{_PROFILE_TOKEN}(?:\s+{_PROFILE_TOKEN}){{0,2}})['’]s\s+profile\b",
    re.IGNORECASE,
)
_PROFILE_OF = re.compile(
    rf"\bprofile\s+of\s+(?P<name>{_PROFILE_TOKEN}(?:\s+{_PROFILE_TOKEN}){{0,2}})",
    re.IGNORECASE,
)
# Heads that name nobody in particular ("profile of my match") — those keep
# the existing own-profile / model routes.
_PROFILE_GENERIC_HEADS = frozenset(
    "my your his her their our the a an this that mine yours hers theirs".split()
)
# Trailing filler that rides along in the "profile of <name> …" tail.
_PROFILE_TAIL_FILLER = frozenset("please thanks now today".split())


def _clean_profile_name(raw: str) -> str | None:
    """The captured name tail, tidied — or ``None`` when it names nobody in
    particular (a generic/pronoun head) or nothing at all."""
    words = [w.strip(".,!?;:\"'’") for w in raw.split()]
    words = [w for w in words if w]
    while words and words[-1].lower() in _PROFILE_TAIL_FILLER:
        words.pop()
    if not words or words[0].lower() in _PROFILE_GENERIC_HEADS:
        return None
    if any(w.lower() in ("profile", "page") for w in words):
        return None
    return " ".join(words)


def detect_profile_command(message: str) -> str | None:
    """A clear "open / go to <member>'s profile" (or "the profile of
    <member>") ask → the member name as said, else ``None``.

    Strict like the rest of this layer: a navigation verb AND a named member
    in possessive or "profile of" form. A nameless profile ask ("open my
    profile") returns ``None`` — :func:`detect_app_command` keeps routing
    it to the user's own profile — and so do story-edit / report phrasings.
    :func:`run_profile_command` executes the match through the bound
    ``open_profile``."""
    m = (message or "").strip()
    if not m or len(m) > 200:
        return None
    verb = _APP_NAV_VERB.search(m)
    if verb is None:
        return None
    if app_registry.find_story_edit_action(m) or app_registry.find_report_action(m):
        return None
    rest = m[verb.end():]
    hit = _PROFILE_POSSESSIVE.search(rest) or _PROFILE_OF.search(rest)
    if hit is None:
        return None
    return _clean_profile_name(hit.group("name"))


async def run_profile_command(db, uid: str, name: str) -> str:
    """Execute a detected named-profile command through the SAME bound
    ``open_profile`` the model would call — its ``_resolve_person`` is the
    one resolver — then translate its model-facing return into a short line
    for the user (the deterministic path has no model turn to relay it). A
    confirmed open reads as a plain "opening X's profile"; an unresolvable
    name surfaces the tool's own couldn't-find line verbatim (the skill's
    clarification style) instead of a silent You-tab landing; no ack is the
    honest "didn't switch" line, never a false success."""
    result = await _bind_open_profile(db, uid)(name=name)
    if isinstance(result, str) and result.startswith("navigated:"):
        opened = result.split("—", 1)[-1].strip()
        full = opened.split("'s profile", 1)[0].strip() or name
        return f"Opening {full}'s profile for you."
    if isinstance(result, str) and result.startswith("I couldn't find"):
        return result
    return (
        "I tried to open that profile, but the app didn't switch screens "
        "just now — you can also reach it from Explore."
    )


# --- deterministic pre-model launch intent (voice backstop) ------------------
#
# Mirrors detect_app_command above: a clear "start a practice date / run a
# date sim with <name>" is executed BEFORE the model, so it fires even when
# the realtime model would otherwise refuse the launch from the call
# (founder, prod 2284). The voice lane runs this matcher on each finalized
# user turn (agent.py); the text lane is untouched — its model already emits
# these tools reliably.
#
# Kept strict: a launch verb AND the feature surface (singular — the plural
# talks about the category, never launches one), so ordinary chat is never
# intercepted. A result/report/debrief request is excluded — those stay with
# the model. The partner name is the raw tail after "with"/"for" (the tool's
# own resolver fuzzy-matches it); a tail naming nobody in particular, or no
# tail at all, yields a None partner — the relay answers those with the "who
# with?" clarification instead of launching.
_LAUNCH_VERB = re.compile(
    r"\b(?:"
    r"start|begin|launch|restart|open(?:\s+up)?|run|simulate|"
    r"set\s+up|kick\s+off|give\s+me"
    r")\b",
    re.IGNORECASE,
)
_PRACTICE_SURFACE = re.compile(r"\bpractice\s+date\b", re.IGNORECASE)
_SIM_SURFACE = re.compile(
    r"\bdat(?:e|ing)\s+sim(?:ulation)?\b|"
    r"\bagent\s+date\b|"
    r"\bagent[\s\-]+to[\s\-]+agent\b|"
    r"\bai\s+date\b",
    re.IGNORECASE,
)
_SIM_WORD = re.compile(r"\bsimulat\w*\b|\bsims?\b", re.IGNORECASE)
_DATE_WORD = re.compile(r"\bdate\b", re.IGNORECASE)
# "let me practice with Daniel" carries no launch verb of its own, so a
# request framing plus the practice verb plus "with" launches too.
_PRACTICE_FRAMING = re.compile(
    r"\blet\s+me\b|\blet'?s\b|\blet\s+us\b|\bcan\s+i\b|\bcould\s+i\b|"
    r"\bi\s+want\s+to\b|\bwanna\b|\bhelp\s+me\b|"
    r"\bi'?d\s+like\s+to\b|\bi\s+need\s+to\b",
    re.IGNORECASE,
)
_PRACTICE_VERB = re.compile(r"\bpractice\b", re.IGNORECASE)
_WITH_FOR = re.compile(r"\bwith\b|\bfor\b", re.IGNORECASE)
_LAUNCH_RESULT_WORD = re.compile(
    r"\bresults?\b|\breports?\b|\bdebrief\b", re.IGNORECASE
)
# A verb-less "practice date with Sofia" still launches — but only with a
# named partner and no past-talk / existential marker, so "my practice date
# with Sofia went well" stays a story for the model.
_VERBLESS_EXCLUDE = re.compile(
    r"\byesterday\b|\bwent\b|\bwas\b|\bwere\b|\bago\b|"
    r"\blast\s+night\b|\benjoyed\b|"
    r"\bis\s+there\b|\bare\s+there\b",
    re.IGNORECASE,
)
# First words that name nobody in particular ("with my girlfriend" is a
# partner-less ask, not a launch for someone called "girlfriend").
_GENERIC_PARTNER_HEAD = frozenset(
    "my a an some any the this that these those someone somebody "
    "anyone anybody everyone everybody nobody people friends guys".split()
)
_GENERIC_PARTNER = frozenset(
    "me myself you yourself yourselves him her them themselves "
    "us ourselves it".split()
)


def _launch_partner(message: str) -> str | None:
    """The raw partner tail after the first "with"/"for", or ``None`` when
    there is no tail or it names nobody in particular (the tool's resolver
    fuzzy-matches a real tail, so only the generic heads are filtered)."""
    hit = _WITH_FOR.search(message)
    if hit is None:
        return None
    tail = message[hit.end():].strip().strip(".,!?;:\"'").strip()
    if not tail:
        return None
    words = tail.lower().split()
    if words[0] in _GENERIC_PARTNER_HEAD or tail.lower() in _GENERIC_PARTNER:
        return None
    return tail


def detect_launch_command(message: str) -> tuple[str, str | None] | None:
    """A clear, unambiguous Practice Date / Agent Date launch ask →
    ``(tool_name, partner)``, else ``None``.

    Strict by design (so ordinary chat is never hijacked): requires a launch
    verb AND the feature surface, or a request framing plus "practice with",
    or the verb-less surface with a named partner. ``partner`` is the raw
    name tail for the tool's resolver, or ``None`` for a partner-less ask —
    the voice relay answers those with :func:`launch_clarification` instead
    of launching. One command per turn: practice wins a both-surfaces tie."""
    m = (message or "").strip()
    if not m or len(m) > 200:
        return None
    if _LAUNCH_RESULT_WORD.search(m):
        return None
    practice = _PRACTICE_SURFACE.search(m) is not None
    sim = _SIM_SURFACE.search(m) is not None or (
        _SIM_WORD.search(m) is not None and _DATE_WORD.search(m) is not None
    )
    practice_verb = _PRACTICE_VERB.search(m) is not None
    if not (practice or sim or practice_verb):
        return None
    if _LAUNCH_VERB.search(m):
        if practice:
            return "open_practice_date", _launch_partner(m)
        if sim:
            return "open_date_sim", _launch_partner(m)
        return None  # a verb plus a bare "practice" stays with the model
    if (
        practice_verb
        and _PRACTICE_FRAMING.search(m) is not None
        and _WITH_FOR.search(m) is not None
    ):
        return "open_practice_date", _launch_partner(m)
    if _VERBLESS_EXCLUDE.search(m):
        return None
    partner = _launch_partner(m)
    if partner is None:
        return None
    # Verb-less arm: the full feature phrase must be present (a bare
    # "practice" / "simulate … date" with a name stays with the model).
    if practice:
        return "open_practice_date", partner
    if _SIM_SURFACE.search(m) is not None:
        return "open_date_sim", partner
    return None


_LAUNCH_WHO_WITH = {
    "open_practice_date": (
        "No name was given — ask the user who they want the practice date "
        "with, and call open_practice_date again only once they name someone."
    ),
    "open_date_sim": (
        "No name was given — ask the user who they want the AI date "
        "simulation with, and call open_date_sim again only once they name "
        "someone."
    ),
}


def launch_clarification(tool_name: str) -> str:
    """The claimed result for a partner-less launch turn: a directive that
    drives the model to ask who the partner is (the voice counterpart to the
    text lane's tool result driving the reply) — never a launch, never a
    "couldn't find someone" error."""
    return _LAUNCH_WHO_WITH[tool_name]


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


def _bind_open_date_sim(db, uid: str) -> Callable[..., str]:
    async def open_date_sim(name: str = "") -> str:
        other, full = await asyncio.to_thread(_resolve_person, db, uid, name)
        if not other:
            return (
                f"I couldn't find someone called {name.strip() or 'that'} "
                "in the app."
            )
        return await _navigate(
            db, uid, "date_sim", f"/date-sim/{other}",
            f"the AI date simulation with {full} (the setup screen — "
            "nothing is sent to them; they run it from there)",
        )

    return open_date_sim


def _bind_open_practice_date(db, uid: str) -> Callable[..., str]:
    async def open_practice_date(name: str = "") -> str:
        other, full = await asyncio.to_thread(_resolve_person, db, uid, name)
        if not other:
            return (
                f"I couldn't find someone called {name.strip() or 'that'} "
                "in the app."
            )
        return await _navigate(
            db, uid, "practice_date", f"/practice/{other}",
            f"the practice date with {full} (a clearly-labelled simulator "
            "built from their public profile)",
        )

    return open_practice_date


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


def _unread_notifications(db, uid: str, limit: int = 50) -> list[dict]:
    """The user's unread notifications, most-recent first — the same list the
    notification centre's badge counts (``NotificationService.watchUnreadCount``):
    ``read == False``, not dismissed, DMs excluded (those surface as the
    Messages tab's badge, never the centre). Each entry is ``{id, deep_link,
    body, type}``. A notification with no ``deep_link`` still opens (the
    client lands it on the Ayma tab), so those are kept."""
    try:
        snaps = list(
            db.collection("users")
            .document(uid)
            .collection(NOTIFICATIONS_COLLECTION)
            .where("read", "==", False)
            .stream()
        )
    except Exception:  # noqa: BLE001
        logger.exception("listing notifications failed for %s", uid)
        return []
    out: list[dict] = []
    for snap in snaps:
        d = snap.to_dict() or {}
        if d.get("dismissed"):
            continue
        if d.get("type") == NOTIF_DM:
            continue
        out.append(
            {
                "id": snap.id,
                "deep_link": str(d.get("deep_link") or "").strip(),
                "body": str(d.get("body") or "").strip(),
                "type": str(d.get("type") or ""),
                "_at": _epoch(d.get("created_at")),
            }
        )
    out.sort(key=lambda n: n["_at"], reverse=True)
    return out[:limit]


def _bind_go_back(db, uid: str) -> Callable[..., str]:
    async def go_back() -> str:
        # One step back in the client's session navigation history
        # (feedback item 15). The client owns the stack and the edge
        # cases; this tool relays its ack honestly, kind by kind:
        # * navigated — say where the user landed;
        # * dismissed_modal — a pop-up/sheet was up, so this back closed
        #   it and the user stayed on the page (the client's line says so);
        # * at_root / tour_active — the client's reason IS the sayable
        #   answer ("nowhere to go back to", "a tour is showing"), not a
        #   failure to soften into _NOT_NAVIGATED.
        cmd_id = _queue_command(db, uid, {"action": "go_back"})
        ack = await _await_ack(db, uid, cmd_id)
        if not ack:
            return _NOT_NAVIGATED
        kind = str(ack.get("kind") or "").strip()
        if ack.get("ok") and kind == "navigated":
            current = str(ack.get("current") or "").strip()
            return (
                f"navigated back: the user is now on "
                f"{current or 'the previous page'}."
            )
        if ack.get("ok") and kind == "dismissed_modal":
            result = str(ack.get("result") or "").strip()
            return result or (
                "Closed that first — the user is still on the same page."
            )
        reason = str(ack.get("reason") or "").strip()
        if reason:
            return reason
        return _NOT_NAVIGATED

    return go_back


def _bind_open_notification(db, uid: str) -> Callable[..., str]:
    async def open_notification() -> str:
        # One ask opens the latest unread notification's DESTINATION directly
        # (founder bug 2026-11-02: "open the Android notification" went to
        # notification *preferences*, then just the list, and only a third
        # screen-reading ask reached the report). The client resolves the
        # deep link to its route (the same `deepLinkToRoute` a centre tap
        # uses); the notification is marked read only once the client acks
        # the open — no ack, no mark, honest failure instead.
        notifs = await asyncio.to_thread(_unread_notifications, db, uid)
        if not notifs:
            return (
                "You have no unread notifications — nothing to open. "
                "The notification list is still there under the bell if "
                "they want to browse it."
            )
        head = notifs[0]
        cmd_id = _queue_command(
            db,
            uid,
            {
                "action": "open_notification",
                "notification_id": head["id"],
                "deep_link": head["deep_link"],
            },
        )
        ack = await _await_ack(db, uid, cmd_id)
        if not (ack and ack.get("ok")):
            return _NOT_NAVIGATED
        try:
            await asyncio.to_thread(
                db.collection("users")
                .document(uid)
                .collection(NOTIFICATIONS_COLLECTION)
                .document(head["id"])
                .set,
                {"read": True},
                merge=True,
            )
        except Exception:  # noqa: BLE001 - badge heals on next open anyway
            logger.exception(
                "marking notification %s read failed for %s", head["id"], uid
            )
        preview = head["body"][:120] or "notification"
        return (
            f"navigated: screen=notification — opened their latest "
            f"notification ({preview})."
        )

    return open_notification


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

_GO_BACK = {
    "name": "go_back",
    "description": (
        "Take the user back to the previous page they were on ('go back', "
        "'take me back'). The app remembers the session's pages whether the "
        "user navigated there or you took them there, including tab pages. "
        "One step per call — call it again to go back another page. If a "
        "pop-up or sheet is open, this closes that first and the user stays "
        "on the page. If a tour is showing, it does not go back and the "
        "return says why. At the first page there is nowhere to go back to "
        "and the return says so — relay it honestly, never invent a page. "
        "Prefer this over ui_action back for page-level 'back' requests: "
        "it knows the previous PAGE, not just the route stack. The return "
        "says where the user ended up."
    ),
    "parameters": {"type": "object", "properties": {}},
}

_OPEN_NOTIFICATION = {
    "name": "open_notification",
    "description": _prompt("app_control_open_notification"),
    "parameters": {
        "type": "object",
        "properties": {},
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

_OPEN_DATE_SIM = {
    "name": "open_date_sim",
    "description": (
        "Open the AI Date Simulation (also called an Agent Date or "
        "agent-to-agent simulation) with a person, by name as the user said "
        "it. This is a real, core feature: the user's AI and the other "
        "person's AI run a preview conversation, then you get a compatibility "
        "read — nothing is sent to that person. Use this whenever the user "
        "wants to 'run an agent-to-agent sim', 'simulate a date', 'do an "
        "agent date', or 'see how our AIs get along' with someone. It opens "
        "the setup screen; the user runs it from there. The return says "
        "whether the app actually navigated — relay it honestly."
    ),
    "parameters": {
        "type": "object",
        "properties": {"name": {"type": "string"}},
        "required": ["name"],
    },
}

_OPEN_PRACTICE = {
    "name": "open_practice_date",
    "description": (
        "Open a Practice Date with a person, by name as the user said it. "
        "This is a real, core feature: a clearly-labelled simulator where a "
        "persona built from that person's public profile lets the user "
        "rehearse talking to them (by text or voice). Use this whenever the "
        "user wants to 'chat with someone's agent/avatar', 'talk to their "
        "AI', 'practice a date', or 'rehearse messaging' a specific person — "
        "it is NOT a policy refusal, it is this feature. The return says "
        "whether the app actually navigated — relay it honestly."
    ),
    "parameters": {
        "type": "object",
        "properties": {"name": {"type": "string"}},
        "required": ["name"],
    },
}


# --- deterministic pre-model go-back intent (feedback item 15) --------------
#
# "go back" / "take me back" with NO destination is a different intent from
# "go back to Explore" (a destination open — :func:`detect_app_command`,
# whose verb set already includes "go back to" / "back to"). This matcher
# is anchored to the WHOLE utterance, so a destination tail can never
# match it, and ordinary chat ("back in the day", "call me back", "get
# back to me") never does either. Both lanes run it BEFORE the model like
# the other app commands (main._prepare_chat for text, agent.py's
# detect_voice_command for voice), so it fires regardless of which brain
# is active; :func:`run_go_back_command` executes it through the SAME
# bound ``go_back`` tool the model would call.
_GO_BACK_RE = re.compile(
    r"(?:please\s+)?(?:"
    r"go\s+back|take\s+me\s+back|head\s+back|"
    r"(?:go\s+back\s+to|back\s+to|return\s+to)\s+the\s+previous\s+(?:page|screen)|"
    r"previous\s+(?:page|screen)|back"
    r")(?:\s+please)?",
    re.IGNORECASE,
)


def detect_go_back_command(message: str) -> bool:
    """A clear, destination-less "go back" / "take me back" → True.

    Strict by design: the whole (short) utterance must be the back phrase
    itself, so "go back to Explore" keeps routing to that page and no
    narrative sentence is ever intercepted."""
    m = (message or "").strip().rstrip(".!").strip()
    if not m or len(m) > 200 or len(m.split()) > 8:
        return False
    return _GO_BACK_RE.fullmatch(m) is not None


async def run_go_back_command(db, uid: str) -> str:
    """Execute a detected go-back through the bound ``go_back`` tool and
    translate its model-facing return into a short line for the user (the
    deterministic path has no model turn to relay it). The at-root, tour
    and modal lines the tool returns are already user-facing sentences
    and pass through verbatim; no ack is the honest didn't-work line."""
    result = await _bind_go_back(db, uid)()
    prefix = "navigated back: the user is now on "
    if isinstance(result, str) and result.startswith(prefix):
        label = result[len(prefix):].rstrip(".").strip()
        return f"Taking you back to {label}." if label else "Going back for you."
    if result == _NOT_NAVIGATED:
        return (
            "I tried to take you back, but the app didn't respond just "
            "now — try again in a moment."
        )
    return result
