"""Scheduled cron endpoints (see docs/ARCHITECTURE.md § Cron)."""

from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, Depends, HTTPException

import account_purge
from auth import require_cron
import backfill_ops
from config import CONFIG
import image_variants
import matching_cron
import persona_evolution
import photo_attrs
import physical_attributes
import skill_runs
import completeness

logger = logging.getLogger(__name__)

router = APIRouter(tags=["cron"])


def get_db():
    import main
    fn = getattr(main, "get_db", None)
    if fn is not None:
        return fn()
    import db
    return db.get_db()


def _bucket():
    import main
    fn = getattr(main, "_bucket", None)
    if fn is not None and fn is not _bucket:
        return fn()
    from firebase_admin import storage
    return storage.bucket(get_config().storage_bucket)


def get_config():
    import main
    return getattr(main, "CONFIG", CONFIG)


async def lint_all(db, limit=None):
    import main
    fn = getattr(main, "lint_all", None)
    if fn is not None:
        return await fn(db, limit=limit)
    from wiki_lint import lint_all as real_lint_all
    return await real_lint_all(db, limit=limit)


@router.post("/cron/purge-deleted", dependencies=[Depends(require_cron)])
async def cron_purge_deleted() -> dict:
    """Permanent purge of soft-deleted accounts past the recovery window
    (§3.6, §3.10 step 10). Daily Cloud Scheduler."""
    return await asyncio.to_thread(
        account_purge.purge_expired, get_db(), _bucket()
    )


@router.post("/cron/match", dependencies=[Depends(require_cron)])
async def cron_match(user_limit: int | None = None) -> dict:
    """Scheduled two-pass matching over the lighter pool (§5.3, §5.10 step 7)."""
    return await matching_cron.run(get_db(), user_limit)


@router.post("/cron/ingest-backfill", dependencies=[Depends(require_cron)])
async def cron_ingest_backfill(user_limit: int = 200) -> dict:
    """Nightly safety net (§15): re-ingest conversations that were skipped
    while a user was out of credits, for any user that now has some."""
    return await backfill_ops.sweep(get_db(), user_limit)


@router.post("/cron/google-sync", dependencies=[Depends(require_cron)])
async def cron_google_sync(user_limit: int = 100) -> dict:
    """Periodic re-sync for every connected Google account, skipping anyone
    synced within ``CONFIG.google_sync_min_interval_hours``. Needs a daily
    Cloud Scheduler job hitting this with the ``X-Cron-Secret`` header."""
    import google_account

    return await google_account.sweep(get_db(), user_limit=user_limit)


@router.post(
    "/cron/physical-attributes-backfill",
    dependencies=[Depends(require_cron)],
)
async def cron_physical_attributes_backfill(user_limit: int = 200) -> dict:
    """Backfill (§ physical attributes): build the structured record for every
    user who has photos but no ``physical_attributes/current`` doc yet."""
    return await physical_attributes.backfill_missing(
        get_db(), user_limit=user_limit
    )


@router.post("/cron/photo-tags-backfill", dependencies=[Depends(require_cron)])
async def cron_photo_tags_backfill(user_limit: int = 200) -> dict:
    """Backfill shot-type tags (§ appearance): re-run the per-photo attribute
    pass for every approved ``user_media`` photo processed before shot-type
    tagging existed. Needs a Cloud Scheduler job hitting this with the
    ``X-Cron-Secret`` header."""
    return await photo_attrs.backfill_missing_tags(
        get_db(), user_limit=user_limit
    )


@router.post(
    "/cron/usable-for-body-resync", dependencies=[Depends(require_cron)]
)
async def cron_usable_for_body_resync(user_limit: int = 500) -> dict:
    """One-time fix (§ founder report — a sitting/clothed body photo and a
    cropped mirror selfie both got excluded from the physique report under
    the old "full-length / standing" rule): re-derive every already-tagged
    photo's ``usable_for_body`` from its already-stored ``shot_type`` — no
    Gemini calls, just a data fix, so existing photos benefit without a
    re-upload. One-off; not meant to be scheduled recurring."""
    return await photo_attrs.resync_usable_for_body(get_db(), user_limit=user_limit)


@router.post("/cron/skill-backfill", dependencies=[Depends(require_cron)])
async def cron_skill_backfill(user_limit: int = 100) -> dict:
    """Run every profile-building skill that has never run for a user, so each
    user's wiki gets fully populated (§ skill runs). Needs a daily Cloud
    Scheduler job hitting this with the ``X-Cron-Secret`` header."""
    return await skill_runs.sweep(get_db(), user_limit=user_limit)


@router.post("/cron/completeness-backfill", dependencies=[Depends(require_cron)])
async def cron_completeness_backfill(user_limit: int = 200) -> dict:
    """Force-recompute the questionnaire completeness score for every user with
    a profile (§ questionnaire revamp). Daily Cloud Scheduler job with the
    ``X-Cron-Secret`` header."""
    return await completeness.backfill(get_db(), user_limit=user_limit)


