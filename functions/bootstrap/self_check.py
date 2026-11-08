"""``self_check`` — the deterministic ``/self-check`` capability runner.

Founder order 2026-11-06 (~22:39 PT): typing ``/self-check`` in chat makes
Ayma run through ALL of its capabilities one at a time — opening every
page, editing something and reverting it, using every tool — then post a
pass/fail report in chat, auto-filing a bug report (the ``report_bug``
path, :mod:`bug_reports_ops`) at the moment each failure happens.

Why deterministic: in voice session ``s-0Y9QgcivBffTuLNJyDe0IN`` the
founder asked Ayma to "run a self check" and she only *summarized*
already-known failures without executing anything. So the trigger here
is a strict slash command matched in ``main._prepare_chat`` BEFORE the
model runs (same determinism family as the model-stack switch and the
deterministic navigation detectors), and every result in the report
comes from a check that actually executed — or is honestly labelled
PROBE (binding verified, execution deliberately not run), SKIP (not
runnable in this context) or EXCLUDED (the six founder-excluded actions,
never exercised).

Design notes (spec: ``Ayma Self-Check Skill — Spec.md`` in the goal
files):

* Navigation checks reuse the exact app-control ack path the
  ``open_screen`` tool uses (``_queue_command`` + ``_await_ack`` with the
  production default window), so a missing ack is a real FAIL — the
  failure class behind the founder's Nov 6 voice-navigation bug reports.
  The check passes NO window of its own: the shared ``_await_ack`` (one
  window + one same-command re-wait) is the whole wait, for a real turn
  and for the check alike (founder, 2026-11-07: a run passed every nav
  minutes before a real "open Explore" ask failed, because the check
  then waited a second window the tool never got — the re-wait now
  lives in the shared helper, not in the check).
* Write checks write through the tool's own bound callable, read the
  stored value back, revert, and read back again. No original value to
  restore -> SKIP; a self-check never leaves a test value behind.
* Display (founder, 2026-11-07, on the first live staging run):
  bubbles, the end-of-run summary and the feature-suggestion
  bubble speak in plain names with marks - never raw check ids.
  After the summary, the runner files ONE consolidated feedback
  record holding the run's feature suggestions (the founder-
  ordered exception to the probe-only rule for record_feedback:
  the check itself still never executes it; the filing is a
  separate post-run write through the same bound tool).
* Generative / credit-spending tools, the model-stack setters, the
  tour, DM sending, and the irreversible inbox bulk actions are
  PROBE-only in this MVP: the runner verifies they are bound, it does
  not execute them. The six excluded actions are not even probed.
* ``record_feedback`` is PROBE-only too, even though it is cheap:
  executing it writes a real feedback doc + steering rule, and a
  diagnostic never writes user data. Probe mode is the default; a
  future full-run mode would need its own explicit opt-in.
* Build-relative accounting (staging port, 2026-11-07): the check
  lists are a superset across builds. A check whose tool this build
  neither declares (``skills.session_tool_declarations``) nor binds
  is SKIP - the capability is not part of this build, so its absence
  is not a defect and files no bug. Declared-but-unbound IS a FAIL:
  the build claims the tool and cannot produce it.
* ``web_search`` runs for real, but its known-off failure is not a
  bug: ``gemini.research()`` raises ``DirectGoogleDisabledError`` by
  design (live web search off since the 2026-11-04 billing kill;
  restore plan pending a founder decision). Any check failing with
  that error is reported SKIP (off by design), files no bug, and the
  suggestions carry one restore-plan line instead of a fix line.
* Readability + stranding (founder, 2026-11-07 ~15:53, after two runs
  on his phone): the end-of-run output is posted as short bubbles —
  never a bubble over 1500 chars, split only on line boundaries (long
  bubbles were truncated mid-word in chat). A nav timeout after an
  external open counts as not-run rather than failed (a backgrounded
  app cannot hear nav commands), the nav section queues a return to
  the chat, and bug filing de-dupes against the last 24h so repeat
  runs do not file the same failure twice.
* Failures-only output + final nav group (founder, 2026-11-07
  ~16:14): chat at the end of a run gets ONLY the counts header and
  the failure lines — no per-category bubbles, no suggestions bubble
  (the full grouped detail and the suggestions live in the run's one
  feedback record). The destinations that need the user present —
  Photos (the photo upload/edit page) and Terms/Privacy (they open
  the browser) — run as real checks at the very END of the run, in
  that order, each through the same production ack wait as every
  other nav check. Privacy goes last: it leaves the app sitting in
  the browser.
"""

from __future__ import annotations

import asyncio
import inspect
import logging
import os
import re
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Awaitable, Callable

import app_registry
import bug_reports_ops

logger = logging.getLogger("ayma.self_check")

PASS = "PASS"
FAIL = "FAIL"
PROBE = "PROBE"
SKIP = "SKIP"
EXCLUDED = "EXCLUDED"

# The six founder-excluded actions (app_registry.json exclusions.items,
# founder 2026-11-06). Kept as a literal fallback so the guard holds even
# if the registry read fails; the runner ALSO filters against the live
# registry at manifest-build time.
EXCLUDED_KEYS = (
    "delete_account",
    "purchase",
    "clear_memory",
    "delete_photo_everywhere",
    "block_report",
    "dismiss_all_suggestions",
)

# Tools that bind only in a surface-scoped chat (Story editor, profile
# edit, photo, deep-dive report, appearance report). A main-chat run
# cannot reach them; they are listed as SKIP-scoped, never omitted.
SCOPED_TOOLS: dict[str, str] = {
    "edit_passage": "Your Story editor chat",
    "set_passage_privacy": "Your Story editor chat",
    "set_section_privacy": "Your Story editor chat",
    "edit_career_timeline_entry": "Your Story editor chat",
    "delete_career_timeline_entry": "Your Story editor chat",
    "remove_from_profile": "Your Story editor chat",
    "list_profile_sections": "public-profile edit chat",
    "edit_profile_section": "public-profile edit chat",
    "set_profile_section_visibility": "public-profile edit chat",
    "edit_photo": "single-photo chat",
    "update_photo_note": "single-photo chat",
    "delete_photo": "single-photo chat",
    "correct_deep_dive_item": "web-research report chat",
    "remove_deep_dive_item": "web-research report chat",
    "correct_appearance_item": "Appearance report chat",
    "clear_appearance_item": "Appearance report chat",
}

