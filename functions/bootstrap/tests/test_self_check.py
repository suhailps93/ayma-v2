"""``self_check`` — the deterministic ``/self-check`` runner (founder
order 2026-11-06). Covers the strict slash-command trigger, the runner's
PASS path, the FAIL path (a bug is filed at failure time, once per check
per run, with the session/run context in the description), the
write+revert restoration guarantee, the exclusion guard, and manifest
integrity against the real session tool declarations."""

import asyncio
from datetime import datetime, timedelta, timezone

import pytest

import self_check
from self_check import CheckResult, SelfCheckRunner, _Deps


# --- trigger ---------------------------------------------------------------

@pytest.mark.parametrize(
    "text",
    ["/self-check", "  /self-check  ", "/SELF-CHECK", "/Self-Check"],
)
def test_trigger_matches_bare_slash_command(text):
    assert self_check.is_self_check_command(text)


@pytest.mark.parametrize(
    "text",
    [
        "",
        "self-check",
        "run a self check",
        "can you run a self-check?",
        "/self-check please",
        "/self-check now",
        "please /self-check",
        "/selfcheck",
    ],
)
def test_trigger_rejects_conversation(text):
    assert not self_check.is_self_check_command(text)


# --- fakes -------------------------------------------------------------------

class _Harness:
    def __init__(
        self,
        *,
        fail_nav=(),
        web_search_fails=False,
        location="San Jose",
        filter_state="all",
        filter_fail=None,
        filter_no_marker=False,
    ):
        self.store = {"location": location}
        self.bugs = []
        self.fail_nav = set(fail_nav)
        self.web_search_fails = web_search_fails
        # The notification-filter fake mimics the client protocol: it
        # keeps the filter in memory (client-only state) and reports the
        # filter it replaced in the ack line ("... (was: <key>)").
        self.filter_state = filter_state
        self.filter_calls = []
        self.filter_fail = filter_fail  # 1-based call number to fail, or None
        self.filter_no_marker = filter_no_marker
        self.record_feedback_calls = []
        self.photo_outcomes = []

    async def nav_fn(self, dest):
        if dest["key"] in self.fail_nav:
            return False, "The app did NOT navigate (no ack)"
        return True, ""

    def read_fn(self, name):
        return True, "ok", ""

    def profile_read(self):
        return self.store["location"]

    def bug_record(self, db, uid, description):
        self.bugs.append(description)
        return f"bug-{len(self.bugs)}"

    async def web_search_fn(self):
        if self.web_search_fails:
            raise RuntimeError(
                "DirectGoogleDisabledError: live web search is unavailable"
            )
        return "ok"

    def tool_fns(self):
        store = self.store

        def set_profile_field(field, value):
            store[field] = value
            return f"set {field}"

        async def set_notification_filter(filter=""):
            self.filter_calls.append(filter)
            if self.filter_fail == len(self.filter_calls):
                return "Not done: the app did NOT change the notification filter"
            prev = self.filter_state
            self.filter_state = filter or "all"
            line = f"Showing {self.filter_state} notifications."
            if not self.filter_no_marker:
                line += f" (was: {prev})"
            return line

        def submit_feedback(kind, title, body):
            return "drafted"

        async def open_profile(name=""):
            return "navigated: screen=profile"

        async def go_back():
            return "navigated: back"

        def record_feedback(category=None, note=None, **_kw):
            self.record_feedback_calls.append((category, note))
            return "noted"

        fns = {name: (lambda: "probe") for name in self_check.PROBE_TOOLS}
        fns.update(
            {
                "set_profile_field": set_profile_field,
                "set_notification_filter": set_notification_filter,
                "submit_feedback": submit_feedback,
                "list_conversations": lambda: "2 conversations",
                "next_questions": lambda: "q1?",
                "find_fact_source": lambda q: "found in profile",
                "read_dm_thread": lambda person: "no thread yet",
                "record_feedback": record_feedback,
                "current_screen": lambda: "The user hasn't opened anything specific.",
                "recall": lambda topic="": "recalled",
                "open_profile": open_profile,
                "go_back": go_back,
                "show_profile_photo": self._show_profile_photo,
            }
        )
        return fns

    async def _show_profile_photo(self, op="goto", index=0):
        # Healthy-app stub: the carousel is open with 3 photos and the
        # asked photo lands. Tests override photo_outcome(s) to model
        # the failure shapes.
        if self.photo_outcomes:
            return self.photo_outcomes.pop(0)
        return "showing: photo 2 of 3 — the carousel now shows photo 2."

    def runner(self) -> SelfCheckRunner:
        return SelfCheckRunner(
            object(),
            "u1",
            session_id="s-test",
            env_label="test-env",
            deps=_Deps(
                nav_fn=self.nav_fn,
                read_fn=self.read_fn,
                profile_read=self.profile_read,
                tool_fns=self.tool_fns(),
                web_search_fn=self.web_search_fn,
                bug_record=self.bug_record,
                destinations=[
                    {"key": "ayma", "label": "Chat"},
                    {"key": "explore", "label": "Explore"},
                    {"key": "delete_account", "label": "Delete account"},
                ],
                settings_keys=["theme", "notify_all"],
            ),
        )


# --- runner: PASS path --------------------------------------------------------

