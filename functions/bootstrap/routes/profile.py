"""Profile endpoints (see docs/ARCHITECTURE.md § Profile & Manual updates)."""

from __future__ import annotations

import asyncio
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from auth import require_uid
import dm_ops
import profile_bullets
import profile_graph
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


class BulletIn(BaseModel):
    # The graph node id the client read back with this bullet (empty for a
    # newly-added bullet). Used to preserve node identity + answer history on
    # edit (person_graph_store.replace_section_bullets); an unknown/empty id
    # just means "new bullet".
    id: str = Field(default="", max_length=200)
    text: str = Field(default="", max_length=2000)
    visibility: Literal["public", "private", "ai_only"] = "public"


class BulletsSaveRequest(BaseModel):
    bullets: list[BulletIn] = Field(default_factory=list, max_length=200)


class BulletsCreateRequest(BaseModel):
    page_type: str = Field(min_length=1, max_length=40)
    bullets: list[BulletIn] = Field(default_factory=list, max_length=200)


@router.get("/profile/bullets")
async def profile_bullets_get(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Your Story as the section → bullets model: every canonical section (even
    empty ones, so the editor shows a "+" per section), each existing page split
    into ``{id, text, visibility}`` bullets at read time."""
    return await asyncio.to_thread(profile_bullets.get_bullets, get_db(), uid)


@router.put("/profile/bullets/{page_id}")
async def profile_bullets_save(
    page_id: str, req: BulletsSaveRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Save an edited bullet list for one existing section (composed back into
    the page body). 404 if the section is gone, 422 if the edit would drop a
    hidden Ayma-only passage."""
    bullets = [b.model_dump() for b in req.bullets]
    try:
        return await asyncio.to_thread(
            profile_bullets.save_bullets, get_db(), uid, page_id, bullets
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="Section not found.") from None
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.post("/profile/bullets")
async def profile_bullets_create(
    req: BulletsCreateRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Create a new section from the first bullet(s) a user adds to a
    previously-empty section (the manual-first path). 422 on an unknown
    section."""
    bullets = [b.model_dump() for b in req.bullets]
    try:
        return await asyncio.to_thread(
            profile_bullets.create_bullet_section,
            get_db(),
            uid,
            req.page_type.strip(),
            bullets,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/profile/graph")
async def profile_graph_mine(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The caller's person-graph (every section with at least one bullet, each
    bullet a leaf node carrying its visibility) for the clickable graph view."""
    return await asyncio.to_thread(profile_graph.get_graph, get_db(), uid)


@router.get("/profile/graph/{target_uid}")
async def profile_graph_other(
    target_uid: str, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """Another member's person-graph — public bullets only (nothing private or
    Ayma-only), the same shape so one renderer draws both."""
    return await asyncio.to_thread(
        profile_graph.public_graph, get_db(), target_uid.strip()
    )


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