# Tools verified by binding only in the MVP, with the reason execution
# is deliberately not run by a diagnostic.
PROBE_TOOLS: dict[str, str] = {
    "add_followup_question": "executing queues a real follow-up question",
    "set_brain": "never flip the brain mid-run",
    "set_voice_brain": "model-stack setter — probe only",
    "set_voice_mode": "model-stack setter — probe only",
    "set_realtime_model": "model-stack setter — probe only",
    "set_stt": "model-stack setter — probe only",
    "set_tts": "model-stack setter — probe only",
    "reconnect_voice": "would drop/reconnect a live call",
    "start_guided_tour": "run-with-cleanup candidate, bench verification pending",
    "advance_guided_tour": "guided-tour scoped",
    "back_guided_tour": "guided-tour scoped",
    "stop_guided_tour": "guided-tour scoped",
    "report_bug": "the filing path itself — exercised for real by every FAIL in this run",
    "remember": "writes durable memory with no exposed un-write",
    "send_dm_message": "a diagnostic never sends a DM",
    "deep_dive": "paid web-research generation — probe only",
    "rerun_web_research": "queues a paid background refresh",
    "face_report": "paid generation — probe only",
    "body_report": "paid generation — probe only",
    "analyze_physical_attributes": "paid generation, needs a photo fixture",
    "run_appearance_report": "paid generation — probe only",
    "record_answer": "would write a real questionnaire answer",
    "set_relationship_intent": "write+revert candidate, read-back unverified",
    "generate_image": "paid generation — probe only",
    "edit_story_entry": "write+revert candidate on a dedicated test section",
    "remove_story_entry": "soft-remove has no un-remove tool",
    "search_explore": "run candidate with a neutral probe query, pending bench verification",
    "open_message_thread": "needs an existing thread fixture",
    "open_notification": "needs a live notification fixture",
    "open_match_report": "needs a scored-match fixture",
    "open_date_sim": "probe only — verify the door, never run the sim generation",
    "open_practice_date": "probe only — verify the door, never run the generation",
    "app_action": "per-setting probes (see setting:* checks)",
    "account_action": "its only runnable action is sign_out, which would kill this session",
    "ui_action": "needs a live screen-capture control id (none in text chat)",
    "take_picture": "would fire the user camera",
    "play_voice_clip": "no voice clip fixture in a plain text run",
    "mark_all_notifications_read": "irreversible inbox state change",
    "clear_all_notifications": "destructive — the user button itself requires confirmation",
    "mark_all_conversations_read": "irreversible inbox state change",
    "copilot_locate": "needs a live co-pilot screen-share session",
    "copilot_copy_draft": "needs a live co-pilot session and a draft",
    "set_user_steering": "write+revert candidate, read-back unverified",
    "set_voice_preference": "covered as a probe in the MVP (no-op write candidate)",
    # record_feedback is deliberately PROBE-only even though it is cheap:
    # executing it writes a real feedback doc + steering rule, and a
    # diagnostic never writes user data (delta review, ledger row 2bs).
    "record_feedback": "probe only — writes a real feedback doc + steering rule",
}

# Tools the MVP actually executes (beyond navigation/read/write-revert).
# record_feedback is NOT here: executing it writes a real feedback doc +
# steering rule, so in probe mode (the default) it is binding-verified
# only — see PROBE_TOOLS. A future full-run mode would need its own
# explicit opt-in; it must never become the default.
RUN_TOOLS = (
    "web_search",
    "submit_feedback",
    "list_conversations",
    "next_questions",
    "find_fact_source",
    "read_dm_thread",
    "current_screen",
    "open_profile",
    "show_profile_photo",
    "go_back",
)

_TEST_LOCATION = "Self Check Test City"
_DM_COUNTERPART = "Sofia Marino"

# -- readability + stranding fixes (founder, 2026-11-07 ~15:53) --------
# No chat bubble the runner posts at finish may exceed this: longer
# bubbles are truncated mid-word by chat persistence (NOTE 137).
MAX_BUBBLE_CHARS = 1500

# Destinations that leave the app for the external browser. Flagged
# ``external`` in app_registry.json; this literal set is the fallback
# so Terms/Privacy are still recognised as browser-opening even if
# the flag is lost — the backgrounding rule (_nav_check) depends on
# knowing a navigation threw the user out of the app.
EXTERNAL_DESTINATION_KEYS = {"terms", "privacy"}

BACKGROUNDED_SKIP_DETAIL = (
    "the app was in your browser \u2014 this check could not be heard"
)
WEB_SEARCH_OFF_DETAIL = "Web search is off by design \u2014 restore plan pending"
WEB_SEARCH_OFF_SUGGESTION = (
    "Web search \u2014 off by design since Nov 4; restoring it waits "
    "on the founder decision in the restore plan."
)
_DIRECT_GOOGLE_DISABLED = "DirectGoogleDisabledError"

# -- final navigation group (founder, 2026-11-07 ~16:14) --------------
# These destinations need the user present while they run — Photos
# lands on the photo upload/edit page, Terms and Privacy open his
# browser — so they run as real checks at the very END of the run, in
# this order (Privacy last: it leaves the app sitting in the
# browser). Their ack wait is the production one, like every nav.
FINAL_NAV_KEYS = ("photos", "terms", "privacy")

# Bug filing de-dupes against identical failures filed this recently.
_BUG_DEDUPE_WINDOW = timedelta(hours=24)
# How many of the user's bug_reports rows the de-dupe fetch pulls. Must
# cover the whole recent set: the fetch has no ordering (no composite
# index exists for (uid, created_at)), so a limit below the user's total
# silently drops recent rows and the de-dupe misses them.
_BUG_DEDUPE_FETCH_LIMIT = 200


def _is_external_destination(dest: dict) -> bool:
    """True when navigating to ``dest`` leaves the app (browser)."""
    if not isinstance(dest, dict):
        return False
    if dest.get("external"):
        return True
    return str(dest.get("key") or "") in EXTERNAL_DESTINATION_KEYS


def _is_no_ack_error(error: str) -> bool:
    """True for nav failures that mean the app never heard the command."""
    text = (error or "").lower()
    return (
        "no ack" in text
        or "did not navigate" in text
        or text.startswith("timeout after")
    )


def _wrap_long_line(line: str, limit: int) -> list[str]:
    """Wrap one over-limit line at its ``; `` separators (never mid-word)."""
    if len(line) <= limit:
        return [line]
    parts = line.split("; ")
    out: list[str] = []
    current = ""
    for part in parts:
        candidate = part if not current else current + "; " + part
        if len(candidate) <= limit:
            current = candidate
        else:
            if current:
                out.append(current)
            current = part
    if current:
        out.append(current)
    return out or [line]


def chunk_lines(lines, limit: int = MAX_BUBBLE_CHARS) -> list[str]:
    """Pack ``lines`` into bubble texts of at most ``limit`` chars.

    Splits only between lines \u2014 never mid-line, never mid-word. A
    single line longer than the limit (a grouped suggestion entry) is
    first wrapped at its ``; `` separators, still never mid-word.
    """
    wrapped: list[str] = []
    for line in lines:
        wrapped.extend(_wrap_long_line(str(line), limit))
    bubbles: list[str] = []
    current = ""
    for line in wrapped:
        if not current:
            current = line
        elif len(current) + 1 + len(line) <= limit:
            current += "\n" + line
        else:
            bubbles.append(current)
            current = line
    if current:
        bubbles.append(current)
    return bubbles

_TRIGGER = re.compile(r"^\s*/self-check\s*$", re.IGNORECASE)


def is_self_check_command(text: str) -> bool:
    """True only for the bare slash command ``/self-check``.

    Strict on purpose (slash-command semantics): a conversational
    mention ("can you run a self check?") must never fire the runner —
    that phrasing is exactly what produced the fake, summarized
    self-check in session s-0Y9QgcivBffTuLNJyDe0IN.
    """
    return bool(_TRIGGER.match(text or ""))


def excluded_keys() -> list[str]:
    """The founder exclusion list, read from the registry when possible."""
    try:
        items = app_registry.registry().get("exclusions", {}).get("items", [])
        keys = []
        for item in items:
            if isinstance(item, dict):
                if item.get("key"):
                    keys.append(str(item["key"]))
            elif item:
                keys.append(str(item))
        return keys or list(EXCLUDED_KEYS)
    except Exception:  # noqa: BLE001 - the literal fallback still protects
        return list(EXCLUDED_KEYS)


def manifest_tool_names() -> set[str]:
    """Every tool name the manifest accounts for (run, probe, or scoped)."""
    names = set(RUN_TOOLS) | set(PROBE_TOOLS) | set(SCOPED_TOOLS)
    names |= {"set_profile_field", "set_notification_filter", "open_screen"}
    return names


# The marker the client appends to a set_notification_filter ack line
# ("Showing X notifications. (was: <key>)") naming the filter it
# replaced — the self-check's only way to learn the user's filter.
_PREVIOUS_FILTER = re.compile(r"\(was:\s*([a-z_]+)\)")


