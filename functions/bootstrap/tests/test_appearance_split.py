"""Tests verifying Tier-2 sweep monolith split #10 (appearance.py split).

Verifies that the appearance monolith is properly factored into:
- appearance_storage
- appearance_reads
- appearance_engine
- appearance_batching
- appearance_corrections
- appearance (facade re-exporting all symbols)
"""

import pytest

import appearance
import appearance_batching
import appearance_corrections
import appearance_engine
import appearance_reads
import appearance_storage


def test_facade_reexports_all_storage_symbols():
    storage_symbols = [
        "REPORTS_COLLECTION",
        "REPORT_DOC_ID",
        "COLLECTION",
        "DOC_ID",
        "NEEDS_FACE",
        "NEEDS_BODY",
        "CAT_RAN",
        "CAT_SKIPPED",
        "CAT_NO_ELIGIBLE",
        "_MAX_FINDING_HISTORY",
        "_axis_ran",
        "_category_status",
        "_report_ref",
        "_read_report_doc",
        "_finding_fingerprint",
        "_push_finding_history",
        "_diff_into_history",
        "_compute_score",
        "_purge_legacy_report_docs",
        "_stamp_current",
        "_record",
        "_persist_report",
    ]
    for sym in storage_symbols:
        assert hasattr(appearance_storage, sym), f"appearance_storage missing {sym}"
        assert hasattr(appearance, sym), f"appearance facade missing {sym}"
        assert getattr(appearance, sym) is getattr(appearance_storage, sym)


def test_facade_reexports_all_reads_symbols():
    reads_symbols = [
        "_LEGACY_COLLECTIONS",
        "_LEGACY_COLLECTIONS_SUNSET",
        "HIDDEN_PHOTOS_FIELD",
        "_MAX_HIDDEN_PHOTOS",
        "_MAX_PHOTO_ID_LEN",
        "_section_ok",
        "_shape",
        "current",
        "get_report",
        "_stream_desc",
        "history",
        "_pool_from_data",
        "analysed_photo_ids",
        "read_card_hidden",
        "set_card_hidden",
    ]
    for sym in reads_symbols:
        assert hasattr(appearance_reads, sym), f"appearance_reads missing {sym}"
        assert hasattr(appearance, sym), f"appearance facade missing {sym}"
        assert getattr(appearance, sym) is getattr(appearance_reads, sym)


def test_legacy_collections_sunset_defined():
    # Verify Tier-2 item #10 recommendation: decide a sunset date for _LEGACY_COLLECTIONS
    assert hasattr(appearance, "_LEGACY_COLLECTIONS_SUNSET")
    assert appearance._LEGACY_COLLECTIONS_SUNSET == "2026-12-01"


def test_facade_reexports_all_engine_symbols():
    engine_symbols = [
        "_MAX_PHOTOS",
        "_grid_photos",
        "_attributes_payload",
        "_bucket_eligible",
        "_pick_all",
        "_identified_paths",
        "_unchanged_since_last_run",
        "run_appearance",
        "record_background_result",
    ]
    for sym in engine_symbols:
        assert hasattr(appearance_engine, sym), f"appearance_engine missing {sym}"
        assert hasattr(appearance, sym), f"appearance facade missing {sym}"
        assert getattr(appearance, sym) is getattr(appearance_engine, sym)


def test_facade_reexports_batching_symbols():
    assert hasattr(appearance_batching, "run_batch_photos")
    assert hasattr(appearance, "run_batch_photos")
    assert appearance.run_batch_photos is appearance_batching.run_batch_photos


def test_facade_reexports_corrections_symbols():
    correction_symbols = [
        "_CORRECTION_SYS",
        "_CORRECTION_SCHEMA",
        "correct_finding",
        "clear_finding",
    ]
    for sym in correction_symbols:
        assert hasattr(appearance_corrections, sym), f"appearance_corrections missing {sym}"
        assert hasattr(appearance, sym), f"appearance facade missing {sym}"
        assert getattr(appearance, sym) is getattr(appearance_corrections, sym)


def test_facade_reexports_dependency_modules():
    modules = [
        "body_report",
        "face_report",
        "gemini",
        "media_embed",
        "physical_attributes",
        "schema",
        "skill_memory",
        "token_ledger",
        "CONFIG",
    ]
    for mod in modules:
        assert hasattr(appearance, mod), f"appearance facade missing module {mod}"


def test_facade_line_count_reduction():
    from pathlib import Path

    facade_path = Path(appearance.__file__)
    lines = len(facade_path.read_text(encoding="utf-8").splitlines())
    # Monolith was ~1334 lines; facade should be <= 250 lines
    assert lines <= 250, f"Facade line count {lines} exceeds 250 lines limit"