@router.post("/cron/reengage", dependencies=[Depends(require_cron)])
async def cron_reengage(user_limit: int | None = None) -> dict:
    """Scheduled re-engagement sweep (§7.1, §7.9 step 7). For each user idle
    past the threshold and out of backoff, Ayma writes one `raw_turns` message
    and a check-in push."""
    import reengagement

    return await reengagement.run(get_db(), user_limit)


@router.post("/cron/lint", dependencies=[Depends(require_cron)])
async def cron_lint(limit: int | None = None) -> dict:
    """Scheduled wiki lint (§2.3, §2.8 step 6). Cloud Scheduler hits this daily
    with the ``X-Cron-Secret`` header; ``?limit=`` caps the sweep for manual
    runs. Writes ``lint_flags`` onto affected pages, resolves nothing.

    Runs on the Gemini Batch API (``gemini_batch.py``) — cheap, and nobody is
    waiting on the result, so a tick may return ``{"status": "submitted"}``
    or ``{"status": "pending"}`` instead of the final tally; a later tick
    (this cron running again) applies the results once the job lands."""
    return await lint_all(get_db(), limit=limit)


@router.post("/cron/persona-evolution", dependencies=[Depends(require_cron)])
async def cron_persona_evolution(window_days: int = persona_evolution.WINDOW_DAYS) -> dict:
    """Daily crowd-feedback aggregation -> base-persona evolution (§15 Part B).
    Cloud Scheduler hits this once a day with the ``X-Cron-Secret`` header.
    Aggregates the last ``window_days`` of ``feedback`` across every user,
    proposes a `lessons.md` update, and either applies it (non-critical, eval
    gate passes), or holds it on ``/admin/persona-changes`` for review
    (critical, or the eval gate fails it)."""
    return await persona_evolution.run(get_db(), window_days=window_days)


@router.post("/cron/persona-snapshot", dependencies=[Depends(require_cron)])
async def cron_persona_snapshot(user_limit: int | None = None) -> dict:
    """Background refresh of the persistent AI-avatar snapshots (§18, founder
    directive 2026-10-27). Cloud Scheduler hits this periodically with the
    ``X-Cron-Secret`` header. Walks up to ``user_limit`` users
    (``PERSONA_SNAPSHOT_SWEEP_LIMIT``) and rebuilds each stale/missing avatar —
    strictly rate-limited to at most one LLM rebuild per hour per user
    (``PERSONA_SNAPSHOT_MIN_INTERVAL_SECONDS``) and skipped entirely when the
    user's source content (profile + wiki + style exemplars) is unchanged."""
    import persona_snapshot

    return await persona_snapshot.run_sweep(get_db(), user_limit)


@router.post("/cron/image-variants-backfill", dependencies=[Depends(require_cron)])
async def cron_image_variants_backfill(
    prefix: str = "uploads/", limit: int = 200
) -> dict[str, object]:
    """Backfill / recover profile-photo variants over a bucket prefix (Perf
    Phase 2 PREP, ``image_variants``). Manual trigger with ``X-Cron-Secret``,
    per the no-staging-cron convention. STAGING ONLY — refuses unless
    ``IMAGE_VARIANTS_ENABLED=true``. Idempotent: up-to-date variants are
    skipped via their ``variant_of`` metadata. ``prefix`` must stay under
    ``uploads/``; ``limit`` is clamped to 1..1000 objects per call."""
    cfg = get_config()
    if not cfg.image_variants_enabled:
        raise HTTPException(status_code=403, detail="Image variants disabled.")
    if not prefix.startswith("uploads/"):
        raise HTTPException(status_code=400, detail="Prefix must stay under uploads/.")
    limit = max(1, min(int(limit), 1000))
    bucket = _bucket()

    def _sweep() -> dict[str, object]:
        scanned = 0
        processed = 0
        skipped = 0
        failed: list[str] = []
        try:
            blobs = list(bucket.list_blobs(prefix=prefix, max_results=limit))
        except Exception as exc:  # noqa: BLE001
            raise image_variants.TransientError(f"list failed: {exc}") from exc
        for blob in blobs:
            scanned += 1
            try:
                result = image_variants.process_object(
                    bucket, blob.name, cfg.storage_bucket
                )
            except image_variants.TransientError as exc:
                failed.append(f"{blob.name}: {exc}")
                continue
            except Exception as exc:  # noqa: BLE001
                logger.exception("variant backfill failed for %s", blob.name)
                failed.append(f"{blob.name}: {exc}")
                continue
            if result.get("status") == "processed":
                processed += 1
            else:
                skipped += 1
        return {
            "scanned": scanned,
            "processed": processed,
            "skipped": skipped,
            "failed": failed[:10],
            "failed_count": len(failed),
        }

    try:
        outcome = await asyncio.to_thread(_sweep)
    except image_variants.TransientError as exc:
        raise HTTPException(status_code=500, detail="Transient failure.") from exc
    logger.info(
        "image variants backfill: bucket=%s prefix=%s -> %s",
        cfg.storage_bucket,
        prefix,
        {k: outcome[k] for k in ("scanned", "processed", "skipped", "failed_count")},
    )
    return outcome