def test_runner_pass_path_and_write_revert_restores():
    h = _Harness()
    runner = h.runner()
    report = asyncio.run(runner.run())

    by_name = {r.name: r for r in runner.results}
    assert by_name["nav:ayma"].status == self_check.PASS
    assert by_name["nav:explore"].status == self_check.PASS
    assert by_name["wr:profile_field"].status == self_check.PASS
    # The test value was written, verified, reverted, verified.
    assert h.store["location"] == "San Jose"
    assert by_name["wr:notification_filter"].status == self_check.PASS
    assert by_name["tool:web_search"].status == self_check.PASS
    assert by_name["tool:submit_feedback"].status == self_check.PASS
    assert by_name["tool:recall"].status == self_check.PASS
    assert by_name["tool:deep_dive"].status == self_check.PROBE
    assert by_name["setting:theme"].status == self_check.PROBE
    assert h.bugs == []
    # The run() return is the turn reply: the short summary line only,
    # NOT the full raw report (founder screenshot 2026-11-07 ~18:30 —
    # the full report now lives in the run's feedback record; see the
    # reply regression tests below).
    assert "0 failed" in report
    assert "Self-check summary" in report
    assert "SELF-CHECK" not in report


# --- photo-open check (executed for real; founder 2026-11-07 ~21:56) --------

def test_runner_executes_show_profile_photo_and_passes():
    h = _Harness()
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    result = by_name["tool:show_profile_photo"]
    # Executed through the production binding — never a probe.
    assert result.status == self_check.PASS
    assert "photo 2 of 3" in result.detail


def test_photo_check_fails_when_the_app_never_confirms():
    h = _Harness()
    h.photo_outcomes = [
        "The app did NOT change the photo — tell the user it didn't work"
    ]
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["tool:show_profile_photo"].status == self_check.FAIL
    # The failure filed a bug record at failure time, like every FAIL.
    assert h.bugs
    assert any("photo" in str(b).lower() for b in h.bugs)


def test_photo_check_single_photo_profile_verifies_photo_one():
    h = _Harness()
    h.photo_outcomes = [
        "out_of_range: that profile has only 1 photo — there is no "
        "photo 2. Tell the user there are only 1 photo; the carousel "
        "did not move (still on photo 1).",
        "showing: photo 1 of 1 — the carousel now shows photo 1.",
    ]
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["tool:show_profile_photo"].status == self_check.PASS


def test_photo_check_fails_when_no_carousel_on_an_open_profile():
    h = _Harness()
    h.photo_outcomes = [
        "no_carousel: no profile photo carousel is open right now. "
        "Tell the user to open a profile first (open_profile can do "
        "that), then ask again."
    ]
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["tool:show_profile_photo"].status == self_check.FAIL


# --- runner: FAIL path --------------------------------------------------------

def test_runner_failures_file_bugs_at_failure_time_with_context():
    h = _Harness(fail_nav={"explore"}, web_search_fails=True)
    runner = h.runner()
    report = asyncio.run(runner.run())

    by_name = {r.name: r for r in runner.results}
    assert by_name["nav:explore"].status == self_check.FAIL
    # Web search failing with DirectGoogleDisabledError is known-off
    # (deliberately disabled 2026-11-04), not a bug: SKIP, no filing.
    assert by_name["tool:web_search"].status == self_check.SKIP
    assert by_name["tool:web_search"].detail == self_check.WEB_SEARCH_OFF_DETAIL
    # Exactly one bug: the genuine nav failure, filed during the run.
    assert len(h.bugs) == 1
    nav_bug = [b for b in h.bugs if "check=nav:explore" in b][0]
    assert "session=s-test" in nav_bug and "run=" in nav_bug
    assert "did NOT navigate" in nav_bug
    assert not any("check=tool:web_search" in b for b in h.bugs)
    assert by_name["nav:explore"].bug_id.startswith("bug-")
    # The reply is the short summary + the failure in plain words,
    # not the raw report (see the reply regression tests below).
    assert "1 failed" in report
    assert "Nav to Explore" in report
    assert "1 FAIL" not in report

    # Dedupe: filing the same check again in this run is a no-op.
    asyncio.run(runner._file_bug(by_name["nav:explore"]))
    assert len(h.bugs) == 1


def test_missing_probe_tool_is_a_fail_not_a_silent_skip():
    h = _Harness()
    runner = h.runner()
    del runner.deps.tool_fns["deep_dive"]
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["tool:deep_dive"].status == self_check.FAIL
    assert any("check=tool:deep_dive" in b for b in h.bugs)


# --- write+revert safety -------------------------------------------------------

def test_write_revert_skips_when_no_original_to_restore():
    h = _Harness(location="")
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["wr:profile_field"].status == self_check.SKIP
    assert h.store["location"] == ""  # never wrote the test value


# --- defect 1: record_feedback check is probe-only; the one record -----
# --- per run is the post-run consolidated suggestions filing -----------

def test_record_feedback_check_probe_only_one_consolidated_record():
    h = _Harness()
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    # The check itself never executes the tool: probe status only.
    assert by_name["tool:record_feedback"].status == self_check.PROBE
    # Exactly one call in the whole run: the consolidated post-run
    # record (founder, 2026-11-07), tagged self-check, carrying the
    # run suggestions - not a per-check execution.
    assert len(h.record_feedback_calls) == 1
    category, note = h.record_feedback_calls[0]
    assert category == "self_check"
    assert note.startswith("[self-check] run ")
    assert "feature suggestions" in note


# --- defect 2: filter check restores the user's filter ---------------------

