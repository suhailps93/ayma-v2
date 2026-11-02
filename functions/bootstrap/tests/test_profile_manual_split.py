"""Tests verifying Tier-2 sweep monolith split #12 (profile_manual.py split).

Verifies that the profile_manual monolith is properly factored into:
- profile_manual_common
- profile_manual_text
- profile_manual_diff
- profile_manual_moderation
- profile_manual_save
- profile_manual_proposals
- profile_manual (facade re-exporting all symbols)
"""

import profile_manual
import profile_manual_common
import profile_manual_diff
import profile_manual_moderation
import profile_manual_proposals
import profile_manual_save
import profile_manual_text


def _assert_reexported(module, symbols):
    for sym in symbols:
        assert hasattr(module, sym), f"{module.__name__} missing {sym}"
        assert hasattr(profile_manual, sym), f"profile_manual facade missing {sym}"
        assert getattr(profile_manual, sym) is getattr(module, sym), (
            f"profile_manual facade {sym} is not {module.__name__}.{sym}"
        )


def test_facade_reexports_all_common_symbols():
    _assert_reexported(
        profile_manual_common,
        [
            "_mark_avatar_stale",
            "_PROMPTS",
            "MAX_TEXT_CHARS",
            "MAX_TITLE_CHARS",
            "MAX_CUSTOM_SECTIONS",
            "F_CUSTOM",
            "CUSTOM_PAGE_TYPE",
            "_CUSTOM_ID_PREFIX",
            "_MAX_SLUG_CHARS",
            "F_PINNED",
            "F_PROPOSAL",
            "_PIN_SIMILAR",
            "_SUPPRESS_WINDOW",
            "KIND_REMOVED",
            "KIND_ADDED",
            "KIND_WORDING",
            "_KINDS",
            "_HEADING",
            "_URL",
            "_EMAIL",
            "_PHONE",
            "_MIN_PHONE_DIGITS",
            "_CLASSIFY_SCHEMA",
            "_MODERATION_SCHEMA",
            "ProfileTextError",
            "_prompt",
            "_norm",
        ],
    )


def test_facade_reexports_all_text_symbols():
    _assert_reexported(
        profile_manual_text,
        [
            "public_sections",
            "assemble_text",
            "text_version",
            "get_text",
            "_parse_headings",
            "_clean_body",
            "_reserved_titles",
            "validate_title",
            "custom_pages",
            "_slug",
            "_new_page_id",
            "plan_sections",
        ],
    )


def test_facade_reexports_all_diff_symbols():
    _assert_reexported(
        profile_manual_diff,
        [
            "_blocks",
            "diff_segments",
            "_classify",
        ],
    )


def test_facade_reexports_all_moderation_symbols():
    _assert_reexported(
        profile_manual_moderation,
        [
            "check_contact_info",
            "_moderate",
        ],
    )


def test_facade_reexports_all_save_symbols():
    _assert_reexported(
        profile_manual_save,
        [
            "_build_body",
            "save_text",
            "_write_section",
        ],
    )


def test_facade_reexports_all_proposals_symbols():
    _assert_reexported(
        profile_manual_proposals,
        [
            "_similar",
            "_pins_to_append",
            "_prune_pins",
            "preserve",
            "_edited_within_window",
            "route_ai_update",
            "_title",
            "_iter_changes",
            "_change_items",
            "_dedupe_changes",
            "_decided_map",
            "_rebuild_public",
            "_compose_body",
            "_write_decided",
            "_live_matches_decisions",
            "list_proposals",
            "F_SUGGEST_NOTIFIED",
            "pending_change_keys",
            "consume_new_suggestions",
            "_load_proposal",
            "_decide_one",
            "apply_change",
            "dismiss_change",
            "_decide_all",
            "apply_proposal",
            "dismiss_proposal",
        ],
    )


def test_facade_reexports_dependencies():
    for sym in ("gemini", "rb", "story", "token_ledger", "page_types", "utcnow"):
        assert hasattr(profile_manual, sym), f"profile_manual facade missing {sym}"


def test_facade_all_covers_public_entry_points():
    assert set(profile_manual.__all__) >= {
        "get_text",
        "save_text",
        "ProfileTextError",
        "check_contact_info",
        "validate_title",
        "plan_sections",
        "diff_segments",
        "preserve",
        "route_ai_update",
        "list_proposals",
        "pending_change_keys",
        "consume_new_suggestions",
        "apply_change",
        "dismiss_change",
        "apply_proposal",
        "dismiss_proposal",
    }
