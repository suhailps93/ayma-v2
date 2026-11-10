from transcript import ROLE_AYMA, ROLE_USER, Turn, strip_speech_markup


def test_strips_a_markup_only_line_to_empty():
    # Founder bug 2026-11-09: the exact leaked turn.
    assert strip_speech_markup("<no speech>{pause}") == ""
    assert strip_speech_markup("{pause}") == ""
    assert strip_speech_markup("  <break time=\"400ms\"/>  ") == ""


def test_keeps_the_step_text_around_an_inline_directive():
    # Sanitizing must not swallow the real guided-tour step.
    assert (
        strip_speech_markup("Take a look {pause} and just say next.")
        == "Take a look and just say next."
    )
    assert strip_speech_markup("Hello{pause}there") == "Hello there"
    assert strip_speech_markup("I'm done. {sigh}") == "I'm done."


def test_covers_the_markup_family():
    for token in (
        "<no speech>",
        "<nospeech>",
        "<no-speech>",
        "{pause}",
        "{ long pause }",
        "[laughs]",
        "{laugh}",
        "<prosody rate=\"slow\">",
        "</prosody>",
        "<say-as interpret-as=\"characters\">",
        "{whisper}",
        "[pause]",
    ):
        assert strip_speech_markup(f"ok {token} done") == "ok done", token


def test_leaves_ordinary_prose_untouched():
    # No false positives on genuine brackets/braces/comparisons.
    for text in (
        "a < b and c > d",
        "use {curly} braces in code",
        "the array is arr[0]",
        "meet me at 3 (sharp)",
        "e.g. <example> tags in XML we discussed",
    ):
        assert strip_speech_markup(text) == text, text


def test_created_at_is_excluded_from_equality_and_hash():
    # Per-turn timestamps must not disturb (role, text) de-duplication.
    a = Turn(ROLE_AYMA, "hi", created_at="2026-11-09T05:27:00+00:00")
    b = Turn(ROLE_AYMA, "hi", created_at="2026-11-09T05:40:00+00:00")
    c = Turn(ROLE_AYMA, "hi")
    assert a == b == c
    assert len({a, b, c}) == 1
    assert Turn(ROLE_USER, "hi") != a


def test_turn_created_at_defaults_to_none():
    assert Turn(ROLE_USER, "hey").created_at is None