def _previous_filter(text: str) -> str | None:
    """The filter the client replaced, from its ack line, or None."""
    match = _PREVIOUS_FILTER.search(text or "")
    return match.group(1) if match else None


def _filter_failed(text: str) -> bool:
    """True when a filter command reports it did not run.

    The client acks a refused/failed command as ``"Not done: <reason>"``
    and the queue layer falls back to ``"The app did NOT ..."`` when no
    ack arrives — both mean the filter did not move, and both are a
    FAIL (the old check only looked for "did NOT" and missed "Not
    done:").
    """
    return ("Not done:" in text) or ("did NOT" in text)


# -- display names -----------------------------------------------------
# Chat bubbles, the summary and the suggestion bubble use plain
# names, never raw check ids (founder, 2026-11-07): "Nav to
# Photos", not "nav:photos". Curated names below; anything
# unlisted falls back to a humanised tail, so a bubble can never
# carry a raw "prefix:name" id.

_MARKS = {PASS: "\u2705", FAIL: "\u274c", SKIP: "\u23ed",
          PROBE: "\u23ed", EXCLUDED: "\u23ed"}

_TOOL_DISPLAY = {
    "web_search": "Web search",
    "submit_feedback": "Draft a feedback note",
    "list_conversations": "List conversations",
    "next_questions": "Next questions for you",
    "find_fact_source": "Find where a fact came from",
    "read_dm_thread": "Read a DM thread",
    "current_screen": "See the current screen",
    "open_profile": "Open a profile",
    "go_back": "Go back",
    "recall": "Recall from memory",
    "open_screen": "Open a page",
    "set_profile_field": "Edit a profile field",
    "set_notification_filter": "Set the notification filter",
    "record_feedback": "Record feedback about a conversation",
    "report_bug": "File a bug report",
    "add_followup_question": "Add a follow-up question",
    "set_brain": "Switch the brain",
    "set_voice_brain": "Switch the voice brain",
    "set_voice_mode": "Switch the voice mode",
    "set_realtime_model": "Switch the realtime model",
    "set_stt": "Switch speech-to-text",
    "set_tts": "Switch text-to-speech",
    "reconnect_voice": "Reconnect the voice call",
    "start_guided_tour": "Start the guided tour",
    "advance_guided_tour": "Advance the guided tour",
    "back_guided_tour": "Go back in the guided tour",
    "stop_guided_tour": "Stop the guided tour",
    "remember": "Remember something",
    "send_dm_message": "Send a DM",
    "deep_dive": "Deep-dive web research",
    "rerun_web_research": "Re-run web research",
    "face_report": "Face report",
    "body_report": "Body report",
    "analyze_physical_attributes": "Analyse physical attributes",
    "run_appearance_report": "Appearance report",
    "record_answer": "Record a questionnaire answer",
    "set_relationship_intent": "Set relationship intent",
    "generate_image": "Generate an image",
    "edit_story_entry": "Edit a Story entry",
    "remove_story_entry": "Remove a Story entry",
    "search_explore": "Search Explore",
    "show_profile_photo": "Show profile photo",
    "open_message_thread": "Open a message thread",
    "open_notification": "Open a notification",
    "open_match_report": "Open a match report",
    "open_date_sim": "Open a date sim",
    "open_practice_date": "Open a practice date",
    "app_action": "Change a setting",
    "account_action": "Account actions",
    "ui_action": "Tap or scroll on screen",
    "take_picture": "Take a picture",
    "play_voice_clip": "Play a voice clip",
    "mark_all_notifications_read": "Mark all notifications read",
    "clear_all_notifications": "Clear all notifications",
    "mark_all_conversations_read": "Mark all conversations read",
    "copilot_locate": "Point at something on a shared screen",
    "copilot_copy_draft": "Draft text for another app",
    "set_user_steering": "Set a steering preference",
    "set_voice_preference": "Set a voice preference",
    "edit_passage": "Edit a Story passage",
    "set_passage_privacy": "Set passage privacy",
    "set_section_privacy": "Set section privacy",
    "edit_career_timeline_entry": "Edit a career timeline entry",
    "delete_career_timeline_entry": "Delete a career timeline entry",
    "remove_from_profile": "Remove something from the profile",
    "list_profile_sections": "List profile sections",
    "edit_profile_section": "Edit a profile section",
    "set_profile_section_visibility": "Set profile section visibility",
    "edit_photo": "Edit a photo",
    "update_photo_note": "Update a photo note",
    "delete_photo": "Delete a photo",
    "correct_deep_dive_item": "Correct a research item",
    "remove_deep_dive_item": "Remove a research item",
    "correct_appearance_item": "Correct an appearance item",
    "clear_appearance_item": "Clear an appearance item",
}

_READ_DISPLAY = {
    "read:profile": "Read your profile",
    "read:story": "Read your Story",
    "read:explore_feed": "Read the Explore feed",
    "read:matches": "Read your matches",
    "read:notifications": "Read your notifications",
    "read:chat_history": "Read the chat history",
}

_WRITE_DISPLAY = {
    "wr:profile_field": "Edit a profile field, then undo it",
    "wr:notification_filter": "Change the notification filter, then restore it",
}

_OPEN_DISPLAY = {
    "open:message_thread": "Open a message thread",
    "open:match_report": "Open a match report",
    "open:date_sim": "Open a date sim",
    "open:practice_date": "Open a practice date",
}

_EXCLUDED_DISPLAY = {
    "delete_account": "Delete the account",
    "purchase": "Make a purchase",
    "clear_memory": "Clear Ayma memory",
    "delete_photo_everywhere": "Delete a photo everywhere",
    "block_report": "Block and report someone",
    "dismiss_all_suggestions": "Dismiss all suggestions",
}


def _humanise(tail: str) -> str:
    text = tail.replace("_", " ").replace("-", " ").strip()
    return text[:1].upper() + text[1:] if text else tail


def _title_label(label) -> str:
    """A registry label with its first letter raised ("your photos"
    -> "Your photos"), the rest untouched."""
    text = str(label or "").strip()
    return text[:1].upper() + text[1:] if text else text


@dataclass
class CheckResult:
    name: str
    category: str
    status: str
    detail: str = ""
    error: str = ""
    bug_id: str = ""
    duration_ms: int = 0


@dataclass
class _Deps:
    """Injectable seams (tests pass fakes; production uses the defaults)."""

    nav_fn: Callable | None = None          # async (dest) -> (ok, error)
    read_fn: Callable | None = None         # (name) -> (ok, detail, error)
    profile_read: Callable | None = None    # () -> str (stored location)
    tool_fns: dict | None = None            # name -> bound callable
    web_search_fn: Callable | None = None   # async () -> object (raises on failure)
    bug_record: Callable | None = None      # (db, uid, description) -> id | None
    progress: Callable | None = None        # (line: str) -> None
    destinations: list | None = None        # registry destination dicts
    settings_keys: list | None = None       # registry setting keys
    declared_tools: set | None = None       # session tool declaration names
    feedback_record: Callable | None = None  # (category, note) -> object