def test_filter_check_restores_non_default_filter():
    h = _Harness(filter_state="matches")
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["wr:notification_filter"].status == self_check.PASS
    assert "restored matches" in by_name["wr:notification_filter"].detail
    # The three calls: unread (test), all (test), matches (restore).
    assert h.filter_calls == ["unread", "all", "matches"]
    assert h.filter_state == "matches"


def test_filter_check_restores_on_second_call_failure():
    h = _Harness(filter_state="matches", filter_fail=2)
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["wr:notification_filter"].status == self_check.FAIL
    assert "Not done:" in by_name["wr:notification_filter"].error
    # The restore still ran, even though the check failed.
    assert h.filter_calls == ["unread", "all", "matches"]
    assert h.filter_state == "matches"


def test_filter_check_fails_on_not_done_first_call_without_moving_filter():
    h = _Harness(filter_state="matches", filter_fail=1)
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["wr:notification_filter"].status == self_check.FAIL
    assert "Not done:" in by_name["wr:notification_filter"].error
    # Nothing was applied, so no restore call: the filter never moved.
    assert h.filter_calls == ["unread"]
    assert h.filter_state == "matches"


def test_filter_check_fails_when_client_reports_no_previous_filter():
    h = _Harness(filter_state="matches", filter_no_marker=True)
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["wr:notification_filter"].status == self_check.FAIL
    assert "did not report the previous filter" in by_name[
        "wr:notification_filter"
    ].error
    # Restored to the default rather than stranding the user on a test
    # value — the honest fallback for an old client.
    assert h.filter_calls == ["unread", "all", "all"]
    assert h.filter_state == "all"


def test_filter_check_fails_when_restore_itself_fails():
    h = _Harness(filter_state="matches", filter_fail=3)
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["wr:notification_filter"].status == self_check.FAIL
    assert "could not be restored" in by_name["wr:notification_filter"].error
    assert h.filter_calls == ["unread", "all", "matches"]
    # The restore was attempted and refused; the filter sits on "all".
    assert h.filter_state == "all"


# --- exclusions -----------------------------------------------------------------

def test_excluded_actions_are_never_runnable():
    h = _Harness()
    runner = h.runner()
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    # The delete_account destination is listed EXCLUDED, not navigated.
    assert by_name["nav:delete_account"].status == self_check.EXCLUDED
    for key in self_check.EXCLUDED_KEYS:
        assert by_name[f"excluded:{key}"].status == self_check.EXCLUDED
    # No executed/probed check touches an excluded action.
    for r in runner.results:
        if r.status in (self_check.PASS, self_check.FAIL, self_check.PROBE):
            for key in self_check.EXCLUDED_KEYS:
                assert key not in r.name
    # The manifest's tool accounting never includes an excluded key.
    assert not (self_check.manifest_tool_names() & set(self_check.EXCLUDED_KEYS))


# --- manifest integrity -----------------------------------------------------------

def test_manifest_covers_every_session_tool():
    import skills

    declared = {d["name"] for d in skills.session_tool_declarations()}
    missing = declared - self_check.manifest_tool_names()
    assert missing == set(), f"tools missing from the self-check manifest: {missing}"


# --- build-relative accounting (staging port) --------------------------------
# The check lists are a superset across builds: a tool this build neither
# declares (skills.session_tool_declarations) nor binds is not part of
# the build, so its checks SKIP and file no bug. A tool the build DOES
# declare but cannot bind stays a FAIL (see also
# test_missing_probe_tool_is_a_fail_not_a_silent_skip).


def test_undeclared_unbound_tools_skip_without_filing_bugs():
    h = _Harness()
    runner = h.runner()
    # copilot_locate / take_picture sit in the cross-build manifest but
    # are neither declared nor bound in this build (v2-only features).
    del runner.deps.tool_fns["copilot_locate"]
    del runner.deps.tool_fns["take_picture"]
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["tool:copilot_locate"].status == self_check.SKIP
    assert by_name["tool:take_picture"].status == self_check.SKIP
    assert not any("copilot_locate" in b for b in h.bugs)
    assert not any("take_picture" in b for b in h.bugs)


def test_declared_but_unbound_run_tool_still_fails_and_files_bug():
    h = _Harness()
    runner = h.runner()
    del runner.deps.tool_fns["list_conversations"]
    del runner.deps.tool_fns["set_notification_filter"]
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    assert by_name["tool:list_conversations"].status == self_check.FAIL
    assert any("check=tool:list_conversations" in b for b in h.bugs)
    # set_notification_filter is declared on this build (staging
    # port), so its write check FAILs too - and never calls through.
    assert by_name["wr:notification_filter"].status == self_check.FAIL
    assert any("check=wr:notification_filter" in b for b in h.bugs)
    assert h.filter_calls == []


# --- progress bubbles ----------------------------------------------------------


