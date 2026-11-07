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
  ``open_screen`` tool uses (``_queue_command`` + ``_await_ack``), so a
  missing ack is a real FAIL — the failure class behind the founder's
  Nov 6 voice-navigation bug reports.
* Write checks write through the tool's own bound callable, read the
  stored value back, revert, and read back again. No original value to
  restore -> SKIP; a self-check never leaves a test value behind.
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
* ``web_search`` runs for real and is EXPECTED to fail today:
  ``gemini.research()`` raises ``DirectGoogleDisabledError`` by design
  (LiveKit-only inference, founder 2026-11-04). The runner reports that
  honestly and files the bug — it never routes around it.
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
    "go_back",
)

_TEST_LOCATION = "Self Check Test City"
_DM_COUNTERPART = "Sofia Marino"

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


class SelfCheckRunner:
    """Sequential, one-check-at-a-time self-check for one user/session."""

    def __init__(
        self,
        db,
        uid: str,
        *,
        session_id: str = "",
        env_label: str = "",
        nav_timeout: float = 3.0,
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

    async def _timed(self, name: str, category: str, coro) -> CheckResult:
        started = time.monotonic()
        try:
            status, detail, error = await asyncio.wait_for(
                coro, timeout=self.check_timeout
            )
        except asyncio.TimeoutError:
            status, detail, error = (
                FAIL,
                "",
                f"timeout after {self.check_timeout:g}s",
            )
        except Exception as exc:  # noqa: BLE001 - a check error IS the result
            status, detail, error = FAIL, "", f"{type(exc).__name__}: {exc}"
        return CheckResult(
            name=name,
            category=category,
            status=status,
            detail=detail or "",
            error=error or "",
            duration_ms=int((time.monotonic() - started) * 1000),
        )

    async def _emit(self, result: CheckResult) -> None:
        self.results.append(result)
        if result.status == FAIL:
            await self._file_bug(result)
        if result.status == PASS:
            await self._announce(f"Self-check: {result.name} — PASS")
        elif result.status == FAIL:
            reason = result.error or result.detail
            line = f"Self-check: {result.name} — FAIL"
            if reason:
                line += f" — {reason}"
            await self._announce(line)

    async def _file_bug(self, result: CheckResult) -> None:
        """File this failure once per run, at the moment it happened."""
        if result.name in self._filed:
            return
        self._filed.add(result.name)
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

    async def _do_nav(self, dest: dict):
        if self.deps.nav_fn is not None:
            ok, error = await self.deps.nav_fn(dest)
            return (PASS, dest.get("label", ""), "") if ok else (FAIL, "", error)
        from skills.app_control_navigation import _resolve_path
        from skills.app_control_queue import _await_ack, _queue_command

        path, label = await asyncio.to_thread(_resolve_path, self.db, self.uid, dest)
        cmd_id = await asyncio.to_thread(
            _queue_command,
            self.db,
            self.uid,
            {"action": "navigate", "screen": dest["key"], "path": path},
        )
        ack = await _await_ack(self.db, self.uid, cmd_id, timeout=self.nav_timeout)
        if ack and ack.get("ok"):
            return PASS, label, ""
        return (
            FAIL,
            "",
            f"The app did NOT navigate (no ack within {self.nav_timeout:g}s)",
        )

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

    # -- the run ---------------------------------------------------------

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

        # A. Navigation — one ack-checked open per destination.
        for dest in destinations:
            key = str(dest.get("key") or "")
            if not key:
                continue
            if key in excluded_dest or key in EXCLUDED_KEYS:
                self.results.append(
                    CheckResult(f"nav:{key}", "navigation", EXCLUDED,
                                "founder-excluded — never exercised")
                )
                continue
            await self._emit(
                await self._timed(f"nav:{key}", "navigation", self._do_nav(dest))
            )

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
            self.results.append(CheckResult(name, "navigation", PROBE, reason))

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
            self.results.append(
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
                settings_keys = [str(s.get("key")) for s in app_registry.settings()]
            except Exception:  # noqa: BLE001
                settings_keys = []
        for key in settings_keys:
            if key:
                self.results.append(
                    CheckResult(f"setting:{key}", "settings", PROBE,
                                "app_action binding + registry presence verified")
                )

        # F (probe half). Binding probes for everything not executed.
        fns = self._tool_fns()
        for name, reason in PROBE_TOOLS.items():
            if name in fns:
                self.results.append(
                    CheckResult(f"tool:{name}", "tools", PROBE, reason)
                )
            elif name in self._declared_tools():
                await self._emit(
                    CheckResult(f"tool:{name}", "tools", FAIL,
                                "", "tool not bound in the session tool set")
                )
            else:
                self.results.append(
                    CheckResult(f"tool:{name}", "tools", SKIP,
                                "not part of this build (not declared and not bound)")
                )

        # G. Context-scoped tools.
        for name, scope in SCOPED_TOOLS.items():
            self.results.append(
                CheckResult(f"tool:{name}", "scoped", SKIP,
                            f"binds only in the {scope}")
            )

        # H. Excluded — listed, never exercised.
        for key in excluded_keys():
            self.results.append(
                CheckResult(f"excluded:{key}", "excluded", EXCLUDED,
                            "founder-excluded — never exercised")
            )

        return build_report(self.results, self.run_id, self.session_id,
                            self.env_label)


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
    before the user turn is persisted). The full report is returned as
    the turn's reply text.
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
