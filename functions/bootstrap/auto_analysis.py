"""Automatic self-analysis (§ auto analysis).

Ayma runs the same face / body / web engines she exposes as explicit skills
over every user's **own** uploads and **own** public-web presence, automatically
and in the background. Results land in the user's own ``private`` skill-memory
pages (``face-analysis`` / ``body-analysis`` / ``web-findings``) — visible to
the user in their own story like any other private content, never to anyone
else. Disclosed in ``docs/TERMS.md``; no opt-out.

Scope guardrail: auto-analysis is ONLY ever about the account owner themselves —
their photos, their name on the web. Never a third party, never a match.
:func:`analyse_web` always calls :func:`deep_dive.run` with ``is_self=True``.

Everything here is best-effort: a failure is logged, never raised, so a photo
upload or a session bootstrap never fails because an analysis did. Because this
is Ayma-initiated background work, an out-of-credits user is not charged a
failure — a :class:`token_ledger.TokenCapExceeded` is swallowed and the
analysis simply skipped (the spend is still metered by the engine).
"""

from __future__ import annotations

import asyncio
import logging

from firebase_admin import firestore

import body_report
import deep_dive
import deep_dive_images
import face_report
import media_embed
import photo_attrs
import skill_memory
import token_ledger

logger = logging.getLogger("ayma.autoanalysis")

_DIVE_DONE_FIELD = "auto_dive_done"
_DIVE_AT_FIELD = "auto_dive_at"


async def _to_thread(fn, *args):
    return await asyncio.to_thread(fn, *args)


async def analyse_photo(
    db,
    uid: str,
    storage_path: str,
    *,
    embedding: list[float] | None = None,
    attributes: dict | None = None,
) -> None:
    """Run the face and/or body engine over one of the user's own photos and
    MERGE each usable result into the running ``private`` skill-memory page.

    ``embedding`` and ``attributes`` are the values ``photo_pipeline.process``
    already computed for this exact photo — passed in so this function never
    has to re-download and re-derive them itself. Gated (the "selective face
    vs. face+body" read):

    * a group shot (``attributes["shot_type"] == "group"``) is never
      analysed — there's no single "the user" to score.
    * otherwise the photo's face is compared against
      ``deep_dive_images.reference_embeddings_for`` — the account's most
      authoritative reference. Anything short of a confirmed match (a clear
      non-match, or a borderline "can't tell") is never analysed either:
      auto-analysis is only ever about the account owner (module docstring),
      never a third party who happens to appear in a chat/DM photo.
    * once the match is confirmed, the face engine only runs if
      ``usable_for_face`` and the body engine only if ``usable_for_body`` —
      an axis the shot can't support is skipped rather than forced into a
      low-quality read.
    * when the account has no reference at all yet (brand-new, zero photos)
      the match check is skipped gracefully and both engines run
      unconditionally — the pre-gating behavior — so a fresh account is never
      stuck with nothing to compare against.

    Each engine runs in its own ``try`` — one failing (or hitting the credit
    cap) never stops the other. Never raises.
    """
    if not uid or not storage_path:
        return

    attrs = attributes if isinstance(attributes, dict) else {}
    if str(attrs.get(photo_attrs.SHOT_TYPE_FIELD, "") or "") == "group":
        return

    run_face, run_body = True, True
    try:
        refs = deep_dive_images.reference_embeddings_for(db, uid)
    except Exception:  # noqa: BLE001
        refs = []
    if refs:
        match = deep_dive_images.classify_face_match(embedding or [], refs)
        if match != "self":
            # Not confirmed to be the account owner in this photo (a clear
            # non-match, or "can't tell") — never analyse anyone else.
            return
        if attrs:
            run_face = bool(attrs.get("usable_for_face", False))
            run_body = bool(attrs.get("usable_for_body", False))
        if not run_face and not run_body:
            return
    # else: no reference to compare against at all yet — fall through and run
    # both engines unconditionally, same as before this gating existed.

    try:
        image_bytes, mime = await _to_thread(
            media_embed.download_bytes, storage_path
        )
    except Exception:  # noqa: BLE001 - a photo we can't read is not an error here
        logger.exception("auto_analysis: could not read %s", storage_path)
        return
    if not image_bytes:
        return

    jobs = []
    if run_face:
        jobs.append((face_report, skill_memory.merge_face_analysis))
    if run_body:
        jobs.append((body_report, skill_memory.merge_body_analysis))

    for engine, merge in jobs:
        try:
            report = await engine.run(image_bytes, mime, uid=uid)
        except token_ledger.TokenCapExceeded:
            # Ayma-initiated background work — don't fail the user for being
            # broke; the engine still metered the spend.
            logger.info(
                "auto_analysis: %s skipped for %s (credit cap)",
                engine.__name__, uid,
            )
            continue
        except Exception:  # noqa: BLE001
            logger.exception(
                "auto_analysis: %s.run failed for %s", engine.__name__, uid
            )
            continue
        try:
            merge(db, uid, report)
        except Exception:  # noqa: BLE001 - skill_memory is best-effort already
            logger.exception(
                "auto_analysis: merge for %s failed for %s",
                engine.__name__, uid,
            )


async def analyse_web(db, uid: str) -> None:
    """Once per user: a consented self deep-dive on the open web, saved to the
    ``web-findings`` ``private`` page.

    Guarded by ``users/{uid}.auto_dive_done``. Returns WITHOUT setting the flag
    when there is no usable name yet, so it runs later once onboarding fills the
    name in. Always ``is_self=True``. Never raises.
    """
    if not uid:
        return
    try:
        snap = db.collection("users").document(uid).get()
        if getattr(snap, "exists", False):
            if (snap.to_dict() or {}).get(_DIVE_DONE_FIELD):
                return
    except Exception:  # noqa: BLE001
        logger.exception("auto_analysis: dive-flag read failed for %s", uid)
        return

    name = deep_dive.profile_full_name(db, uid)
    if not name:
        # No name yet — leave the flag unset so a later bootstrap retries.
        return

    try:
        digest = await deep_dive.run(
            name,
            db=db,
            uid=uid,
            context=deep_dive.profile_dive_context(db, uid),
            is_self=True,
        )
    except token_ledger.TokenCapExceeded:
        logger.info("auto_analysis: web dive skipped for %s (credit cap)", uid)
        return
    except Exception:  # noqa: BLE001
        logger.exception("auto_analysis: deep dive failed for %s", uid)
        return

    try:
        skill_memory.save_web_findings(db, uid, digest)
    except Exception:  # noqa: BLE001
        logger.exception("auto_analysis: save_web_findings failed for %s", uid)

    try:
        import skill_runs

        skill_runs.record(
            db, uid, skill_runs.DEEP_DIVE,
            status=skill_runs.STATUS_OK, source="auto", detail="auto_analysis",
        )
    except Exception:  # noqa: BLE001
        logger.exception("auto_analysis: skill-run record failed for %s", uid)

    try:
        db.collection("users").document(uid).set(
            {
                _DIVE_DONE_FIELD: True,
                _DIVE_AT_FIELD: firestore.SERVER_TIMESTAMP,
            },
            merge=True,
        )
    except Exception:  # noqa: BLE001
        logger.exception("auto_analysis: dive-flag write failed for %s", uid)