def test_progress_bubbles_plain_names_marks_no_raw_ids():
    h = _Harness(fail_nav={"explore"})
    lines = []
    runner = h.runner()
    runner.deps.progress = lines.append
    asyncio.run(runner.run())
    # A start bubble posts before any check result.
    assert lines[0].startswith("Self-check started")
    # Every result bubbles exactly once as it finishes, in plain names
    # with marks: start + one per result, then the finish bubbles.
    result_lines = lines[1:1 + len(runner.results)]
    assert len(result_lines) == len(runner.results)
    # Each live bubble is exactly the check's own line, in run order.
    assert result_lines == [runner._line(r) for r in runner.results]
    assert "\u2705 Nav to Explore" not in lines  # explore fails here
    assert "\u2705 Nav to Chat" in lines
    fail_lines = [ln for ln in lines if ln.startswith("\u274c Nav to Explore")]
    assert len(fail_lines) == 1
    # The FAIL bubble carries the short reason, not just the name.
    assert "did NOT navigate" in fail_lines[0]
    # Probes and excluded checks bubble too, with the skip mark.
    assert "\u23ed Deep-dive web research (probe only)" in lines
    assert "\u23ed Delete the account (excluded \u2014 never run)" in lines
    # No bubble anywhere carries a raw check id.
    for ln in lines:
        for raw in ("nav:", "tool:", "wr:", "read:", "setting:",
                    "excluded:", "open:"):
            assert raw not in ln, (raw, ln)
    # The finish (founder, 2026-11-07 ~16:14) is failures-only: one
    # header bubble with the counts, then the failure lines — no
    # per-category bubbles, no pass lines, no suggestions bubble.
    finish = lines[1 + len(runner.results):]
    assert len(finish) == 2
    assert all(len(ln) <= self_check.MAX_BUBBLE_CHARS for ln in lines)
    assert finish[0].startswith("\U0001f9ea Self-check summary")
    assert f"{len(runner.results)} checks" in finish[0]
    assert finish[1].startswith("\u274c Failures")
    assert "Nav to Explore" in finish[1]
    assert "Nav to Chat" not in finish[1]  # passes stay out of the finish
    for title in ("Navigation — ", "Tools — ", "Reading — ",
                  "Settings — ", "Write and revert — "):
        assert not any(ln.startswith(title) for ln in finish)
    assert not any(ln.startswith("\U0001f4a1") for ln in lines)


# --- feature suggestions + consolidated feedback record -------------------


def test_suggestions_from_fails_and_skips_filed_exactly_once():
    h = _Harness(fail_nav={"explore"})
    fns = h.tool_fns()
    del fns["copilot_locate"]  # not bound here -> build-relative SKIP
    lines = []
    runner = SelfCheckRunner(
        object(),
        "u1",
        session_id="s-test",
        env_label="test-env",
        deps=_Deps(
            nav_fn=h.nav_fn,
            read_fn=h.read_fn,
            profile_read=h.profile_read,
            tool_fns=fns,
            web_search_fn=h.web_search_fn,
            bug_record=h.bug_record,
            destinations=[
                {"key": "ayma", "label": "Chat"},
                {"key": "explore", "label": "Explore"},
                {"key": "delete_account", "label": "Delete account"},
            ],
            settings_keys=["theme", "notify_all"],
            progress=lines.append,
        ),
    )
    asyncio.run(runner.run())
    # Suggestions no longer post to chat (founder, 2026-11-07 ~16:14:
    # the finish is failures-only) — they live in the record below.
    assert not any(ln.startswith("\U0001f4a1") for ln in lines)
    # The two repetitive families collapse to ONE grouped line each.
    suggestions = runner._suggestions()
    scoped = [
        s for s in suggestions
        if s.startswith("Bring these into the main chat")
    ]
    assert len(scoped) == 1
    assert "Edit a Story passage" in scoped[0]
    assert "Set passage privacy" in scoped[0]
    probe = [
        s for s in suggestions
        if s.startswith("Checked for wiring only, never run for real")
    ]
    assert len(probe) == 1
    assert "Deep-dive web research" in probe[0]
    # One consolidated record for the whole run, never one per gap.
    assert len(h.record_feedback_calls) == 1
    category, note = h.record_feedback_calls[0]
    assert category == "self_check"
    # Derived from THIS run: the explore FAIL and the copilot SKIP
    # both become concrete, plain-language suggestions in the record.
    assert "Fix Nav to Explore" in note
    assert "Add Point at something on a shared screen to this build" in note


# --- nav cluster: the production ack wait, shared with the tool -----------
# The check used to wait a second window the production tool never got,
# so it passed navs real asks failed (founder, 2026-11-07). The re-wait
# now lives in skills.app_control_queue._await_ack itself; _do_nav awaits
# through it with NO window of its own (its coverage sits with the tool's
# tests in test_app_control.py).


def test_nav_default_window_matches_production_six_seconds():
    runner = SelfCheckRunner(object(), "u1")
    assert runner.nav_timeout == 6.0


def _patched_nav(monkeypatch, ack_outcomes):
    import skills.app_control_navigation as acn
    import skills.app_control_queue as acq

    calls = {"queue": 0, "ack": 0}

    def fake_resolve(db, uid, dest):
        return "/explore", "Explore"

    def fake_queue(db, uid, payload):
        calls["queue"] += 1
        return "cmd-1"

    outcomes = list(ack_outcomes)

    async def fake_ack(db, uid, cmd_id, timeout=None):
        calls["ack"] += 1
        return outcomes.pop(0)

    monkeypatch.setattr(acn, "_resolve_path", fake_resolve)
    monkeypatch.setattr(acq, "_queue_command", fake_queue)
    monkeypatch.setattr(acq, "_await_ack", fake_ack)
    return calls


