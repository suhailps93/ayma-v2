"""Appearance batching: "add photos" flows (§ appearance batching).

The one pipeline every "add photo(s) to the grid" call site should use
instead of triggering per-photo analysis directly — a single photo add is
just a batch of one.

Split out of ``appearance.py`` (Tier-2 sweep item #10).
"""

from __future__ import annotations

import logging

import auto_analysis
import physical_attributes

logger = logging.getLogger("ayma.appearance")


async def run_batch_photos(
    db,
    uid: str,
    new_photos: list[tuple[str, list[float] | None, dict | None]],
    *,
    source: str = "add_photos",
) -> None:
    """The one pipeline every "add photo(s) to the grid" call site should use
    instead of triggering per-photo analysis directly — a single photo add is
    just a batch of one.

    ``new_photos`` — ``[(storage_path, embedding, attributes), ...]`` — are
    the photos actually added together in ONE action, already resolved by the
    caller from their ``user_media`` docs (this module stays decoupled from
    that schema). Each is run through
    :func:`auto_analysis.analyse_photo` UNCHANGED — the exact same
    group-shot / face-match-to-reference / usable-flag gating and face/body
    engine calls as any other auto-analysis photo, merging into the ONE
    persistent report (:func:`record_background_result`, which it already
    calls). Then, once — never once per photo — the structured attributes
    record is re-derived over the caller's FULL current photo set
    (:func:`physical_attributes.refresh` always reads the whole grid, so this
    naturally has every other current photo as context too, not just the new
    ones, satisfying the "resolve contradictions against the full set" ask).

    Best-effort: one photo's analysis failing never stops the rest or the
    attributes refresh; never raises. A no-op pass over ``new_photos`` (still
    runs the attributes refresh) when it's empty — harmless to call after a
    remove/reorder if a caller wants the record re-derived too."""
    import appearance

    pa_mod = getattr(appearance, "physical_attributes", physical_attributes)

    seen: set[str] = set()
    for storage_path, embedding, attrs in new_photos:
        sp = (storage_path or "").strip()
        if not sp or sp in seen:
            continue
        seen.add(sp)
        try:
            await auto_analysis.analyse_photo(
                db, uid, sp, embedding=embedding, attributes=attrs,
            )
        except Exception:  # noqa: BLE001 - one bad photo must not sink the batch
            logger.exception(
                "appearance: batch analyse_photo failed for %s/%s", uid, sp
            )

    try:
        await pa_mod.refresh(db, uid)
    except Exception:  # noqa: BLE001 - refresh() already guards TokenCapExceeded etc.
        logger.exception("appearance: batch attributes refresh failed for %s", uid)
