"""``analysis_mode`` — the Westworld-style diagnostic mode (founder
order 2026-11-08). Subset coverage per the founder's subset-only test
rule: the deterministic triggers (text slash + voice phrases), the
fuzzy password matcher (every required accept/reject from the brief),
the gate flow (wrong stays in character, 3 fails cancel, correct
enters), the analysis prompt block carrying the signed-in user's core
memories only while in mode, and the exit phrase."""

import pytest

import analysis_mode as am
from fake_firestore import FakeDb

UID = "u-analysis"
SESSION = "s-analysis-1"


def _db_with_memories():
    return FakeDb(
        seed={
            ("users", UID, "profile", "main"): {
                "completeness": {"score": 42},
            },
            ("users", UID, "wiki_pages", "p1"): {
                "page_type": "profile",
                "ai_body": "Lives in San Jose and likes night markets.",
            },
            ("users", UID, "wiki_pages", "p2"): {
                "page_type": "taste",
                "ai_body": "Prefers dry humor and short answers.",
            },
            ("feedback", "fb-sc-1"): {
                "uid": UID,
                "note": "[self-check] run abc — feature suggestions:",
                "quote": "140 checks — 46 passed, 0 failed",
                "created_at": "2026-11-07T21:07:00+00:00",
            },
            ("bug_reports", "bug-1"): {
                "uid": UID,
                "status": "new",
                "title": "Web search did not finish",
            },
        }
    )


# --- triggers -----------------------------------------------------------------


@pytest.mark.parametrize(
    "text",
    [
        "/analysis-mode",
        "  /analysis-mode  ",
        "/ANALYSIS-MODE",
        "analysis mode",
        "Analysis Mode",
        "  analysis mode  ",
        "analysis mode.",
        "analysis mode!",
    ],
)
def test_text_trigger_matches_bare_slash_command(text):
    assert am.is_analysis_mode_command(text)


@pytest.mark.parametrize(
    "text",
    [
        "",
        "run analysis mode",
        "analysis mode please",
        "what is analysis mode?",
        "/analysis-mode please",
        "please /analysis-mode",
        "/analysismode",
    ],
)
def test_text_trigger_rejects_conversation(text):
    assert not am.is_analysis_mode_command(text)


@pytest.mark.parametrize(
    "text,expected",
    [
        ("analysis mode", "analysis"),
        ("Analysis mode.", "analysis"),
        ("enter analysis mode", "analysis"),
        ("self check", "self_check"),
        ("run a self check", "self_check"),
        ("run self-check", "self_check"),
    ],
)
def test_voice_triggers(text, expected):
    assert am.detect_voice_trigger(text) == expected


@pytest.mark.parametrize(
    "text",
    ["", "tell me about analysis mode", "can you run a self check for me", "check yourself", "analysis"],
)
def test_voice_triggers_reject_conversation(text):
    assert am.detect_voice_trigger(text) is None


# --- fuzzy password matcher -----------------------------------------------------


@pytest.mark.parametrize(
    "text",
    [
        "Pineapple nachos",
        "pineapple nachos",
        "pineapple nacho",       # singular second word
        "pine apple nachos",     # split first word
        "pine apple nacho",
        "pineapple nachoz",      # small spelling error, second word
        "pinapple nachos",       # small spelling error, first word
        "Pineapple, nachos!",    # punctuation + case
    ],
)
def test_password_accepts(text):
    assert am.password_matches(text)


@pytest.mark.parametrize(
    "text",
    [
        "",
        "pineapple",             # only one core word
        "nachos",                # only one core word
        "nachos pineapple",      # reversed order
        "banana pancakes",       # unrelated
        "pineapple pizza",       # second word wrong
        "apple nachos",          # first word wrong (not the split form)
        "pineapple nachos please",  # extra words are not the phrase
    ],
)
def test_password_rejects(text):
    assert not am.password_matches(text)


# --- gate flow ------------------------------------------------------------------