def test_nav_awaits_through_the_production_ack_wait(monkeypatch):
    # _do_nav hands the ack wait to the shared _await_ack with NO
    # timeout of its own — the production default (one window + one
    # same-command re-wait inside the helper) decides, exactly as it
    # does for a real open_screen turn. One command, one await call.
    calls = _patched_nav(monkeypatch, [{"ok": True}])
    runner = SelfCheckRunner(object(), "u1", deps=_Deps(tool_fns={}))
    status, detail, error = asyncio.run(
        runner._do_nav({"key": "explore", "label": "Explore"})
    )
    assert status == self_check.PASS
    assert calls == {"queue": 1, "ack": 1}


def test_nav_fails_when_the_production_wait_gets_no_ack(monkeypatch):
    calls = _patched_nav(monkeypatch, [None])
    runner = SelfCheckRunner(object(), "u1", deps=_Deps(tool_fns={}))
    status, detail, error = asyncio.run(
        runner._do_nav({"key": "explore", "label": "Explore"})
    )
    assert status == self_check.FAIL
    assert "12s" in error  # the production total: two 6s windows
    assert calls == {"queue": 1, "ack": 1}


# --- readability + stranding fixes (founder, 2026-11-07 ~15:53) ---------
# --- failures-only finish + final nav group (founder, ~16:14) -------------
# After two runs on his phone: the output was unreadable (one packed
# summary bubble, truncated mid-word), the nav section threw him into
# the browser (Terms) and onto the photo page and never brought him
# back, and two of the three "failures" were the check itself.


def _runner_with(h, destinations, nav_fn=None):
    return SelfCheckRunner(
        object(),
        "u1",
        session_id="s-test",
        env_label="test-env",
        deps=_Deps(
            nav_fn=nav_fn or h.nav_fn,
            read_fn=h.read_fn,
            profile_read=h.profile_read,
            tool_fns=h.tool_fns(),
            web_search_fn=h.web_search_fn,
            bug_record=h.bug_record,
            destinations=destinations,
            settings_keys=["theme", "notify_all"],
        ),
    )


# A. chunking

def test_chunk_lines_never_exceeds_limit_or_splits_a_line():
    lines = [f"result {i} " + "x" * 40 for i in range(60)]
    bubbles = self_check.chunk_lines(lines, limit=200)
    assert bubbles and all(len(b) <= 200 for b in bubbles)
    rejoined = []
    for b in bubbles:
        rejoined.extend(b.split("\n"))
    assert rejoined == lines


def test_chunk_lines_wraps_a_grouped_line_at_its_separators():
    names = "; ".join(f"Check number {i}" for i in range(40))
    line = "Checked for wiring only, never run for real: " + names
    bubbles = self_check.chunk_lines([line], limit=300)
    assert len(bubbles) > 1
    assert all(len(b) <= 300 for b in bubbles)
    joined = "\n".join(bubbles)
    # Every name survives whole — no mid-word or mid-name split.
    for i in range(40):
        assert f"Check number {i}" in joined
    assert joined.count("Check number") == 40


def test_finish_posts_header_and_failures_only():
    h = _Harness(fail_nav={"explore"})
    lines = []
    runner = h.runner()
    runner.deps.progress = lines.append
    asyncio.run(runner.run())
    assert all(len(ln) <= self_check.MAX_BUBBLE_CHARS for ln in lines)
    finish = lines[1 + len(runner.results):]
    # Exactly two bubbles: the counts header and the failures bubble.
    assert len(finish) == 2
    assert finish[0].startswith("\U0001f9ea Self-check summary")
    assert "1 failed" in finish[0]
    assert finish[1].startswith("\u274c Failures")
    assert "Nav to Explore" in finish[1]
    # No per-category bubbles, and no pass lines in the failures bubble.
    headings = [ln.split("\n")[0] for ln in finish]
    assert not any(x.startswith("Navigation — ") for x in headings)
    assert not any(x.startswith("Tools — ") for x in headings)
    assert "Nav to Chat" not in finish[1]


def test_zero_failure_run_posts_only_the_header_at_finish():
    h = _Harness()
    lines = []
    runner = h.runner()
    runner.deps.progress = lines.append
    asyncio.run(runner.run())
    assert not any(r.status == self_check.FAIL for r in runner.results)
    finish = lines[1 + len(runner.results):]
    # One bubble only — and the counts lines make clear everything
    # passed: the failed count sits on its own line, reading zero.
    assert len(finish) == 1
    assert finish[0].startswith("\U0001f9ea Self-check summary")
    assert "0 failed" in finish[0]
    assert "\u274c 0 failed" in finish[0].split("\n")


def test_summary_header_one_count_per_line_emoji_first():
    """Founder, 2026-11-07 ~21:09: the counts were crammed into one
    line — summary, then the three counts joined by "·" separators —
    and he asked for each count on its own line, starting with the
    emoji. This pins the exact shape of the shared formatter."""
    h = _Harness()
    runner = h.runner()
    runner.results = [
        CheckResult("a", "nav", self_check.PASS),
        CheckResult("b", "nav", self_check.PASS),
        CheckResult("c", "tool", self_check.FAIL),
        CheckResult("d", "tool", self_check.PROBE),
        CheckResult("e", "tool", self_check.SKIP),
        CheckResult("f", "tool", self_check.EXCLUDED),
    ]
    header = runner._summary_header()
    assert header == (
        "\U0001f9ea Self-check summary — 6 checks\n"
        "\u2705 2 passed\n"
        "\u274c 1 failed\n"
        "\u23ed 3 not run"
    )
    # No "·" separators survive anywhere in the counts block.
    assert "·" not in header


