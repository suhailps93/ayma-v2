"""``self_check`` — the deterministic ``/self-check`` runner (founder
order 2026-11-06). Covers the strict slash-command trigger, the runner's
PASS path, the FAIL path (a bug is filed at failure time, once per check
per run, with the session/run context in the description), the
write+revert restoration guarantee, the exclusion guard, and manifest
integrity against the real session tool declarations."""

import asyncio

import pytest

import self_check
from self_check import SelfCheckRunner, _Deps


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
            }
        )
        return fns

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
    assert "0 FAIL" in report
    assert "SELF-CHECK" in report and "s-test" in report


# --- runner: FAIL path --------------------------------------------------------

def test_runner_failures_file_bugs_at_failure_time_with_context():
    h = _Harness(fail_nav={"explore"}, web_search_fails=True)
    runner = h.runner()
    report = asyncio.run(runner.run())

    by_name = {r.name: r for r in runner.results}
    assert by_name["nav:explore"].status == self_check.FAIL
    assert by_name["tool:web_search"].status == self_check.FAIL
    assert "DirectGoogleDisabledError" in by_name["tool:web_search"].error
    # Exactly one bug per failing check, filed during the run.
    assert len(h.bugs) == 2
    nav_bug = [b for b in h.bugs if "check=nav:explore" in b][0]
    assert "session=s-test" in nav_bug and "run=" in nav_bug
    assert "did NOT navigate" in nav_bug
    web_bug = [b for b in h.bugs if "check=tool:web_search" in b][0]
    assert "DirectGoogleDisabledError" in web_bug
    assert by_name["nav:explore"].bug_id.startswith("bug-")
    assert "2 FAIL" in report

    # Dedupe: filing the same check again in this run is a no-op.
    asyncio.run(runner._file_bug(by_name["nav:explore"]))
    assert len(h.bugs) == 2


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
    # Every result bubbles exactly once, in plain names with marks:
    # start + one per result + summary + suggestions.
    assert len(lines) == 1 + len(runner.results) + 2
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
    # The summary is ONE bubble listing every result, with counts.
    summary = [ln for ln in lines if ln.startswith("\U0001f9ea Self-check summary")]
    assert len(summary) == 1
    summary = summary[0]
    assert f"{len(runner.results)} checks" in summary
    marked = [
        ln
        for ln in summary.split("\n")
        if ln[:1] in ("\u2705", "\u274c", "\u23ed")
    ]
    assert len(marked) == len(runner.results)
    for r in runner.results:
        assert runner._line(r) in summary


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
    bubble = [ln for ln in lines if ln.startswith("\U0001f4a1 Feature ideas")]
    assert len(bubble) == 1
    bubble = bubble[0]
    # Derived from THIS run: the explore FAIL and the copilot SKIP both
    # become concrete, plain-language suggestions.
    assert "Fix Nav to Explore" in bubble
    assert "Add Point at something on a shared screen to this build" in bubble
    # One consolidated record for the whole run, never one per gap.
    assert len(h.record_feedback_calls) == 1
    category, note = h.record_feedback_calls[0]
    assert category == "self_check"
    assert "Nav to Explore" in note
    assert "Point at something on a shared screen" in note


# --- nav cluster: window + same-command re-wait ----------------------------


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


def test_nav_rewaits_once_on_the_same_command(monkeypatch):
    # First window silent (client watch gap), ack lands in the second:
    # the check PASSES and only ONE command was ever queued.
    calls = _patched_nav(monkeypatch, [None, {"ok": True}])
    runner = SelfCheckRunner(object(), "u1", deps=_Deps(tool_fns={}))
    status, detail, error = asyncio.run(
        runner._do_nav({"key": "explore", "label": "Explore"})
    )
    assert status == self_check.PASS
    assert calls == {"queue": 1, "ack": 2}


def test_nav_fails_only_after_both_windows(monkeypatch):
    calls = _patched_nav(monkeypatch, [None, None])
    runner = SelfCheckRunner(object(), "u1", deps=_Deps(tool_fns={}))
    status, detail, error = asyncio.run(
        runner._do_nav({"key": "explore", "label": "Explore"})
    )
    assert status == self_check.FAIL
    assert "12s" in error  # two 6s windows, honestly reported
    assert calls == {"queue": 1, "ack": 2}
