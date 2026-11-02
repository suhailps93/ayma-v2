"""Tests verifying Tier-2 sweep monolith split #12 (story.py split).

Verifies that the story monolith is properly factored into:
- story_common
- story_spans
- story_pages
- story_versions
- story_reads
- story_writes
- story_chat
- story (facade re-exporting all symbols)
"""

import story
import story_chat
import story_common
import story_pages
import story_reads
import story_spans
import story_versions
import story_writes


def _assert_reexported(module, symbols):
    for sym in symbols:
        assert hasattr(module, sym), f"{module.__name__} missing {sym}"
        assert hasattr(story, sym), f"story facade missing {sym}"
        assert getattr(story, sym) is getattr(module, sym), (
            f"story facade {sym} is not {module.__name__}.{sym}"
        )


def test_facade_reexports_all_common_symbols():
    _assert_reexported(
        story_common,
        [
            "WIKI_PAGES",
            "F_AI_BODY",
            "F_USER_EDITS",
            "F_VISIBILITY",
            "F_USER_HIDDEN",
            "F_USER_UPDATED_AT",
            "F_AI_BODY_UPDATED_AT",
            "F_PAGE_TYPE",
            "F_TITLE",
            "F_SUPPRESS_PROPOSAL",
            "F_PENDING_PROPOSAL",
            "VIS_PUBLIC",
            "VIS_PRIVATE",
            "VIS_AI_ONLY",
            "AUTHOR_USER",
            "AUTHOR_AYMA",
            "SNAPSHOT_DEBOUNCE_SECONDS",
            "NOTE_AI_LEARNED",
            "PRIVATE_OPEN",
            "PRIVATE_CLOSE",
            "AI_ONLY_OPEN",
            "AI_ONLY_CLOSE",
            "_SPAN_RE",
            "SKILL_PAGE_IDS",
            "_SKILL_ORDER",
            "_SKILL_TITLES",
            "REPORT_LINKED_PAGE_IDS",
            "_NARRATIVE_ORDER",
            "_server_ts",
            "_now_ms",
            "humanize",
            "_label",
            "_section_title",
            "_section_order",
            "_pages_col",
            "_to_epoch",
        ],
    )


def test_facade_reexports_all_spans_symbols():
    _assert_reexported(
        story_spans,
        [
            "parse_spans",
            "_serialize_spans",
            "strip_private_spans",
            "strip_ai_only_spans",
            "sentence_spans",
            "apply_span_action",
        ],
    )


def test_facade_reexports_all_pages_symbols():
    _assert_reexported(
        story_pages,
        [
            "_effective_body",
            "_editor_pages",
            "_all_pages",
            "_ai_updated_since_user",
            "_display_body",
            "_skill_report_id",
            "_photo_url_safe",
            "_latest_report",
            "_report_markdown",
            "_URL_RE",
            "_web_findings_markdown",
        ],
    )


def test_facade_reexports_all_versions_symbols():
    _assert_reexported(
        story_versions,
        [
            "SECTION_VERSIONS",
            "MAX_SECTION_VERSIONS",
            "_section_versions_col",
            "_section_history",
            "_snapshot_section",
            "list_section_versions",
            "get_section_version",
        ],
    )


def test_facade_reexports_all_reads_symbols():
    _assert_reexported(
        story_reads,
        [
            "_section_dict",
            "get_story",
            "get_ai_notes",
            "get_section_provenance",
        ],
    )


def test_facade_reexports_all_writes_symbols():
    _assert_reexported(
        story_writes,
        [
            "_require_page",
            "save_section",
            "set_visibility",
            "remove_section",
            "revert_section",
            "maybe_snapshot_section_after_ai",
        ],
    )


def test_facade_reexports_all_chat_symbols():
    _assert_reexported(
        story_chat,
        [
            "_CHAT_SYS",
            "_CHAT_SCHEMA",
            "_chat_contents",
            "edit_section",
        ],
    )


def test_facade_reexports_dependencies():
    for sym in ("gemini", "rb", "token_ledger", "firestore", "iso_or_none"):
        assert hasattr(story, sym), f"story facade missing {sym}"


def test_facade_all_covers_public_entry_points():
    assert set(story.__all__) >= {
        "get_story",
        "get_ai_notes",
        "get_section_provenance",
        "save_section",
        "set_visibility",
        "remove_section",
        "revert_section",
        "edit_section",
        "parse_spans",
        "list_section_versions",
        "get_section_version",
    }