# --- turn reply: short summary only; full report in the record --------
# Regression for the founder screenshot 2026-11-07 ~18:30 (run
# 15ccce916d5f): run() used to return build_report verbatim, so the
# /self-check turn reply was the whole raw report — header, PASSED:
# list, raw check ids — under the short finish bubbles.


def test_reply_clean_run_is_short_summary_no_raw_ids():
    h = _Harness()
    runner = h.runner()
    reply = asyncio.run(runner.run())
    assert not any(r.status == self_check.FAIL for r in runner.results)
    # The reply IS the shared counts block (one formatter, no fork):
    # the title line plus the three count lines, nothing else.
    assert reply == runner._summary_header()
    assert reply.count("\n") == 3
    assert "Self-check summary" in reply
    assert "0 failed" in reply
    # No raw check ids and no report list sections in the reply.
    assert "nav:" not in reply and "tool:" not in reply
    assert "PASSED:" not in reply
    assert "PROBED" not in reply and "SKIPPED:" not in reply
    assert "SELF-CHECK" not in reply


def test_reply_failing_run_names_failures_in_plain_words():
    h = _Harness(fail_nav={"explore"})
    runner = h.runner()
    reply = asyncio.run(runner.run())
    lines = reply.split("\n")
    header_lines = runner._summary_header().split("\n")
    # The reply opens with the shared counts block; failures follow it.
    assert lines[:len(header_lines)] == header_lines
    assert "\u274c 1 failed" in header_lines
    # The failure is named the plain way the finish bubbles name it —
    # never by its raw check id, and with no passed/probed lists.
    assert any("Nav to Explore" in ln for ln in lines[len(header_lines):])
    assert "nav:explore" not in reply
    assert "PASSED:" not in reply


def test_full_report_filed_in_the_single_feedback_record():
    h = _Harness(fail_nav={"explore"})
    captured = []

    def feedback_record(category, note, quote=""):
        captured.append((category, note, quote))
        return "noted"

    runner = h.runner()
    runner.deps.feedback_record = feedback_record
    asyncio.run(runner.run())
    # Still exactly ONE record for the whole run, tagged self-check,
    # suggestions in the note exactly as before...
    assert len(captured) == 1
    category, note, quote = captured[0]
    assert category == "self_check"
    assert note.startswith("[self-check] run ")
    assert "feature suggestions" in note
    assert "Fix Nav to Explore" in note
    # ...and the FULL build_report text preserved in the same record.
    expected = self_check.build_report(
        runner.results, runner.run_id, runner.session_id, runner.env_label
    )
    assert quote == expected
    assert "SELF-CHECK" in quote and "s-test" in quote
    assert "nav:explore" in quote  # raw detail lives here, not in chat


def test_suggestions_never_treat_passes_as_gaps():
    h = _Harness()
    runner = h.runner()
    asyncio.run(runner.run())
    suggestions = runner._suggestions()
    excluded_results = [
        r for r in runner.results if r.status == self_check.EXCLUDED
    ]
    off_limits = [s for s in suggestions if "off-limits by your rule" in s]
    assert len(off_limits) == len(excluded_results)
    # nav:ayma passed in this run — it must not appear as any gap.
    assert not any("Nav to Chat" in s for s in suggestions)


# B + C. final nav group (photos/terms/privacy run last, for real),
# backgrounding artifacts, return-to-chat

def test_registry_flags_terms_and_privacy_external():
    import app_registry

    dests = {d["key"]: d for d in app_registry.destinations()}
    assert dests["terms"].get("external") is True
    assert dests["privacy"].get("external") is True
    assert self_check._is_external_destination(dests["terms"])
    assert not self_check._is_external_destination(dests["explore"])


def test_final_group_runs_last_in_photos_terms_privacy_order():
    h = _Harness()
    calls = []

    async def nav_fn(dest):
        calls.append(dest["key"])
        return await h.nav_fn(dest)

    runner = _runner_with(
        h,
        [
            {"key": "ayma", "label": "Chat"},
            {"key": "privacy", "label": "Privacy Policy", "external": True},
            {"key": "explore", "label": "Explore"},
            {"key": "photos", "label": "your photos"},
            {"key": "terms", "label": "Terms of Service", "external": True},
            {"key": "matches", "label": "Matches"},
        ],
        nav_fn=nav_fn,
    )
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    # All three really execute and pass — nothing is skipped by design.
    for key in ("photos", "terms", "privacy"):
        assert by_name[f"nav:{key}"].status == self_check.PASS
    # They are the last three checks of the whole run, in the final
    # group order — the registry order above does not matter.
    assert [r.name for r in runner.results[-3:]] == [
        "nav:photos", "nav:terms", "nav:privacy",
    ]
    # And their navigations happen after every main-section nav.
    assert calls.index("photos") > calls.index("matches")
    assert calls.index("terms") > calls.index("photos")
    assert calls.index("privacy") > calls.index("terms")