class SelfCheckRunner:
    """Sequential, one-check-at-a-time self-check for one user/session."""

    def __init__(
        self,
        db,
        uid: str,
        *,
        session_id: str = "",
        env_label: str = "",
        # The production nav tool's SINGLE ack window
        # (skills.app_control._ACK_TIMEOUT_SECONDS, raised there from
        # 3s after the 2026-11-01 founder bug: healthy acks on a laggy
        # app can miss 3s). The check itself awaits through the shared
        # _await_ack with no window of its own (see _do_nav); this
        # value only budgets the check-level timeout in _nav_check at
        # two windows + slack, mirroring that shared wait.
        nav_timeout: float = 6.0,
        check_timeout: float = 10.0,
        deps: _Deps | None = None,
    ):
        self.db = db
        self.uid = uid
        self.session_id = session_id or ""
        self.env_label = env_label or _env_label()
        self.nav_timeout = nav_timeout
        self.check_timeout = check_timeout
        self.deps = deps or _Deps()
        self.run_id = uuid.uuid4().hex[:12]
        self.results: list[CheckResult] = []
        self._filed: set[str] = set()
        self._feedback_sink: dict = {}
        self._tool_fns_cache: dict | None = None
        self._declared_cache: set | None = None
        self._labels: dict[str, str] = {}
        # Nav stranding guards: an external destination was reached
        # earlier in this run, or a nav command already went unheard —
        # either means later nav timeouts may be check artifacts.
        self._external_seen = False
        self._nav_unheard = False

    # -- plumbing ------------------------------------------------------

    def _tool_fns(self) -> dict:
        if self.deps.tool_fns is not None:
            return self.deps.tool_fns
        if self._tool_fns_cache is None:
            from skills import make_session_tool_fns

            self._tool_fns_cache = make_session_tool_fns(
                self.db,
                self.uid,
                session_ctx={
                    "session_id": self.session_id,
                    "turn_index": 0,
                    "turns": [],
                },
                feedback_result=self._feedback_sink,
            )
        return self._tool_fns_cache

    def _declared_tools(self) -> set:
        """Tool names this build declares to the model (its claims).

        A capability the build neither declares nor binds is not
        part of the build; one it declares but cannot bind is a
        defect. If the declarations cannot be read, fall back to
        treating the whole manifest as declared (the legacy FAIL
        behavior) - silently skipping a real failure is worse.
        """
        if self.deps.declared_tools is not None:
            return self.deps.declared_tools
        if self._declared_cache is None:
            try:
                from skills import session_tool_declarations

                self._declared_cache = {
                    str(d["name"]) for d in session_tool_declarations()
                }
            except Exception:  # noqa: BLE001 - legacy FAIL fallback
                logger.exception("self-check declarations read failed")
                self._declared_cache = set(manifest_tool_names())
        return self._declared_cache

    def _unbound(self, name: str):
        """(status, detail, error) for a check whose tool is unbound."""
        if name in self._declared_tools():
            return FAIL, "", f"{name} not bound in the session tool set"
        return (
            SKIP,
            f"{name} is not part of this build (not declared and not bound)",
            "",
        )

    async def _announce(self, line: str) -> None:
        """Post one progress bubble; progress never breaks a run."""
        if self.deps.progress is None:
            return
        try:
            out = self.deps.progress(line)
            if inspect.isawaitable(out):
                await out
        except Exception:  # noqa: BLE001 - progress never breaks a run
            logger.exception("self-check progress failed")

    async def _call(self, fn, *args, **kwargs):
        out = fn(*args, **kwargs)
        if inspect.isawaitable(out):
            out = await out
        return out

    async def _timed(self, name: str, category: str, coro,
                     timeout: float | None = None) -> CheckResult:
        limit = timeout if timeout is not None else self.check_timeout
        started = time.monotonic()
        try:
            status, detail, error = await asyncio.wait_for(
                coro, timeout=limit
            )
        except asyncio.TimeoutError:
            status, detail, error = (
                FAIL,
                "",
                f"timeout after {limit:g}s",
            )
        except Exception as exc:  # noqa: BLE001 - a check error IS the result
            status, detail, error = FAIL, "", f"{type(exc).__name__}: {exc}"
        if status == FAIL and _DIRECT_GOOGLE_DISABLED in (error or ""):
            # Known-off, not a bug: live web search was deliberately
            # disabled 2026-11-04 and its restore waits on a founder
            # decision. Report not-run, file nothing.
            status, detail, error = SKIP, WEB_SEARCH_OFF_DETAIL, ""
        return CheckResult(
            name=name,
            category=category,
            status=status,
            detail=detail or "",
            error=error or "",
            duration_ms=int((time.monotonic() - started) * 1000),
        )

    def _display(self, result: CheckResult) -> str:
        """The plain name for a check - bubbles never show raw ids."""
        name = result.name
        if name in self._labels:
            return self._labels[name]
        if name in _READ_DISPLAY:
            return _READ_DISPLAY[name]
        if name in _WRITE_DISPLAY:
            return _WRITE_DISPLAY[name]
        if name in _OPEN_DISPLAY:
            return _OPEN_DISPLAY[name]
        if name.startswith("tool:"):
            tail = name[5:]
            return _TOOL_DISPLAY.get(tail) or _humanise(tail)
        if name.startswith("setting:"):
            return "Setting: " + _humanise(name[8:])
        if name.startswith("excluded:"):
            tail = name[9:]
            return _EXCLUDED_DISPLAY.get(tail) or _humanise(tail)
        if name.startswith("nav:"):
            return "Nav to " + _humanise(name[4:])
        return _humanise(name.split(":")[-1])

    def _line(self, result: CheckResult) -> str:
        """One marked, plain-name line for a check (bubble/summary)."""
        line = f"{_MARKS.get(result.status, _MARKS[SKIP])} {self._display(result)}"
        if result.status == FAIL:
            reason = (result.error or result.detail or "").strip()
            if reason:
                line += f" — {reason[:120]}"
        elif result.status == PROBE:
            line += " (probe only)"
        elif result.status == EXCLUDED:
            line += " (excluded — never run)"
        return line

    async def _emit(self, result: CheckResult) -> None:
        self.results.append(result)
        if result.status == FAIL:
            await self._file_bug(result)
        await self._announce(self._line(result))

    def _recent_bug_docs(self) -> list:
        """Best-effort recent bug_reports docs for this user, newest first.

        Any handle or query failure returns an empty list — a filing
        query failure must never break a run or block a real filing.
        The fetch has no server-side ordering (no composite index
        exists for (uid, created_at)), so the newest-first order is
        applied here in memory.
        """
        docs: list = []
        try:
            query = self.db.collection("bug_reports")
            try:
                query = query.where("uid", "==", self.uid)
            except Exception:  # noqa: BLE001 - unfiltered fallback
                pass
            try:
                query = query.limit(_BUG_DEDUPE_FETCH_LIMIT)
            except Exception:  # noqa: BLE001 - limit is best-effort
                pass
            if hasattr(query, "stream"):
                docs = list(query.stream())
            elif hasattr(query, "get"):
                docs = list(query.get())
        except Exception:  # noqa: BLE001 - de-dupe is best-effort
            logger.exception("self-check bug de-dupe query failed")
            return []

        def _sort_key(doc):
            try:
                data = doc.to_dict() or {}
            except Exception:  # noqa: BLE001 - undated docs sort last
                return (1, 0.0)
            created = data.get("created_at")
            if isinstance(created, datetime):
                if created.tzinfo is None:
                    created = created.replace(tzinfo=timezone.utc)
                return (0, -created.timestamp())
            return (1, 0.0)

        docs.sort(key=_sort_key)
        return docs

    def _already_filed_recently(self, result: CheckResult) -> str:
        """Id of the existing report for an identical check+error filed
        within 24h, else "".

        A doc whose created_at is missing or unparseable never counts
        as a match: recency cannot be verified, and suppressing on it
        would hide a genuinely new failure forever.
        """
        needle = f"check={result.name} "
        want_error = (result.error or result.detail or "").strip()
        now = datetime.now(timezone.utc)
        for doc in self._recent_bug_docs():
            try:
                data = doc.to_dict() or {}
            except Exception:  # noqa: BLE001 - skip unreadable docs
                continue
            description = str(data.get("description") or "")
            if needle not in description:
                continue
            if want_error and " error=" in description:
                filed_error = description.rsplit(" error=", 1)[-1].strip()
                if filed_error != want_error:
                    continue
            created = data.get("created_at")
            if not isinstance(created, datetime):
                continue
            if created.tzinfo is None:
                created = created.replace(tzinfo=timezone.utc)
            if now - created > _BUG_DEDUPE_WINDOW:
                continue
            return getattr(doc, "id", "") or ""
        return ""

    async def _file_bug(self, result: CheckResult) -> None:
        """File this failure once per run, at the moment it happened."""
        if result.name in self._filed:
            return
        self._filed.add(result.name)
        existing_id = self._already_filed_recently(result)
        if existing_id:
            # The failure already has a live report from the last 24h:
            # point at it instead of filing a duplicate. bug_id must be
            # set here — build_report reads "bug filing failed" off an
            # empty bug_id, which is how these suppressions were
            # misreported as filing failures in NOTE 142.
            result.bug_id = existing_id
            result.detail = (
                result.detail + " (already filed in the last 24h)"
            ).strip()
            return
        description = (
            f"[self-check] check={result.name} category={result.category} "
            f"session={self.session_id or '?'} run={self.run_id} "
            f"env={self.env_label} error={result.error or result.detail}"
        )
        record = self.deps.bug_record or bug_reports_ops.record
        try:
            rid = record(self.db, self.uid, description)
            if inspect.isawaitable(rid):
                rid = await rid
            result.bug_id = str(rid or "")
            if not rid:
                result.detail = (result.detail + " (bug filing failed)").strip()
        except Exception:  # noqa: BLE001 - filing is best-effort
            logger.exception("self-check bug filing failed for %s", result.name)
            result.detail = (result.detail + " (bug filing failed)").strip()

    # -- individual checks ----------------------------------------------

    def _queue_nav_command(self, dest: dict):
        """Resolve + queue one navigate command; returns (cmd_id, label).

        No ack is awaited here — callers decide whether to wait.
        """
        from skills.app_control_navigation import _resolve_path
        from skills.app_control_queue import _queue_command

        path, label = _resolve_path(self.db, self.uid, dest)
        cmd_id = _queue_command(
            self.db,
            self.uid,
            {"action": "navigate", "screen": dest["key"], "path": path},
        )
        return cmd_id, label

    async def _return_to_chat(self, destinations) -> None:
        """Queue a navigate back to the chat, best-effort.

        Runs at the end of the nav section so a run always leaves the
        user back in the chat instead of stranded on whatever page the
        checks opened last. Ack is not required and this never becomes
        a check result.
        """
        chat = {"key": "ayma", "path": "/", "label": "the chat with Ayma"}
        for dest in destinations or []:
            if str(dest.get("key") or "") == "ayma":
                chat = dest
                break
        try:
            if self.deps.nav_fn is not None:
                out = self.deps.nav_fn(chat)
                if inspect.isawaitable(out):
                    await out
                return
            await asyncio.to_thread(self._queue_nav_command, chat)
        except Exception:  # noqa: BLE001 - return-to-chat never breaks a run
            logger.exception("self-check return-to-chat queue failed")

    async def _do_nav(self, dest: dict):
        if self.deps.nav_fn is not None:
            ok, error = await self.deps.nav_fn(dest)
            return (PASS, dest.get("label", ""), "") if ok else (FAIL, "", error)
        from skills import app_control
        from skills.app_control_queue import _await_ack

        cmd_id, label = await asyncio.to_thread(self._queue_nav_command, dest)
        # The production ack wait, unchanged: no timeout of the check's
        # own, so the shared helper's default window (one window + one
        # same-command re-wait) is exactly what a real open_screen turn
        # gets. A check that is privately more patient than the tool
        # green-lights the conditions real asks fail in (founder,
        # 2026-11-07 — see the module docstring).
        ack = await _await_ack(self.db, self.uid, cmd_id)
        if ack and ack.get("ok"):
            return PASS, label, ""
        total = app_control._ACK_TIMEOUT_SECONDS * 2
        return (
            FAIL,
            "",
            f"The app did NOT navigate (no ack within {total:g}s)",
        )

    async def _nav_check(self, dest: dict) -> None:
        """Run one navigation check for ``dest`` and emit the result.

        The ack wait is the production one (see ``_do_nav``) for every
        destination, the final group included. A no-ack timeout that
        follows an external open or an earlier unheard command is a
        check artifact — the app was backgrounded and could not
        hear — so it is reported not-run, never a failure, never a bug.
        """
        key = str(dest.get("key") or "")
        nav_result = await self._timed(
            f"nav:{key}", "navigation",
            self._do_nav(dest),
            timeout=self.nav_timeout * 2 + 5,
        )
        if nav_result.status == FAIL and _is_no_ack_error(nav_result.error):
            if self._external_seen or self._nav_unheard:
                nav_result = CheckResult(
                    nav_result.name, nav_result.category, SKIP,
                    BACKGROUNDED_SKIP_DETAIL, "",
                    duration_ms=nav_result.duration_ms,
                )
            else:
                self._nav_unheard = True
        if _is_external_destination(dest):
            # Navigating here opened (or tried to open) the browser:
            # the app is backgrounded from this point on, so a later
            # no-ack timeout in this run is the same artifact.
            self._external_seen = True
        await self._emit(nav_result)

    def _default_read(self, name: str):
        user = self.db.collection("users").document(self.uid)
        if name == "read:profile":
            snap = user.collection("profile").document("main").get()
            if getattr(snap, "exists", False):
                return True, "profile doc present", ""
            return False, "", "profile doc (users/{uid}/profile/main) missing"
        if name == "read:story":
            docs = list(user.collection("wiki_pages").limit(1).stream())
            return True, f"wiki_pages readable (sample {len(docs)})", ""
        if name == "read:explore_feed":
            docs = list(self.db.collection("profiles").limit(5).stream())
            others = [d for d in docs if d.id != self.uid]
            if others:
                return True, f"explore pool readable ({len(others)} sampled)", ""
            return False, "", "explore pool empty in sample"
        if name == "read:matches":
            docs = list(self.db.collection("matches").limit(1).stream())
            return True, f"matches readable (sample {len(docs)})", ""
        if name == "read:notifications":
            docs = list(user.collection("notifications").limit(1).stream())
            return True, f"notifications readable (sample {len(docs)})", ""
        if name == "read:chat_history":
            docs = list(user.collection("chat_messages").limit(1).stream())
            return True, f"chat_messages readable (sample {len(docs)})", ""
        return False, "", f"unknown read check {name}"

    async def _do_read(self, name: str):
        if self.deps.read_fn is not None:
            out = self.deps.read_fn(name)
            if inspect.isawaitable(out):
                out = await out
            ok, detail, error = out
        else:
            ok, detail, error = await asyncio.to_thread(self._default_read, name)
        return (PASS, detail, "") if ok else (FAIL, "", error)

    def _profile_location(self) -> str:
        if self.deps.profile_read is not None:
            return self.deps.profile_read() or ""
        snap = (
            self.db.collection("users")
            .document(self.uid)
            .collection("profile")
            .document("main")
            .get()
        )
        data = snap.to_dict() if getattr(snap, "exists", False) else {}
        return str((data or {}).get("location") or "")

    async def _do_wr_profile_field(self):
        fn = self._tool_fns().get("set_profile_field")
        if fn is None:
            return self._unbound("set_profile_field")
        original = await asyncio.to_thread(self._profile_location)
        if not original:
            return SKIP, "no original location value to restore — not writing", ""
        await self._call(fn, "location", _TEST_LOCATION)
        mid = await asyncio.to_thread(self._profile_location)
        if mid != _TEST_LOCATION:
            # Best-effort restore before reporting the failure.
            try:
                await self._call(fn, "location", original)
            except Exception:  # noqa: BLE001
                pass
            return FAIL, "", f"write did not land (read back {mid!r})"
        await self._call(fn, "location", original)
        back = await asyncio.to_thread(self._profile_location)
        if back != original:
            return FAIL, "", f"revert did not land (read back {back!r})"
        return PASS, "location write → verify → revert → verify", ""

    async def _do_wr_filter(self):
        """Exercise the notification filter, then restore the user's own.

        The filter lives only in the client
        (``NotificationFilterState``) — there is no server-side read of
        it. The client reports the filter it replaced in the ack line
        (``"... (was: <key>)"``) — that marker is the only way to learn
        the user's filter before touching it. If the client does not
        report one (old client), the check FAILs honestly and restores
        the default rather than stranding the user on a test filter.
        The restore runs in a ``finally`` so a failed second call still
        leaves the user's filter as it was — and a restore that itself
        fails is a FAIL, not a silent PASS.
        """
        fn = self._tool_fns().get("set_notification_filter")
        if fn is None:
            return self._unbound("set_notification_filter")
        original = "all"  # the client default; replaced by the reported value
        reported = False
        changed = False
        restore_error = ""
        status, detail, error = PASS, "", ""
        try:
            first = str(await self._call(fn, "unread") or "")
            if _filter_failed(first):
                status, error = FAIL, f"filter command not applied: {first}"
            else:
                # The first call landed, so the filter has moved.
                changed = True
                previous = _previous_filter(first)
                if previous is not None:
                    original, reported = previous, True
                second = str(await self._call(fn, "all") or "")
                if _filter_failed(second):
                    status, error = (
                        FAIL,
                        f"filter command not applied: {second}",
                    )
                elif not reported:
                    status, error = FAIL, (
                        "client did not report the previous filter — "
                        "restored to the default (all)"
                    )
                else:
                    detail = f"filter unread → all (restored {original})"
        finally:
            # Restore even on failure — but only if the check actually
            # moved the filter; a failed first call changed nothing, so
            # restoring then would itself move the user's filter.
            if changed:
                try:
                    restored = str(await self._call(fn, original) or "")
                    if _filter_failed(restored):
                        restore_error = restored
                except Exception as exc:  # noqa: BLE001
                    restore_error = f"{type(exc).__name__}: {exc}"
        if restore_error:
            return FAIL, "", f"filter could not be restored: {restore_error}"
        return status, detail, error

    async def _do_web_search(self):
        if self.deps.web_search_fn is not None:
            await self.deps.web_search_fn()
            return PASS, "web search answered", ""
        import gemini

        await gemini.research(
            "Ayma self-check probe", uid=self.uid, feature="self_check"
        )
        return PASS, "web search answered", ""

    async def _do_tool_run(self, name: str):
        fns = self._tool_fns()
        if name == "web_search":
            return await self._do_web_search()
        if name == "current_screen":
            fn = (self.deps.tool_fns or {}).get("current_screen")
            if fn is None:
                from skills import app_control as _ac

                fn = _ac._bind_current_screen(self.db, self.uid)
            out = str(await self._call(fn) or "")
            return PASS, out[:120], ""
        fn = fns.get(name)
        if fn is None:
            return self._unbound(name)
        if name == "submit_feedback":
            out = await self._call(
                fn,
                kind="bug",
                title="[self-check] draft probe",
                body="Self-check draft probe — drafted only, never submitted.",
            )
            if self._feedback_sink or str(out or "").strip():
                return PASS, "feedback draft produced in its sink, nothing persisted", ""
            return FAIL, "", "submit_feedback produced no draft"
        if name == "open_profile":
            out = str(await self._call(fn, _DM_COUNTERPART) or "")
            if "did NOT" in out:
                return FAIL, "", out[:200]
            return PASS, out[:120], ""
        if name == "show_profile_photo":
            return await self._do_show_profile_photo(fn)
        if name == "go_back":
            out = str(await self._call(fn) or "")
            if "did NOT" in out:
                return FAIL, "", out[:200]
            return PASS, out[:120], ""
        if name in ("find_fact_source", "recall"):
            out = await self._call(fn, "self-check")
            return PASS, str(out or "")[:120], ""
        if name == "read_dm_thread":
            out = await self._call(fn, _DM_COUNTERPART)
            return PASS, str(out or "")[:120], ""
        # list_conversations / next_questions: no-arg reads.
        out = await self._call(fn)
        text = str(out or "")
        if text.lower().startswith("error"):
            return FAIL, "", text[:200]
        return PASS, text[:120], ""

    async def _do_show_profile_photo(self, fn):
        """Execute the photo-open check for real (founder, 2026-11-07
        ~21:56: "open her third picture" was refused in a live voice
        session minutes after a self-check run reported no failures —
        this tool sat probe-only behind "needs an open profile photo
        carousel fixture", so the failure class was invisible).

        The check builds its own fixture through the production path:
        open the counterpart's profile with the same bound
        ``open_profile`` a real turn uses, then call the same bound
        ``show_profile_photo`` and judge ONLY its confirmed outcome —
        PASS when the app ack says the carousel is showing the asked
        photo, FAIL when the open does not land (no ack, a missing
        carousel on an open profile, or an out-of-range claim for a
        photo that exists). A profile with a single photo cannot move,
        so photo 1 is verified instead; a profile with no photos at
        all is a SKIP — there is nothing to open.
        """
        fns = self._tool_fns()
        opener = fns.get("open_profile")
        if opener is None:
            return FAIL, "", "open_profile not bound — photo fixture unavailable"
        out = str(await self._call(opener, _DM_COUNTERPART) or "")
        if "did NOT" in out or "couldn't find" in out:
            return FAIL, "", f"photo fixture failed: {out[:160]}"
        out = str(await self._call(fn, op="goto", index=2) or "")
        if out.startswith("showing:"):
            return PASS, out[:120], ""
        if out.startswith("out_of_range:"):
            m = re.search(r"only (\d+)", out)
            count = int(m.group(1)) if m else -1
            if count == 1:
                one = str(await self._call(fn, op="goto", index=1) or "")
                if one.startswith("showing:"):
                    return PASS, "profile has 1 photo; opening it verified", ""
                return FAIL, "", one[:200]
            if count == 0:
                return SKIP, "the fixture profile has no photos to open", ""
            return FAIL, "", (
                f"photo 2 reported out of range on a {count}-photo "
                f"profile: {out[:140]}"
            )
        if out.startswith("no_carousel:"):
            return FAIL, "", (
                "profile open but no photo carousel registered — "
                "a photo open cannot land"
            )
        return FAIL, "", out[:200]

    # -- the run ---------------------------------------------------------

    # -- post-run: summary, suggestions, one feedback record --------

    def _suggestions(self) -> list[str]:
        """Feature gaps from THIS run, in plain language.

        Failures and not-in-this-build adds stay individual lines.
        The two repetitive families collapse into ONE grouped line
        each (founder, 2026-11-07 ~15:53: the one-line-per-gap list
        was unreadable): every screen-scoped "bring into the main
        chat" item is named in a single line, and every probe-only
        item is named in a single line. By-design skips (backgrounded
        nav, web search off) are not gaps.
        Ordered most-actionable first so the consolidated feedback
        record — whose note is clipped by feedback_ops — holds the
        important ones.
        """
        failures: list[str] = []
        build_adds: list[str] = []
        other_skips: list[str] = []
        scoped_names: list[str] = []
        probe_names: list[str] = []
        excluded_lines: list[str] = []
        web_search_line = ""
        for r in self.results:
            plain = self._display(r)
            if r.status == FAIL:
                reason = (r.error or r.detail or "").strip()
                if reason:
                    failures.append(f"Fix {plain} — it failed ({reason[:80]}).")
                else:
                    failures.append(f"Fix {plain} — it failed in this run.")
            elif r.status == SKIP:
                detail = r.detail or ""
                if detail == WEB_SEARCH_OFF_DETAIL:
                    web_search_line = WEB_SEARCH_OFF_SUGGESTION
                elif "not part of this build" in detail:
                    build_adds.append(
                        f"Add {plain} to this build — not wired up here yet."
                    )
                elif r.category == "scoped":
                    if plain not in scoped_names:
                        scoped_names.append(plain)
                elif detail == BACKGROUNDED_SKIP_DETAIL:
                    continue  # by design — not a gap, no suggestion
                else:
                    other_skips.append(
                        f"Make {plain} runnable in a self-check — "
                        f"skipped ({detail[:60]})."
                    )
            elif r.status == PROBE:
                if plain not in probe_names:
                    probe_names.append(plain)
            elif r.status == EXCLUDED:
                excluded_lines.append(
                    f"{plain} — off-limits by your rule; never run, "
                    "listed so the gap is visible."
                )
            # PASS is not a gap — no suggestion.
        out = list(failures)
        if web_search_line:
            out.append(web_search_line)
        out += build_adds + other_skips
        if scoped_names:
            out.append(
                "Bring these into the main chat (they only work inside "
                "a specific screen today): " + "; ".join(scoped_names)
            )
        if probe_names:
            out.append(
                "Checked for wiring only, never run for real: "
                + "; ".join(probe_names)
            )
        out += excluded_lines
        return out

    async def _file_feedback(self, suggestions: list[str],
                             report: str = "") -> None:
        """File the run as ONE feedback record: suggestions + full report.

        Through the same bound record_feedback tool the session
        uses (feedback_ops, source ayma), tagged self-check in the
        note (the stored category taxonomy coerces to "other").
        feedback_ops clips each text field at 4000 chars, so the
        note keeps as many suggestions as fit and counts the rest.
        The full build_report text rides in the record's second
        text field (``quote``) — chat carries only the counts and
        the failures, and the turn reply is the short summary, so
        this one record is where the full report lives now.
        """
        fn = self.deps.feedback_record
        if fn is None:
            fn = self._tool_fns().get("record_feedback")
        if fn is None:
            return
        header = f"[self-check] run {self.run_id} — feature suggestions:"
        lines: list[str] = []
        size = len(header)
        for s in suggestions:
            if lines and size + len(s) + 3 > 3800:
                lines.append(
                    f"- and {len(suggestions) - len(lines)} more "
                    "(see the full report in this record)"
                )
                break
            lines.append(f"- {s}")
            size += len(s) + 3
        note = header + "\n" + "\n".join(lines)
        try:
            if report:
                try:
                    out = fn("self_check", note, quote=report)
                except TypeError:
                    # A bound fn without the quote parameter: the
                    # record still files, suggestions only.
                    out = fn("self_check", note)
            else:
                out = fn("self_check", note)
            if inspect.isawaitable(out):
                await out
        except Exception:  # noqa: BLE001 - feedback never breaks a run
            logger.exception("self-check feedback filing failed")

    async def _announce_bubbles(self, heading: str, lines: list[str]) -> None:
        """Post ``lines`` under ``heading`` in bubbles of at most
        MAX_BUBBLE_CHARS (heading repeated on each chunk)."""
        if not lines:
            return
        room = MAX_BUBBLE_CHARS - len(heading) - 1
        for chunk in chunk_lines(lines, limit=room):
            await self._announce(heading + "\n" + chunk)

    def _summary_header(self) -> str:
        """The counts block — shared by the finish bubbles and the
        turn reply, so the two can never drift into different formats.
        One count per line, each count line starting with its mark
        (founder, 2026-11-07 ~21:09: the counts used to be crammed
        into one line with "·" separators; he asked for one per
        line). A zero-failure run reads clearly from the counts
        themselves — the passed line over a "0 failed" line."""
        counts = {PASS: 0, FAIL: 0, PROBE: 0, SKIP: 0, EXCLUDED: 0}
        for r in self.results:
            counts[r.status] = counts.get(r.status, 0) + 1
        not_run = counts[PROBE] + counts[SKIP] + counts[EXCLUDED]
        return "\n".join([
            f"\U0001f9ea Self-check summary — {len(self.results)} checks",
            f"{_MARKS[PASS]} {counts[PASS]} passed",
            f"{_MARKS[FAIL]} {counts[FAIL]} failed",
            f"{_MARKS[SKIP]} {not_run} not run",
        ])

    def _failure_lines(self) -> list[str]:
        """The failure lines in plain words — the same ``_line``
        humanisation the finish bubbles post, reused for the reply."""
        return [self._line(r) for r in self.results if r.status == FAIL]

    def _reply_text(self) -> str:
        """The /self-check turn reply: the counts block, plus the
        failure lines when there are any — and nothing else.

        The full raw report (build_report) is NOT the reply. It used
        to be returned verbatim, so every run ended with a wall of
        raw check ids under the short bubbles (founder screenshot
        2026-11-07 ~18:30 PT, run 15ccce916d5f). The full report now
        lives only in the run's feedback record (see _file_feedback).
        """
        return "\n".join([self._summary_header(), *self._failure_lines()])

    async def _finish(self, report: str = "") -> None:
        """End-of-run chat output: the counts, then failures only.

        Founder, 2026-11-07 ~16:14: even grouped, the full readout
        (header, failures, one bubble per category, suggestions)
        landed as a wall of text, so chat now gets ONE header bubble
        with the counts and then the failure lines only — packed
        under MAX_BUBBLE_CHARS, split only on line boundaries. A run
        with no failures posts the header alone, worded so it is
        clear every check that ran passed. The full report and the
        feature suggestions go to the run's single feedback record
        (_file_feedback) — they no longer post here. The turn reply
        (run()'s return value) is built from these same lines via
        _reply_text — never the raw report.
        """
        await self._announce(self._summary_header())
        failure_lines = self._failure_lines()
        if failure_lines:
            await self._announce_bubbles(
                "\u274c Failures — every failure from this run:",
                failure_lines,
            )
        suggestions = self._suggestions()
        await self._file_feedback(suggestions, report)

    async def run(self) -> str:
        deps = self.deps
        await self._announce(
            "Self-check started — running each capability one by one; "
            "each result lands here in the chat as its check finishes."
        )
        destinations = deps.destinations
        if destinations is None:
            destinations = app_registry.destinations()
        excluded_dest = set()
        try:
            excluded_dest = set(app_registry.excluded_destination_keys())
        except Exception:  # noqa: BLE001
            pass
        excluded_dest.add("delete_account")

        # A. Navigation — one ack-checked open per destination, EXCEPT
        # the final group (FINAL_NAV_KEYS: photos, terms, privacy).
        # Those need the user present while they run, so they are held
        # back and executed at the very end of the run (below).
        final_dests: dict[str, dict] = {}
        for dest in destinations:
            key = str(dest.get("key") or "")
            if not key:
                continue
            self._labels[f"nav:{key}"] = (
                "Nav to " + _title_label(dest.get("label"))
            )
            if key in FINAL_NAV_KEYS:
                final_dests.setdefault(key, dest)
                continue
            if key in excluded_dest or key in EXCLUDED_KEYS:
                await self._emit(
                    CheckResult(f"nav:{key}", "navigation", EXCLUDED,
                                "founder-excluded — never exercised")
                )
                continue
            await self._nav_check(dest)

        # A run always leaves the user back in the chat.
        await self._return_to_chat(destinations)

        # B. Parameterized opens.
        await self._emit(
            await self._timed(
                "tool:open_profile", "tools", self._do_tool_run("open_profile")
            )
        )
        for name, reason in (
            ("open:message_thread", "needs an existing thread fixture"),
            ("open:match_report", "needs a scored-match fixture"),
            ("open:date_sim", "probe only — no sim generation in a diagnostic"),
            ("open:practice_date", "probe only — no generation in a diagnostic"),
        ):
            await self._emit(CheckResult(name, "navigation", PROBE, reason))

        # C. Read checks.
        for name in (
            "read:profile",
            "read:story",
            "read:explore_feed",
            "read:matches",
            "read:notifications",
            "read:chat_history",
        ):
            await self._emit(
                await self._timed(name, "read", self._do_read(name))
            )

        # D. Write + revert.
        await self._emit(
            await self._timed(
                "wr:profile_field", "write_revert", self._do_wr_profile_field()
            )
        )
        await self._emit(
            await self._timed(
                "wr:notification_filter", "write_revert", self._do_wr_filter()
            )
        )

        # F (run half). Executed tool checks. record_feedback is NOT here:
        # it writes a real feedback doc + steering rule, so it is
        # binding-verified only (PROBE_TOOLS) — see the PROBE half below.
        for name in (
            "web_search",
            "submit_feedback",
            "list_conversations",
            "next_questions",
            "find_fact_source",
            "read_dm_thread",
            "current_screen",
            "show_profile_photo",
        ):
            await self._emit(
                await self._timed(
                    f"tool:{name}", "tools", self._do_tool_run(name)
                )
            )
        # Recall is conditional on the context level.
        if "recall" in self._tool_fns():
            await self._emit(
                await self._timed(
                    "tool:recall", "tools", self._do_tool_run("recall")
                )
            )
        else:
            await self._emit(
                CheckResult("tool:recall", "tools", SKIP,
                            "not registered at this context level")
            )
        # go_back last: unwind one navigation step back toward chat.
        await self._emit(
            await self._timed("tool:go_back", "tools", self._do_tool_run("go_back"))
        )

        # E. Settings probes.
        settings_keys = deps.settings_keys
        if settings_keys is None:
            try:
                settings_list = app_registry.settings()
                settings_keys = [str(s.get("key")) for s in settings_list]
                for s in settings_list:
                    k = str(s.get("key") or "")
                    if k and s.get("label"):
                        self._labels[f"setting:{k}"] = (
                            "Setting: " + str(s["label"])
                        )
            except Exception:  # noqa: BLE001
                settings_keys = []
        for key in settings_keys:
            if key:
                await self._emit(
                    CheckResult(f"setting:{key}", "settings", PROBE,
                                "app_action binding + registry presence verified")
                )

        # F (probe half). Binding probes for everything not executed.
        fns = self._tool_fns()
        for name, reason in PROBE_TOOLS.items():
            if name in fns:
                await self._emit(
                    CheckResult(f"tool:{name}", "tools", PROBE, reason)
                )
            elif name in self._declared_tools():
                await self._emit(
                    CheckResult(f"tool:{name}", "tools", FAIL,
                                "", "tool not bound in the session tool set")
                )
            else:
                await self._emit(
                    CheckResult(f"tool:{name}", "tools", SKIP,
                                "not part of this build (not declared and not bound)")
                )

        # G. Context-scoped tools.
        for name, scope in SCOPED_TOOLS.items():
            await self._emit(
                CheckResult(f"tool:{name}", "scoped", SKIP,
                            f"binds only in the {scope}")
            )

        # H. Excluded — listed, never exercised.
        for key in excluded_keys():
            await self._emit(
                CheckResult(f"excluded:{key}", "excluded", EXCLUDED,
                            "founder-excluded — never exercised")
            )

        # Final navigation group — photos, terms, privacy, in that
        # order, each through the same production ack wait as every
        # other nav check. They land the user somewhere he may need
        # to act — the photo upload/edit page, then his browser — so
        # they run only when nothing else remains. Privacy is last
        # because it leaves the app sitting in the browser.
        final_ran = False
        for key in FINAL_NAV_KEYS:
            dest = final_dests.get(key)
            if dest is None:
                continue
            final_ran = True
            if key in excluded_dest or key in EXCLUDED_KEYS:
                await self._emit(
                    CheckResult(f"nav:{key}", "navigation", EXCLUDED,
                                "founder-excluded — never exercised")
                )
                continue
            await self._nav_check(dest)
        if final_ran:
            # Line up a return to the chat, as after the main nav
            # section. After Privacy the app sits in the browser, so
            # this will usually go unheard — it is not a check.
            await self._return_to_chat(destinations)

        report = build_report(self.results, self.run_id, self.session_id,
                              self.env_label)
        await self._finish(report)
        return self._reply_text()


