"""One unified, PERSISTENT "Appearance" read of the user's photos
(§ appearance report v2).

Folds the three former photo skills — the structured ``physical_attributes``
record, the honest ``face_report`` and the honest ``body_report`` — into a
single report with three parts:

* **attributes** — the :mod:`physical_attributes` record + summary. Built by
  calling :func:`physical_attributes.refresh` so the flat Explore mirror and
  the ``physical-profile`` wiki section stay in step. Each field carries its
  own ``photo_ids`` (:func:`physical_attributes.merge`) — the photo(s) that
  are the basis for it.
* **face** — the :mod:`face_report` shape (overall score, features, strengths,
  recommendations). When the pre-run sheet names an explicit selection, ALL the
  ticked eligible photos are fed to one combined :func:`face_report.run` read of
  the same person; otherwise the single best ``usable_for_face`` photo (auto/chat
  path). No usable photo → ``{"status": "needs_face_photo"}``.
* **body** — the :mod:`body_report` shape, likewise: all the ticked eligible
  photos combined, or the single best ``usable_for_body`` photo on the auto path.
  None → ``{"status": "needs_body_photo"}``.

ONE doc, forever: ``users/{uid}/appearance_reports/current`` — a fixed id,
always overwritten in place, never a fresh auto-id per run (that was the bug:
a 4-photo onboarding burst used to leave 7+ separate history docs behind).
Every run — an explicit ``POST /appearance/report``, a background
auto-analysis result, or the batched add-photos pipeline
(:func:`run_batch_photos`) — reads the previous doc first and:

* keeps whichever axis this run didn't touch (never regresses ``face``/
  ``body``/``attributes`` back to "needs a photo" just because this
  particular run only had evidence for one of them);
* records a per-field/per-axis ``finding_history`` entry whenever a value
  actually changes (the tattoo example: an old "no visible tattoos" finding
  is pushed into history, not silently dropped, when a later photo flips it);
* recomputes the single evolving ``score`` in place.

``users/{uid}/appearance/current`` stays a lightweight pointer
(``{report_id: "current", updated_at}``) purely for back-compat with
:mod:`story` and :mod:`skill_runs`, which only ever check it exists.

Everything here is best-effort on storage: a store failure still returns the
report. A credit-cap hit propagates :class:`token_ledger.TokenCapExceeded`.

Tier-2 sweep monolith split #10:
Split 1,334-line monolith into focused submodules:
- appearance_storage: ONE persistent doc, diffing, scoring, legacy purge
- appearance_reads: reads, history (legacy collections with sunset), card-hidden photos
- appearance_engine: photo gathering, selection, dedup, run_appearance, record_background_result
- appearance_batching: batch "add photos" pipeline (run_batch_photos)
- appearance_corrections: free-text corrections (correct_finding, clear_finding)

This module remains the facade re-exporting all symbols for 100% backward compatibility.
"""

from __future__ import annotations

import logging

# Dependencies re-exported for callers and test monkeypatch compatibility
import body_report
import face_report
import gemini
import media_embed
import physical_attributes
import schema
import skill_memory
import token_ledger
from config import CONFIG
from timefmt import iso_or_none

from appearance_storage import (
    COLLECTION,
    DOC_ID,
    REPORT_DOC_ID,
    REPORTS_COLLECTION,
    _MAX_FINDING_HISTORY,
    CAT_NO_ELIGIBLE,
    CAT_RAN,
    CAT_SKIPPED,
    NEEDS_BODY,
    NEEDS_FACE,
    _axis_ran,
    _category_status,
    _compute_score,
    _diff_into_history,
    _finding_fingerprint,
    _persist_report,
    _purge_legacy_report_docs,
    _push_finding_history,
    _read_report_doc,
    _record,
    _report_ref,
    _stamp_current,
)
from appearance_reads import (
    HIDDEN_PHOTOS_FIELD,
    _LEGACY_COLLECTIONS,
    _LEGACY_COLLECTIONS_SUNSET,
    _MAX_HIDDEN_PHOTOS,
    _MAX_PHOTO_ID_LEN,
    _pool_from_data,
    _section_ok,
    _shape,
    _stream_desc,
    analysed_photo_ids,
    current,
    get_report,
    history,
    read_card_hidden,
    set_card_hidden,
)
from appearance_engine import (
    _MAX_PHOTOS,
    _attributes_payload,
    _bucket_eligible,
    _grid_photos,
    _identified_paths,
    _owned_extra_images,
    _pick_all,
    _unchanged_since_last_run,
    record_background_result,
    run_appearance,
)
from appearance_batching import (
    run_batch_photos,
)
from appearance_corrections import (
    _CORRECTION_SCHEMA,
    _CORRECTION_SYS,
    clear_finding,
    correct_finding,
)

logger = logging.getLogger("ayma.appearance")

__all__ = [
    "COLLECTION",
    "DOC_ID",
    "REPORT_DOC_ID",
    "REPORTS_COLLECTION",
    "_LEGACY_COLLECTIONS",
    "_LEGACY_COLLECTIONS_SUNSET",
    "NEEDS_FACE",
    "NEEDS_BODY",
    "CAT_RAN",
    "CAT_SKIPPED",
    "CAT_NO_ELIGIBLE",
    "_MAX_PHOTOS",
    "_MAX_FINDING_HISTORY",
    "HIDDEN_PHOTOS_FIELD",
    "_MAX_HIDDEN_PHOTOS",
    "_MAX_PHOTO_ID_LEN",
    "_CORRECTION_SYS",
    "_CORRECTION_SCHEMA",
    "_grid_photos",
    "_attributes_payload",
    "_bucket_eligible",
    "_pick_all",
    "_axis_ran",
    "_category_status",
    "_identified_paths",
    "_owned_extra_images",
    "_unchanged_since_last_run",
    "run_appearance",
    "record_background_result",
    "_report_ref",
    "_read_report_doc",
    "_finding_fingerprint",
    "_push_finding_history",
    "_diff_into_history",
    "_compute_score",
    "_persist_report",
    "_purge_legacy_report_docs",
    "_stamp_current",
    "_record",
    "current",
    "get_report",
    "HIDDEN_PHOTOS_FIELD",
    "_pool_from_data",
    "analysed_photo_ids",
    "read_card_hidden",
    "set_card_hidden",
    "_shape",
    "_section_ok",
    "history",
    "_stream_desc",
    "run_batch_photos",
    "correct_finding",
    "clear_finding",
    "body_report",
    "face_report",
    "gemini",
    "media_embed",
    "physical_attributes",
    "schema",
    "skill_memory",
    "token_ledger",
    "CONFIG",
    "logger",
]