def test_terms_executes_and_privacy_timeout_after_it_is_not_a_failure():
    h = _Harness(fail_nav={"privacy"})
    calls = []

    async def nav_fn(dest):
        calls.append(dest["key"])
        return await h.nav_fn(dest)

    runner = _runner_with(
        h,
        [
            {"key": "ayma", "label": "Chat"},
            {"key": "terms", "label": "Terms of Service", "external": True},
            {"key": "privacy", "label": "Privacy Policy", "external": True},
        ],
        nav_fn=nav_fn,
    )
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    # Terms really executes now — it is navigated, not skipped.
    assert "terms" in calls
    assert by_name["nav:terms"].status == self_check.PASS
    # Privacy timed out AFTER Terms threw the app into the browser:
    # the app was backgrounded and could not hear — not-run, never a
    # failure, never a bug.
    assert by_name["nav:privacy"].status == self_check.SKIP
    assert by_name["nav:privacy"].detail == (
        self_check.BACKGROUNDED_SKIP_DETAIL
    )
    assert h.bugs == []
    # Chat, back to chat, then the final group, then a return lined up.
    assert calls == ["ayma", "ayma", "terms", "privacy", "ayma"]


def test_final_group_first_timeout_still_fails_and_files_bug():
    h = _Harness(fail_nav={"terms"})
    runner = _runner_with(
        h,
        [
            {"key": "ayma", "label": "Chat"},
            {"key": "terms", "label": "Terms of Service", "external": True},
            {"key": "privacy", "label": "Privacy Policy", "external": True},
        ],
    )
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    # Terms is the FIRST unheard nav of the run — nothing was opened
    # before it — so its timeout is a genuine failure with its bug.
    assert by_name["nav:terms"].status == self_check.FAIL
    assert len([b for b in h.bugs if "check=nav:terms" in b]) == 1
    # Privacy still executes afterwards and passes.
    assert by_name["nav:privacy"].status == self_check.PASS


def test_final_group_uses_the_same_production_ack_wait(monkeypatch):
    import skills.app_control_navigation as acn
    import skills.app_control_queue as acq

    timeouts = []

    def fake_resolve(db, uid, dest):
        return "/x", "X"

    def fake_queue(db, uid, payload):
        return "cmd-1"

    async def fake_ack(db, uid, cmd_id, timeout=None):
        timeouts.append(timeout)
        return {"ok": True}

    monkeypatch.setattr(acn, "_resolve_path", fake_resolve)
    monkeypatch.setattr(acq, "_queue_command", fake_queue)
    monkeypatch.setattr(acq, "_await_ack", fake_ack)

    h = _Harness()
    runner = SelfCheckRunner(
        object(),
        "u1",
        session_id="s-test",
        env_label="test-env",
        deps=_Deps(
            # nav_fn deliberately NOT injected: the production ack
            # path runs, so the ack windows are observable here.
            read_fn=h.read_fn,
            profile_read=h.profile_read,
            tool_fns=h.tool_fns(),
            web_search_fn=h.web_search_fn,
            bug_record=h.bug_record,
            destinations=[
                {"key": "ayma", "label": "Chat"},
                {"key": "explore", "label": "Explore"},
                {"key": "photos", "label": "your photos"},
                {"key": "terms", "label": "Terms of Service",
                 "external": True},
                {"key": "privacy", "label": "Privacy Policy",
                 "external": True},
            ],
            settings_keys=["theme", "notify_all"],
        ),
    )
    asyncio.run(runner.run())
    # Every destination — main section and final group alike — awaits
    # through the production ack wait: no explicit timeout anywhere,
    # so the shared helper's default window (with its one re-wait)
    # decides for a check exactly as it does for a real turn. (The
    # return-to-chat lineups queue a command but never await an ack,
    # so they do not appear here.)
    assert timeouts == [None, None, None, None, None]
    by_name = {r.name: r for r in runner.results}
    for key in ("photos", "terms", "privacy"):
        assert by_name[f"nav:{key}"].status == self_check.PASS


def test_genuine_foregrounded_nav_timeout_still_fails():
    h = _Harness(fail_nav={"matches", "explore"})
    runner = _runner_with(
        h,
        [
            {"key": "ayma", "label": "Chat"},
            {"key": "matches", "label": "Matches"},
            {"key": "explore", "label": "Explore"},
        ],
    )
    asyncio.run(runner.run())
    by_name = {r.name: r for r in runner.results}
    # No external open before it: the first unheard nav is a real FAIL
    # and files its bug.
    assert by_name["nav:matches"].status == self_check.FAIL
    assert len([b for b in h.bugs if "check=nav:matches" in b]) == 1
    # Once a nav command has gone unheard, a later timeout in the same
    # run is the same artifact — not-run, no second bug.
    assert by_name["nav:explore"].status == self_check.SKIP
    assert not any("check=nav:explore" in b for b in h.bugs)


# D. web search known-off

def test_web_search_known_off_suggestion_wording():
    h = _Harness(web_search_fails=True)
    runner = h.runner()
    asyncio.run(runner.run())
    suggestions = runner._suggestions()
    assert self_check.WEB_SEARCH_OFF_SUGGESTION in suggestions
    assert not any(s.startswith("Fix Web search") for s in suggestions)


def test_any_check_failing_with_disabled_error_is_known_off():
    h = _Harness()
    runner = h.runner()

    async def boom():
        raise RuntimeError("DirectGoogleDisabledError: live web search is unavailable")

    result = asyncio.run(runner._timed("tool:deep_dive", "tools", boom()))
    assert result.status == self_check.SKIP
    assert result.detail == self_check.WEB_SEARCH_OFF_DETAIL
    assert result.error == ""


# E. bug-filing de-dupe (24h)

