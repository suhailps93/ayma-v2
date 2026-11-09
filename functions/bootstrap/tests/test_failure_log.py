"""``failure_log`` + ``read_recent_failures`` — analysis-mode failure
records (founder order 2026-11-09, ~08:34 PT). Subset coverage per the
founder's subset-only rule:

* the stored line is the decisive error text trimmed to 1–2 lines — a
  traceback keeps only its final, causal line — with credential-looking
  values stripped;
* the dispatch capture (``skills._failure_captured``, the wrapper every
  bound tool callable passes through on both surfaces) records a raise,
  an ``error:``-form result, and a failed app command — and records
  NOTHING for a success or an ordinary refusal;
* ``generate_image``'s provider failure is recorded with the RAW
  provider line (the proven first case — the skill swallows the
  exception into a soft reply, so it records at the failure site);
* retention is capped per user, and topic matching returns the asked
  failure ("why did the image fail" → the image-generation record);
* the reader tool is gated to analysis mode: invisible in the default
  text tool set, refusing outside the mode, refusing for a different
  session, and structurally unable to read another user's records;
* the answer shape: diagnostics carry the recorded lines and the
  analysis block instructs the exact, short quote.

Every provider call is faked — no real model is ever called.
"""

import asyncio

import analysis_mode as am
import failure_log
import skills
from fake_firestore import FakeDb
from skills import generate_image as generate_image_mod
from skills import read_failures

UID = "u-failures"
OTHER = "u-someone-else"
SESSION = "s-failures-1"


def _enter_analysis(db, uid=UID, session=SESSION):
    assert am.handle_chat_turn(db, uid, "/analysis-mode", session) == am.ASK_LINE
    # A fuzzy hearing of the password — the same shape the analysis-mode
    # suite enters with; the canonical phrase is never written here.
    reply = am.handle_chat_turn(db, uid, "pine apple nacho", session)
    assert reply is not None and reply.startswith(am.ENTER_LINE)


# --- the stored line: trim + sanitize -----------------------------------------


def test_record_trims_traceback_to_final_line():
    db = FakeDb()
    tb = (
        "Traceback (most recent call last):\n"
        '  File "agent.py", line 10, in <module>\n'
        "    boom()\n"
        "ValueError: the real cause"
    )
    assert failure_log.record_failure(db, UID, "deep_dive", tb)
    rows = failure_log.recent_failures(db, UID)
    assert len(rows) == 1
    assert rows[0]["action"] == "deep_dive"
    assert rows[0]["error"] == "ValueError: the real cause"


def test_record_keeps_at_most_two_lines():
    db = FakeDb()
    failure_log.record_failure(
        db, UID, "web_search", "line one\nline two\nline three\nline four"
    )
    rows = failure_log.recent_failures(db, UID)
    assert rows[0]["error"] == "line one\nline two"
    assert len(rows[0]["error"].splitlines()) <= 2


def test_record_strips_credentials():
    db = FakeDb()
    failure_log.record_failure(
        db,
        UID,
        "web_search",
        "403 denied for key AIzaFAKEKEYFAKEKEYFAKEKEYFAKEKEY123 with "
        "Authorization: Bearer FAKEBEARERTOKEN0123456789 and "
        "api_key=FAKEAPIKEYVALUE",
    )
    error = failure_log.recent_failures(db, UID)[0]["error"]
    assert "AIzaFAKEKEY" not in error
    assert "FAKEBEARERTOKEN" not in error
    assert "FAKEAPIKEYVALUE" not in error
    assert "[redacted]" in error


def test_records_capped_per_user():
    db = FakeDb()
    for i in range(failure_log.MAX_RECORDS + 5):
        failure_log.record_failure(db, UID, "some_tool", f"boom {i}")
    rows = failure_log.recent_failures(db, UID, limit=1000)
    assert len(rows) == failure_log.MAX_RECORDS


def test_topic_matching_returns_the_asked_failure():
    db = FakeDb()
    failure_log.record_failure(
        db, UID, "generate_image", "403 PERMISSION_DENIED on the image model"
    )
    failure_log.record_failure(db, UID, "go_back", "the app did not respond")
    rows = failure_log.recent_failures(db, UID, topic="image")
    assert [r["action"] for r in rows] == ["generate_image"]
    rows = failure_log.recent_failures(db, UID, topic="navigation back")
    assert [r["action"] for r in rows] == ["go_back"]


# --- dispatch capture (skills._failure_captured) -------------------------------


def test_dispatch_wrapper_records_raised_exception():
    db = FakeDb()

    def boom():
        raise RuntimeError("provider said no\nmore detail here\neven more")

    wrapped = skills._failure_captured(boom, "some_tool", db, UID, "text")
    try:
        wrapped()
    except RuntimeError:
        pass
    else:  # the raise must pass through untouched
        raise AssertionError("wrapper swallowed the exception")
    rows = failure_log.recent_failures(db, UID)
    assert len(rows) == 1
    assert rows[0]["action"] == "some_tool"
    assert rows[0]["error"] == "provider said no\nmore detail here"


def test_dispatch_wrapper_records_error_string_result():
    db = FakeDb()

    async def err_tool():
        return (
            "error: 403 PERMISSION_DENIED. Vertex AI API has not been "
            "used in project ayma-ai."
        )

    wrapped = skills._failure_captured(err_tool, "generate_image", db, UID, "text")
    result = asyncio.run(wrapped())
    assert result.startswith("error:")
    rows = failure_log.recent_failures(db, UID)
    assert len(rows) == 1
    assert rows[0]["error"].startswith("403 PERMISSION_DENIED")


