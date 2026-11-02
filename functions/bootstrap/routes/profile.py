"""Profile endpoints (see docs/ARCHITECTURE.md § Profile & Manual updates)."""

from __future__ import annotations

import asyncio
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from auth import require_uid
import dm_ops
import profile_manual
from skills import questionnaire as questionnaire_skill

router = APIRouter(tags=["profile"])


def get_db():
    import main
    fn = getattr(main, "get_db", None)
    if fn is not None:
        return fn()
    import db
    return db.get_db()


async def require_adult_uid(uid: str = Depends(require_uid)) -> str:
    """Like ``require_uid`` but only for an adult with a birthdate on file.
    Guards matching / explore / DMs / sharing."""
    import main
    if hasattr(main, "_enforce_age"):
        await main._enforce_age(uid, require_birthdate=True)
    return uid


class ProfileShareRequest(BaseModel):
    shared_uid: str = Field(min_length=1, max_length=128)
    thread_with: str = Field(min_length=1, max_length=128)


class ProfileTextSaveRequest(BaseModel):
    text: str = Field(default="", max_length=30000)
    base_version: str = Field(min_length=1, max_length=64)


class PartnerPreferencesRequest(BaseModel):
    partner_age_min: int | None = Field(default=None, ge=18, le=99)
    partner_age_max: int | None = Field(default=None, ge=18, le=99)
    distance_pref: str | None = Field(default=None, max_length=16)


@router.post("/profile/share")
async def profile_share(
    req: ProfileShareRequest, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """Send a ``shared_profile`` message into the DM thread with
    ``thread_with`` (§6.7)."""
    try:
        msg_id = await asyncio.to_thread(
            dm_ops.post_message,
            get_db(),
            uid,
            req.thread_with.strip(),
            "shared_profile",
            req.shared_uid.strip(),
        )
    except PermissionError:
        raise HTTPException(status_code=403, detail="Blocked.") from None
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"ok": True, "message_id": msg_id}


@router.put("/profile/preferences")
async def profile_preferences_save(
    req: PartnerPreferencesRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Edit profile: save the partner age range and distance preference where
    matching already reads them (questionnaire doc + ``qz_*`` profile mirror).
    422 on a value the questionnaire would not accept."""
    try:
        recorded = await asyncio.to_thread(
            lambda: questionnaire_skill.save_partner_preferences(
                get_db(),
                uid,
                age_min=req.partner_age_min,
                age_max=req.partner_age_max,
                distance_pref=req.distance_pref,
            )
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"ok": True, "recorded": recorded}


@router.get("/profile/public-text")
async def profile_public_text(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The caller's public profile as one plain text (each section under a
    ``## Title`` heading) for the manual editor, plus the ``version`` to send
    back on save."""
    return await asyncio.to_thread(profile_manual.get_text, get_db(), uid)


@router.put("/profile/public-text")
async def profile_public_text_save(
    req: ProfileTextSaveRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Save a manual edit of the public text: moderated, diffed, removed facts
    kept in the private AI notes, added facts pinned. 409 when the profile
    changed since the editor loaded, 422 when the text is refused."""
    try:
        return await profile_manual.save_text(
            get_db(), uid, req.text, req.base_version
        )
    except profile_manual.ProfileTextError as exc:
        status = 409 if exc.code == "stale" else 503 if exc.code == (
            "moderation_unavailable"
        ) else 422
        raise HTTPException(
            status_code=status, detail={"code": exc.code, "message": str(exc)}
        ) from exc


@router.get("/profile/proposals")
async def profile_proposals(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Ayma's pending public-profile updates, grouped by section — each change
    an individual ``{id, op, text}`` row the user applies or dismisses on its
    own. Apply shows it publicly; Dismiss keeps it in the private profile and
    Ayma's notes."""
    return {
        "proposals": await asyncio.to_thread(
            profile_manual.list_proposals, get_db(), uid
        )
    }


@router.post("/profile/proposals/{page_id}/changes/{change_id}/apply")
async def profile_change_apply(
    page_id: str, change_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Apply one change — show that added sentence on the public profile (or
    carry out that removal)."""
    try:
        return await asyncio.to_thread(
            profile_manual.apply_change, get_db(), uid, page_id, change_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such pending change.")


@router.post("/profile/proposals/{page_id}/changes/{change_id}/dismiss")
async def profile_change_dismiss(
    page_id: str, change_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Dismiss one change — keep it off the public profile but in the private
    profile and Ayma's notes."""
    try:
        return await asyncio.to_thread(
            profile_manual.dismiss_change, get_db(), uid, page_id, change_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such pending change.")


@router.post("/profile/proposals/{page_id}/apply")
async def profile_proposal_apply(
    page_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Apply all of a section's remaining changes at once."""
    try:
        return await asyncio.to_thread(
            profile_manual.apply_proposal, get_db(), uid, page_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No pending update.")


@router.post("/profile/proposals/{page_id}/dismiss")
async def profile_proposal_dismiss(
    page_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Dismiss all of a section's remaining changes at once — each kept in the
    private profile and Ayma's notes."""
    try:
        return await asyncio.to_thread(
            profile_manual.dismiss_proposal, get_db(), uid, page_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No pending update.")
