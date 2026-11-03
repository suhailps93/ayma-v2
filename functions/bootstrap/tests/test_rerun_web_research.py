"""The ``rerun_web_research`` skill + ``deep_dive_delivery.schedule_self_refresh``.

Founder bug 2026-11-03: asked Ayma in a voice call to "re-run the web search
report" with that report open; she ran an inline ``deep_dive`` self-lookup that
hung on "Searching the web…". The fix is a dedicated re-run tool that kicks off
the SAME queued background refresh the report screen's "Search again" button
does and returns immediately — never blocking (or hanging) the turn — in both
text and voice.
"""

import asyncio

import deep_dive
import deep_dive_delivery
import token_ledger
from skills import rerun_web_research, session_tool_declarations


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


class _DummyDB:
    pass


def test_registered_in_both_text_and_voice_tool_sets():
    # Text declarations.
    assert "rerun_web_research" in {d["name"] for d in session_tool_declarations()}
    # Voice uses the SAME _REGISTRY (make_livekit_tools iterates it), so
    # membership in all_skills() proves the voice set has it too — without
    # importing livekit-agents.
    import skills

    assert any(s.name == "rerun_web_research" for s in skills.all_skills())


def test_rerun_queues_background_refresh_and_returns_immediately(monkeypatch):
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "Dana Reyes")
    monkeypatch.setattr(
        deep_dive, "profile_dive_context", lambda db, uid, name="": "San Jose"
    )
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    marks = []
    monkeypatch.setattr(
        deep_dive, "mark_run",
        lambda db, uid, rid, status: marks.append((rid, status)),
    )
    jobs = []

    async def _fake_job(db, uid, **kw):
        jobs.append((uid, kw))

    # The job must NOT be the inline research — it's spawned detached and the
    # tool returns at once. Patch the shared runner so no real search fires.
    monkeypatch.setattr(deep_dive_delivery, "run_job", _fake_job)

    async def _drive():
        fn = rerun_web_research.SKILL.bind(_DummyDB(), "me")
        out = await fn()
        await asyncio.sleep(0)  # let the detached refresh task start
        return out

    out = _run(_drive())
    report_id = deep_dive.dive_report_id(name="Dana Reyes")

    # Immediate, honest "on it" reply with the report marker (so chat shows the
    # existing report card while it refreshes).
    assert "re-running your web research" in out.lower()
    assert f"[deep_dive:{report_id}]" in out
    # The run was marked running (so the screen's banner tracks it)…
    assert (report_id, deep_dive.RUN_RUNNING) in marks
    # …and the background refresh was a self-dive, forced (like the button).
    assert jobs and jobs[0][0] == "me"
    assert jobs[0][1]["is_self"] is True
    assert jobs[0][1]["force"] is True
    assert jobs[0][1]["target"] == ""


def test_rerun_without_a_name_hints_and_schedules_nothing(monkeypatch):
    monkeypatch.setattr(deep_dive, "profile_full_name", lambda db, uid: "")
    monkeypatch.setattr(token_ledger, "check", lambda uid: None)
    scheduled = []
    monkeypatch.setattr(
        deep_dive_delivery, "run_job",
        lambda *a, **k: scheduled.append(1),
    )

    out = _run(rerun_web_research.SKILL.bind(_DummyDB(), "me")())
    assert "name" in out.lower()
    assert "[deep_dive:" not in out
    assert not scheduled


def test_rerun_out_of_credits_never_schedules(monkeypatch):
    def _cap(uid):
        raise token_ledger.TokenCapExceeded()

    monkeypatch.setattr(token_ledger, "check", _cap)
    called = []
    monkeypatch.setattr(
        deep_dive_delivery, "schedule_self_refresh",
        lambda db, uid: called.append(1) or ("x", "y"),
    )

    out = _run(rerun_web_research.SKILL.bind(_DummyDB(), "me")())
    assert out and "[deep_dive:" not in out
    assert not called  # capped → no search queued