class _BugDoc:
    def __init__(self, data, doc_id="bug-old"):
        self._data = data
        self.id = doc_id

    def to_dict(self):
        return self._data


class _BugQuery:
    def __init__(self, docs):
        self._docs = docs

    def where(self, *args):
        return self

    def limit(self, n):
        self._docs = self._docs[:n]
        return self

    def stream(self):
        return iter(self._docs)


class _BugCollection:
    def __init__(self, docs):
        self._docs = docs

    def where(self, *args):
        return _BugQuery(self._docs)


class _BugDb:
    def __init__(self, docs):
        self._docs = docs

    def collection(self, name):
        assert name == "bug_reports"
        return _BugCollection(self._docs)


def _filed_doc(error, *, hours_ago=1, doc_id="bug-old", check="nav:explore"):
    return _BugDoc(
        {
            "uid": "u1",
            "description": (
                f"[self-check] check={check} category=navigation "
                f"session=s-old run=oldrun env=test-env error={error}"
            ),
            "status": "new",
            "created_at": datetime.now(timezone.utc)
            - timedelta(hours=hours_ago),
        },
        doc_id=doc_id,
    )


def _dedupe_runner(db, filed):
    def record(db_, uid, description):
        filed.append(description)
        return "bug-new"

    return SelfCheckRunner(
        db, "u1", deps=_Deps(bug_record=record, tool_fns={})
    )


def test_bug_filing_dedupes_identical_failure_within_24h():
    filed = []
    runner = _dedupe_runner(_BugDb([_filed_doc("boom")]), filed)
    result = CheckResult("nav:explore", "navigation", self_check.FAIL,
                         "", "boom")
    asyncio.run(runner._file_bug(result))
    assert filed == []
    assert "already filed" in result.detail


def test_bug_filing_still_files_new_or_stale_failures():
    # A different error is a different failure: filed.
    filed = []
    runner = _dedupe_runner(_BugDb([_filed_doc("boom")]), filed)
    asyncio.run(
        runner._file_bug(
            CheckResult("nav:explore", "navigation", self_check.FAIL,
                        "", "different")
        )
    )
    assert len(filed) == 1
    # The same failure filed more than 24h ago: filed again.
    filed2 = []
    runner2 = _dedupe_runner(_BugDb([_filed_doc("boom", hours_ago=30)]), filed2)
    asyncio.run(
        runner2._file_bug(
            CheckResult("nav:explore", "navigation", self_check.FAIL,
                        "", "boom")
        )
    )
    assert len(filed2) == 1


def test_bug_filing_dedupe_query_failure_never_blocks_filing():
    class _BadDb:
        def collection(self, name):
            raise RuntimeError("down")

    filed = []
    runner = _dedupe_runner(_BadDb(), filed)
    asyncio.run(
        runner._file_bug(
            CheckResult("nav:explore", "navigation", self_check.FAIL,
                        "", "boom")
        )
    )
    assert len(filed) == 1


# E2. bug-filing de-dupe reporting (ledger 2d1, Scout NOTE 142) ---------------


def test_bug_filing_suppression_points_at_existing_report():
    """A de-dupe suppression is not a filing failure: the result points
    at the existing report, and the built report line shows its id
    instead of "bug filing failed"."""
    filed = []
    runner = _dedupe_runner(_BugDb([_filed_doc("boom", doc_id="bug-old")]), filed)
    result = CheckResult("nav:explore", "navigation", self_check.FAIL, "", "boom")
    asyncio.run(runner._file_bug(result))
    assert filed == []
    assert result.bug_id == "bug-old"
    assert "already filed" in result.detail
    report = self_check.build_report([result], "run-x", "s-x", "test-env")
    assert "— bug bug-old" in report
    assert "bug filing failed" not in report


def test_bug_filing_undated_doc_never_suppresses():
    """A matching doc with no usable created_at cannot prove recency,
    so it must not suppress a genuinely new filing."""
    filed = []
    doc = _BugDoc(
        {
            "uid": "u1",
            "description": (
                "[self-check] check=nav:explore category=navigation "
                "session=s-old run=oldrun env=test-env error=boom"
            ),
            "status": "new",
            "created_at": None,
        },
        doc_id="bug-undated",
    )
    runner = _dedupe_runner(_BugDb([doc]), filed)
    result = CheckResult("nav:explore", "navigation", self_check.FAIL, "", "boom")
    asyncio.run(runner._file_bug(result))
    assert len(filed) == 1
    assert result.bug_id == "bug-new"


def test_bug_filing_dedupe_sees_docs_beyond_first_fifty():
    """The de-dupe fetch must cover the user's whole recent set: with 60
    prior reports and the identical one at position 55, the old
    limit(50) fetch missed it and filed a duplicate."""
    filed = []
    docs = [
        _filed_doc("other", hours_ago=1, doc_id=f"bug-filler-{i}",
                   check=f"nav:other{i}")
        for i in range(55)
    ]
    docs.append(_filed_doc("boom", doc_id="bug-match"))
    docs += [
        _filed_doc("other", hours_ago=1, doc_id=f"bug-tail-{i}",
                   check=f"nav:tail{i}")
        for i in range(4)
    ]
    runner = _dedupe_runner(_BugDb(docs), filed)
    result = CheckResult("nav:explore", "navigation", self_check.FAIL, "", "boom")
    asyncio.run(runner._file_bug(result))
    assert filed == []
    assert result.bug_id == "bug-match"