def test_gate_flow_wrong_then_correct_then_exit():
    db = _db_with_memories()
    # Trigger asks for the password; Ayma stays in character until it passes.
    reply = am.handle_chat_turn(db, UID, "/analysis-mode", SESSION)
    assert reply == am.ASK_LINE
    assert am.active_prompt_block(db, UID, SESSION) == ""

    # A wrong password is an attempt, not an entry.
    reply = am.handle_chat_turn(db, UID, "banana pancakes", SESSION)
    assert "not it" in reply and "2 attempts left" in reply
    assert am.active_prompt_block(db, UID, SESSION) == ""

    # The correct phrase (a fuzzy hearing of it) enters, with a live brief.
    reply = am.handle_chat_turn(db, UID, "pine apple nacho", SESSION)
    assert reply.startswith(am.ENTER_LINE)
    assert "Model stack in use" in reply

    # In mode, a normal question falls through to the model (no reply here).
    assert am.handle_chat_turn(db, UID, "what is wrong with you?", SESSION) is None

    # Exit phrase leaves the mode, back to normal character.
    reply = am.handle_chat_turn(db, UID, "exit analysis mode", SESSION)
    assert reply == am.EXIT_LINE
    assert am.active_prompt_block(db, UID, SESSION) == ""


def test_gate_flow_plain_phrase_trigger():
    db = _db_with_memories()
    # The typed plain phrase starts the same gate as the slash command.
    reply = am.handle_chat_turn(db, UID, "analysis mode", SESSION)
    assert reply == am.ASK_LINE
    assert am.active_prompt_block(db, UID, SESSION) == ""


def test_gate_cancels_after_three_failures():
    db = _db_with_memories()
    assert am.handle_chat_turn(db, UID, "/analysis-mode", SESSION) == am.ASK_LINE
    am.handle_chat_turn(db, UID, "wrong one", SESSION)
    am.handle_chat_turn(db, UID, "wrong two", SESSION)
    reply = am.handle_chat_turn(db, UID, "wrong three", SESSION)
    assert reply == am.CANCEL_LINE
    # Gate closed: a later non-command message is ordinary chat again.
    assert am.handle_chat_turn(db, UID, "hello", SESSION) is None


def test_gate_is_scoped_to_the_session():
    db = _db_with_memories()
    am.handle_chat_turn(db, UID, "/analysis-mode", SESSION)
    am.handle_chat_turn(db, UID, "pineapple nachos", SESSION)
    assert am.active_prompt_block(db, UID, SESSION) != ""
    # A different session never inherits the open mode.
    assert am.active_prompt_block(db, UID, "s-other-session") == ""
    assert am.handle_chat_turn(db, UID, "what is wrong?", "s-other-session") is None


# --- analysis-mode state: prompt/context ----------------------------------------


def test_prompt_block_carries_core_memories_and_diagnostics():
    db = _db_with_memories()
    am.handle_chat_turn(db, UID, "/analysis-mode", SESSION)
    am.handle_chat_turn(db, UID, "pineapple nachos", SESSION)
    block = am.active_prompt_block(db, UID, SESSION)
    assert block.startswith("[ANALYSIS MODE ACTIVE]")
    assert "persona is OFF" in block
    # Core memories: the signed-in user's wiki pages are pulled in full.
    assert "night markets" in block
    assert "dry humor" in block
    # Diagnostics: last self-check + open bug reports, from real records.
    assert "46 passed, 0 failed" in block
    assert "Web search did not finish" in block
    # Honesty rule for unverified failures
    norm = " ".join(block.lower().split())
    assert "when asked why something failed" in norm
    assert "cannot see the cause" in norm
    assert "flagged in testing" in norm
    assert "bug was logged" in norm


def test_analysis_prompt_block_carries_failure_honesty_rule():
    db = _db_with_memories()
    block = am.build_analysis_block(db, UID)
    norm = " ".join(block.lower().split())
    assert "when asked why something failed" in norm
    assert "cannot see the cause" in norm
    assert "flagged in testing" in norm
    assert "bug was logged" in norm


def test_prompt_block_absent_out_of_mode():
    db = _db_with_memories()
    assert am.active_prompt_block(db, UID, SESSION) == ""
    block = am.build_analysis_block(db, UID)
    assert "night markets" in block  # the builder itself pulls the same pull


# --- exit phrase ------------------------------------------------------------------


@pytest.mark.parametrize(
    "text",
    [
        "exit analysis mode",
        "Exit analysis mode.",
        "/exit-analysis-mode",
        "exit analisis mode",   # fuzzy voice hearing
        "exit analysis modes",
    ],
)
def test_exit_phrases(text):
    assert am.is_exit_command(text)


@pytest.mark.parametrize(
    "text",
    ["", "exit", "leave analysis mode please", "what is analysis mode", "exit mode"],
)
def test_exit_rejects_conversation(text):
    assert not am.is_exit_command(text)
