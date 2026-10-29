"""The navigation-tool chip only shows on a real navigation (founder bug
2026-10-28: a false "Opened that conversation" chip showed even when the open
failed). ``outcome_label`` returns ``NO_CHIP`` for any non-``navigated:``
result so both surfaces (text ``tools_used`` and the voice ``tool_used`` event)
suppress the success chip."""

import tool_labels
from tool_labels import NO_CHIP, outcome_label


def test_nav_tool_shows_chip_only_on_real_navigation():
    assert outcome_label(
        "open_message_thread",
        "navigated: screen=dm — the conversation with Jordan Lee is open.",
    ) is None  # None -> fall back to the "Opened that conversation" chip


def test_nav_tool_suppresses_chip_when_not_found():
    assert outcome_label(
        "open_message_thread",
        "I couldn't find an existing conversation with sahil.",
    ) == NO_CHIP


def test_nav_tool_suppresses_chip_when_app_did_not_navigate():
    assert outcome_label("open_profile", tool_labels_not_navigated()) == NO_CHIP


def test_every_nav_tool_is_gated():
    for name in (
        "open_message_thread", "open_screen", "open_profile",
        "open_match_report", "search_explore",
    ):
        assert outcome_label(name, "whatever, not navigated") == NO_CHIP
        assert outcome_label(name, "navigated: screen=x.") is None


def test_non_nav_tools_are_unaffected():
    assert outcome_label("read_dm_thread", "Recent messages:\n…") is None
    assert outcome_label("send_dm_message", "PREVIEW ONLY, nothing sent yet.") == (
        "Drafted a message"
    )


def test_list_conversations_has_both_labels():
    assert tool_labels.TOOL_LABELS["list_conversations"]
    assert tool_labels.WORKING_LABELS["list_conversations"]


def tool_labels_not_navigated() -> str:
    from skills import app_control

    return app_control._NOT_NAVIGATED
