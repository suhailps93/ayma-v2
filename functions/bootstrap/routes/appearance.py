"""Appearance report endpoints (see docs/ARCHITECTURE.md § Appearance)."""

from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

import appearance
from auth import require_uid
import chat_history
import media_embed
import photo_attrs
import token_ledger

logger = logging.getLogger(__name__)

router = APIRouter(tags=["appearance"])


def get_db():
    import main
    fn = getattr(main, "get_db", None)
    if fn is not None:
        return fn()
    import db
    return db.get_db()


class AppearanceReportRequest(BaseModel):
    # Extra chat-uploaded photos (each under ``uploads/{caller}/``) folded into
    # the vision passes alongside the user's profile grid. Capped, best-effort.
    image_paths: list[str] = Field(default_factory=list, max_length=6)
    # Gate the face / physique sections — the client sets these from
    # ``GET /appearance/coverage`` / ``/eligibility`` but the run is never
    # hard-blocked. A skipped axis (``want_*=False``) reports as ``skipped``.
    want_face: bool = True
    want_body: bool = True
    # The explicit grid photos the pre-run sheet chose for each axis. ``None``
    # (field omitted) means "auto-pick the first eligible grid photo"; a list
    # restricts the axis to those grid media ids, server-validated to the
    # caller's own, currently-eligible photos.
    face_media_ids: list[str] | None = Field(default=None, max_length=6)
    body_media_ids: list[str] | None = Field(default=None, max_length=6)


class AppearanceFindingCorrectRequest(BaseModel):
    # A physical_attributes field name (e.g. "visible_tattoos"), or "face" /
    # "body" for those two composite reads.
    finding_id: str = Field(min_length=1, max_length=64)
    message: str = Field(min_length=1, max_length=2000)


class AppearanceCardHiddenRequest(BaseModel):
    # Storage paths of the caller's OWN analysed photos to keep off the
    # shareable report card (card-only — never deletes the photo or its
    # analysis). Validated server-side against the caller's analysed pool.
    hidden: list[str] = Field(default_factory=list, max_length=32)


@router.post("/appearance/report")
async def appearance_report_run(
    req: AppearanceReportRequest | None = None,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Build the caller's unified Appearance report — structured attributes plus
    an honest face and physique analysis — and persist it. Respects the credit
    cap; ``image_paths`` adds chat attachments to the vision passes."""
    req = req or AppearanceReportRequest()
    paths = [p.strip() for p in req.image_paths if p.strip()]
    for p in paths:
        if not p.startswith(f"uploads/{uid}/"):
            raise HTTPException(
                status_code=403,
                detail="image_paths must be under the caller's uploads/ tree.",
            )

    try:
        await asyncio.to_thread(token_ledger.check, uid)
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}

    extra: list[tuple[bytes, str, str]] = []
    for p in paths:
        try:
            data, mime = await asyncio.to_thread(media_embed.download_bytes, p)
        except Exception:  # noqa: BLE001 - a bad attachment just isn't used
            logger.warning("appearance: unreadable extra image %s", p)
            continue
        if data:
            extra.append((data, mime or "image/jpeg", p))

    try:
        report = await appearance.run_appearance(
            get_db(),
            uid,
            extra_images=extra or None,
            want_face=bool(req.want_face),
            want_body=bool(req.want_body),
            face_media_ids=req.face_media_ids,
            body_media_ids=req.body_media_ids,
            source="endpoint",
        )
    except token_ledger.TokenCapExceeded:
        return {"usage_capped": True}
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(
            status_code=502, detail=f"Appearance report failed: {exc}"
        ) from exc
    if report is None:
        raise HTTPException(
            status_code=400,
            detail="No photo to analyse — add a profile photo first.",
        )

    report_id = report.get("id", "")
    line = "Here's your Appearance report."
    if report_id:
        line = f"{line}\n\n[appearance:{report_id}]"
    try:
        chat_history.append(get_db(), uid, "ayma", line)
    except Exception:  # noqa: BLE001
        logger.exception("appearance: chat_history append failed for %s", uid)
    return {"ok": True, "report": report, "report_id": report_id}


@router.get("/appearance/report/{report_id}")
async def appearance_report_get(
    report_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Re-open a stored Appearance report by id — from an ``[appearance:<id>]``
    chat marker or the Skills-screen history. ``current`` returns the latest;
    404 when the caller has no such report."""
    out = await asyncio.to_thread(
        appearance.get_report, get_db(), uid, report_id
    )
    if out is None:
        raise HTTPException(status_code=404, detail="No such report.")
    return out


@router.get("/appearance/history")
async def appearance_history_get(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """The caller's Appearance runs newest-first, with the pre-merge
    ``face_reports`` / ``body_reports`` / ``physical_reports`` collections
    folded in as read-only ``legacy: true`` rows."""
    return {
        "reports": await asyncio.to_thread(appearance.history, get_db(), uid)
    }


@router.get("/appearance/coverage")
async def appearance_coverage_get(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """``{has_face_photo, has_body_photo}`` for the caller — derived from the
    shot-type tags on their current grid photos. Backs the Skills-screen
    coverage line; never hard-blocks a run."""
    return await asyncio.to_thread(photo_attrs.coverage, get_db(), uid)


@router.get("/appearance/eligibility")
async def appearance_eligibility_get(
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """``{face: [{media_id, url}], body: [...], has_face_photo,
    has_body_photo}`` for the caller — their current grid photos grouped by
    which Appearance axis each is eligible for, so the pre-run sheet can show
    the Face and Body photo groups as thumbnails and let the user pick or skip
    per axis. Derived from the shot-type tags; never hard-blocks a run."""
    return await asyncio.to_thread(photo_attrs.eligibility, get_db(), uid)


@router.post("/appearance/finding/correct")
async def appearance_finding_correct(
    req: AppearanceFindingCorrectRequest,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Free-text correction for ONE finding in the caller's Appearance report
    (§ appearance corrections) — the user taps a claim and tells Ayma in
    plain language what's wrong, mirroring ``POST /story/edit``'s
    passage-chat pattern but committed immediately (see
    :func:`appearance.correct_finding`'s docstring for the full contract,
    including how an attribute correction becomes a durable ``stated`` value
    versus a face/body correction, which doesn't have that precedence slot).

    Returns ``{ok, reply, finding_id, value}`` or ``{usage_capped: true}``."""
    try:
        return await appearance.correct_finding(
            get_db(), uid, req.finding_id.strip(), req.message
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post("/appearance/card/hidden")
async def appearance_card_hidden_set(
    req: AppearanceCardHiddenRequest,
    uid: str = Depends(require_uid),
) -> dict[str, object]:
    """Set which of the caller's analysed photos are hidden from their
    shareable Appearance report card (§ report card: remove-from-card). The
    card builder and the exported 1080x1920 share image both honour this
    list, so the shared picture matches what the user sees. Card-only: it does
    NOT delete the underlying photo or its analysis — the full report still
    shows every photo. 422 if an id isn't one of the caller's own analysed
    photos. Returns ``{hidden: [...]}`` (the stored list)."""
    try:
        stored = await asyncio.to_thread(
            appearance.set_card_hidden, get_db(), uid, req.hidden
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"hidden": stored}
