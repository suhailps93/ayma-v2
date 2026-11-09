"""The navigation-tool chip only shows on a real navigation (founder bug
2026-10-28: a false "Opened that conversation" chip showed even when the open
failed). ``outcome_label`` returns ``NO_CHIP`` for any non-``navigated:``
result so both surfaces (text ``tools_used`` and the voice ``tool_used`` event)
suppress the success chip.

Same gating for the image tools (founder report 2026-11-09: the "Generated an
image" chip showed on a reply whose generation had been refused server-side):
``generate_image`` / ``edit_photo`` earn their chip only on the skill's exact
success line."""

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
        "open_match_report", "search_explore", "open_notification",
    ):
        assert outcome_label(name, "whatever, not navigated") == NO_CHIP
        assert outcome_label(name, "navigated: screen=x.") is None


def test_non_nav_tools_are_unaffected():
    assert outcome_label("read_dm_thread", "Recent messages:\n…") is None
    assert outcome_label("send_dm_message", "PREVIEW ONLY, nothing sent yet.") == (
        "Drafted a message"
    )


def test_generate_image_chip_only_on_success():
    # The skill's exact success line (skills/generate_image.py) earns the
    # chip: outcome None -> the "Generated an image" label shows.
    assert outcome_label(
        "generate_image", "done — sent the image in the chat"
    ) is None
    assert tool_labels.tool_label("generate_image") == "Generated an image"


def test_generate_image_no_chip_on_failure():
    # The skill's real failure lines (model refused / save failed) get no
    # chip at all — the reply text already explains the failure.
    assert outcome_label(
        "generate_image",
        "I couldn't generate that image just now (403 PERMISSION_DENIED).",
    ) == NO_CHIP
    assert outcome_label(
        "generate_image",
        "I made the image but couldn't save it just now (boom).",
    ) == NO_CHIP
    assert outcome_label("generate_image", None) == NO_CHIP


def test_edit_photo_chip_only_on_success():
    # The skill's exact success line (skills/photo_edit.py) earns the chip:
    # outcome None -> the existing fallback label shows, unchanged.
    assert outcome_label(
        "edit_photo", "done — sent the edited photo in the chat"
    ) is None
    assert tool_labels.tool_label("edit_photo") == "Edit photo"


def test_edit_photo_no_chip_on_failure():
    assert outcome_label(
        "edit_photo",
        "I couldn't generate that edited photo just now (403) — let me "
        "just give you some advice instead.",
    ) == NO_CHIP
    assert outcome_label(
        "edit_photo", "I made the edit but couldn't save it just now (boom)."
    ) == NO_CHIP
    # Another photo tool's success line is not edit_photo's marker.
    assert outcome_label("edit_photo", "done — removed that photo") == NO_CHIP
    assert outcome_label("edit_photo", None) == NO_CHIP


def test_list_conversations_has_both_labels():
    assert tool_labels.TOOL_LABELS["list_conversations"]
    assert tool_labels.WORKING_LABELS["list_conversations"]


def test_is_guided_tour_turn_detects_tour_labels_only():
    # Every guided-tour tool's label is recognised; nothing else is (so only
    # tour narration is suppressed from persistence — §11.2b).
    for name in tool_labels.GUIDED_TOUR_TOOLS:
        assert tool_labels.is_guided_tour_turn([tool_labels.TOOL_LABELS[name]])
    assert not tool_labels.is_guided_tour_turn(["Opened that for you"])
    assert not tool_labels.is_guided_tour_turn([])
    assert not tool_labels.is_guided_tour_turn(None)
    # A mixed turn that ran a tour tool still counts.
    assert tool_labels.is_guided_tour_turn(
        ["Opened that for you", "Moved to the next step"])


def tool_labels_not_navigated() -> str:
    from skills import app_control

    return app_control._NOT_NAVIGATED