def test_dispatch_wrapper_records_failed_app_command_only():
    db = FakeDb()

    def nav_fail():
        return "I tried to take you back, but the app didn't respond just now."

    def nav_ok():
        return "navigated: home"

    fail = skills._failure_captured(nav_fail, "go_back", db, UID, "text")
    ok = skills._failure_captured(nav_ok, "go_back", db, UID, "text")
    assert fail() == nav_fail()
    assert ok() == "navigated: home"
    rows = failure_log.recent_failures(db, UID)
    assert len(rows) == 1
    assert rows[0]["error"].startswith("I tried to take you back")


def test_dispatch_wrapper_records_nothing_on_success_or_refusal():
    db = FakeDb()

    def fine():
        return "done — sent the image in the chat"

    def refusal():
        return "tell me what you'd like me to create"

    assert (
        skills._failure_captured(fine, "generate_image", db, UID, "text")()
        == "done — sent the image in the chat"
    )
    skills._failure_captured(refusal, "generate_image", db, UID, "text")()
    assert failure_log.recent_failures(db, UID) == []


def test_generate_image_provider_failure_is_recorded(monkeypatch):
    async def failing(prompt, *, image=None, uid=None, feature=""):
        raise RuntimeError(
            "403 PERMISSION_DENIED. Vertex AI API has not been used in "
            "project ayma-ai before or it is disabled."
        )

    monkeypatch.setattr(generate_image_mod.gemini, "generate_image", failing)
    db = FakeDb()
    fn = generate_image_mod.SKILL.bind(db, UID, result={})
    out = asyncio.run(fn(prompt="a caricature of me"))
    # The user-facing reply is unchanged...
    assert out.startswith("I couldn't generate that image just now")
    # ...and the RAW provider line is on record for analysis mode.
    rows = failure_log.recent_failures(db, UID)
    assert len(rows) == 1
    assert rows[0]["action"] == "generate_image"
    assert "PERMISSION_DENIED" in rows[0]["error"]


# --- the reader tool: visibility + gate ----------------------------------------


def test_reader_declared_and_bound_only_in_analysis_mode():
    plain = {d["name"] for d in skills.session_tool_declarations()}
    assert "read_recent_failures" not in plain
    in_mode = {d["name"] for d in skills.session_tool_declarations(analysis=True)}
    assert "read_recent_failures" in in_mode

    db = FakeDb()
    assert "read_recent_failures" not in skills.make_session_tool_fns(db, UID)
    fns = skills.make_session_tool_fns(db, UID, analysis_session_id=SESSION)
    assert "read_recent_failures" in fns


def test_reader_refuses_outside_analysis_mode():
    db = FakeDb()
    failure_log.record_failure(
        db, UID, "generate_image", "403 PERMISSION_DENIED. the exact line."
    )
    read = read_failures.SKILL.bind(db, UID, session_id=SESSION)
    out = read()
    assert "analysis mode" in out
    assert "PERMISSION_DENIED" not in out  # nothing leaks outside the mode


def test_reader_refuses_for_a_different_session():
    db = FakeDb()
    failure_log.record_failure(
        db, UID, "generate_image", "403 PERMISSION_DENIED. the exact line."
    )
    _enter_analysis(db)
    read = read_failures.SKILL.bind(db, UID, session_id="s-a-different-call")
    assert "PERMISSION_DENIED" not in read()


def test_reader_quotes_exact_line_in_analysis_mode():
    db = FakeDb()
    failure_log.record_failure(
        db, UID, "generate_image", "403 PERMISSION_DENIED. the exact line."
    )
    _enter_analysis(db)
    read = read_failures.SKILL.bind(db, UID, session_id=SESSION)
    out = read(topic="image")
    assert "403 PERMISSION_DENIED. the exact line." in out
    assert "generate_image" in read()


def test_reader_says_plainly_when_nothing_recorded():
    db = FakeDb()
    _enter_analysis(db)
    read = read_failures.SKILL.bind(db, UID, session_id=SESSION)
    assert read() == "No failures have been recorded for this user."
    assert read(topic="image") == "No failure was recorded for 'image'."


def test_reader_never_crosses_users():
    db = FakeDb()
    failure_log.record_failure(
        db, UID, "generate_image", "403 PERMISSION_DENIED. a private line."
    )
    _enter_analysis(db, uid=OTHER, session="s-other")
    read = read_failures.SKILL.bind(db, OTHER, session_id="s-other")
    out = read()
    assert out == "No failures have been recorded for this user."
    assert "private line" not in out


# --- diagnostics + answer shape -------------------------------------------------


def test_diagnostics_carry_recent_failure_lines():
    db = FakeDb()
    assert any("none recorded" in ln for ln in am.diagnostic_lines(db, UID))
    failure_log.record_failure(
        db, UID, "generate_image", "403 PERMISSION_DENIED. the exact line."
    )
    lines = am.diagnostic_lines(db, UID)
    assert any(
        "generate_image" in ln and "PERMISSION_DENIED" in ln for ln in lines
    )


def test_analysis_block_instructs_exact_short_quote():
    db = FakeDb()
    block = am.build_analysis_block(db, UID)
    norm = " ".join(block.lower().split())
    assert "read_recent_failures" in norm
    assert "quote the recorded error line" in norm
    assert "no failure was recorded" in norm