def _env_label() -> str:
    env = (
        os.getenv("APP_ENV")
        or os.getenv("SENTRY_ENVIRONMENT")
        or os.getenv("ENVIRONMENT")
        or "unknown-env"
    )
    version = os.getenv("APP_VERSION", "")
    return f"{env}/{version}" if version else env


def build_report(
    results: list[CheckResult], run_id: str, session_id: str, env_label: str
) -> str:
    counts = {PASS: 0, FAIL: 0, PROBE: 0, SKIP: 0, EXCLUDED: 0}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1
    lines = [
        f"SELF-CHECK — run {run_id} — {env_label} — session {session_id or '?'}",
        f"{len(results)} checks: {counts[PASS]} PASS · {counts[FAIL]} FAIL · "
        f"{counts[PROBE]} PROBE · {counts[SKIP]} SKIP · {counts[EXCLUDED]} EXCLUDED",
        "",
    ]
    failures = [r for r in results if r.status == FAIL]
    if failures:
        lines.append("FAILURES (a bug report was filed for each):")
        for r in failures:
            bug = f" — bug {r.bug_id}" if r.bug_id else " — bug filing failed"
            lines.append(f"• {r.name} — {r.error or r.detail}{bug}")
        lines.append("")
    passed = [r.name for r in results if r.status == PASS]
    if passed:
        lines.append("PASSED: " + ", ".join(passed))
    probed = [r.name for r in results if r.status == PROBE]
    if probed:
        lines.append("PROBED (binding verified, not executed): " + ", ".join(probed))
    skipped = [r for r in results if r.status == SKIP]
    if skipped:
        lines.append(
            "SKIPPED: "
            + "; ".join(f"{r.name} ({r.detail})" for r in skipped)
        )
    excluded = [r.name for r in results if r.status == EXCLUDED]
    if excluded:
        lines.append(
            "EXCLUDED (never exercised): "
            + ", ".join(n.replace("excluded:", "") for n in excluded)
        )
    return "\n".join(lines)


async def run_self_check(db, uid: str, *, session_id: str = "") -> str:
    """Production entry point used by the ``/chat`` deterministic hook.

    Progress lines are appended to the chat history as checks complete
    (they land just before the persisted ``/self-check`` turn — a known
    cosmetic quirk of running inside ``_prepare_chat``, which executes
    before the user turn is persisted). The turn's reply text is the
    short human summary only (counts line + any failures in plain
    words); the full report is filed in the run's feedback record,
    never returned as the reply.
    """

    def _progress(line: str) -> None:
        try:
            import chat_history

            chat_history.append(db, uid, "ayma", line)
        except Exception:  # noqa: BLE001 - progress must never break a run
            logger.exception("self-check progress append failed")

    runner = SelfCheckRunner(
        db, uid, session_id=session_id, deps=_Deps(progress=_progress)
    )
    return await runner.run()
