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


# --- regression: SWEEP59-J3R appearance hidden_photos strict-read 502 --------
#
# The split's ``_grid_photos`` dropped the ``.to_dict()`` on the profile read,
# so it handed a raw Firestore ``DocumentSnapshot`` to
# ``schema.analysis_photo_entries``. That helper does ``snap.get("hidden_photos")``
# which, on a DocumentSnapshot, raises
# ``"'hidden_photos' is not contained in the data"`` when the field is ABSENT
# (the google-cloud-firestore ``DocumentSnapshot.get`` semantics) — exactly the
# 502 Scout hit on a prod-copied profile doc that predates the field. A dict's
# ``.get`` returns a default instead, so the report builds normally.


class _FakeSnap:
    """Mimics a Firestore ``DocumentSnapshot``: ``.get(field)`` raises when the
    top-level field is absent (the real 502's root cause), while ``.to_dict()``
    returns the backing dict."""

    def __init__(self, data, doc_id="main"):
        self._data = data
        self.exists = data is not None
        self.id = doc_id

    def to_dict(self):
        return dict(self._data) if self._data is not None else None

    def get(self, field_path):
        data = self._data or {}
        if field_path not in data:
            raise KeyError(f"{field_path!r} is not contained in the data")
        return data[field_path]


class _FakeDoc:
    def __init__(self, snap, subcols=None):
        self._snap = snap
        self._subcols = subcols or {}

    def get(self):
        return self._snap

    def collection(self, name):
        return self._subcols.get(name, _FakeCol({}))


class _FakeCol:
    def __init__(self, docs):
        self._docs = docs

    def document(self, doc_id):
        return self._docs.get(doc_id, _FakeDoc(_FakeSnap(None)))


class _FakeDb:
    def __init__(self, profile_data):
        profile_doc = _FakeDoc(_FakeSnap(profile_data))
        user_doc = _FakeDoc(
            _FakeSnap({}),
            {"profile": _FakeCol({"main": profile_doc}), "user_media": _FakeCol({})},
        )
        self._users = _FakeCol({"u1": user_doc})

    def collection(self, name):
        if name == "users":
            return self._users
        return _FakeCol({})


def test_grid_photos_tolerates_profile_without_hidden_photos():
    # A valid older profile doc with photos but NO ``hidden_photos`` field.
    # Pre-fix this raised the Firestore "not contained in the data" KeyError
    # (which the endpoint turned into a 502); post-fix it returns normally.
    db = _FakeDb({"photos": [{"media_id": "m1", "order": 0}]})
    assert appearance_engine._grid_photos(db, "u1") == []


def test_analysis_photo_entries_honors_hidden_photos_when_present():
    # When the field IS present, hidden photos still feed analysis, appended
    # after the public grid and renumbered 0..n-1.
    import schema

    prof = {
        "photos": [{"media_id": "p0", "order": 0}],
        "hidden_photos": [{"media_id": "h0", "order": 0}],
    }
    entries = schema.analysis_photo_entries(prof)
    assert [e["media_id"] for e in entries] == ["p0", "h0"]
    assert [e["order"] for e in entries] == [0, 1]
