"""Your Story endpoints (see docs/ARCHITECTURE.md § Your Story)."""

from __future__ import annotations

import asyncio
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from auth import require_uid
import career_timeline
import story

router = APIRouter(tags=["story"])


def get_db():
    import main
    fn = getattr(main, "get_db", None)
    if fn is not None:
        return fn()
    import db
    return db.get_db()


class StorySaveSectionRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    body: str = Field(default="", max_length=20000)
    visibility: Literal["private", "public"] | None = None


class StoryVisibilityRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    visibility: Literal["private", "public"]


class StoryChatMessage(BaseModel):
    role: Literal["user", "ayma"]
    text: str = Field(default="", max_length=4000)


class StoryEditRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    selection: str = Field(default="", max_length=8000)
    messages: list[StoryChatMessage] = Field(default_factory=list, max_length=40)


class StoryRemoveSectionRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)


class StorySectionRevertRequest(BaseModel):
    page_id: str = Field(min_length=1, max_length=80)
    version_id: str = Field(min_length=1, max_length=128)


class LinkedInUrlRequest(BaseModel):
    url: str = Field(min_length=1, max_length=300)


@router.get("/story")
async def story_get(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The whole story document once — every visible section (title, body,
    visibility, flags). The client renders the Public preview by filtering
    ``visibility == 'public'`` and stripping private spans locally. Each
    section's version history lives at ``/story/section/{id}/versions``."""
    return await asyncio.to_thread(story.get_story, get_db(), uid)


@router.get("/story/ai-notes")
async def story_ai_notes(uid: str = Depends(require_uid)) -> dict[str, object]:
    """Every wiki page the caller has, regardless of visibility — public,
    private, and anything still ai_only — each carrying its own real
    visibility. Your Story's "AI notes" tab: a superset of "Everything",
    colour-coded by that visibility. See story.get_ai_notes."""
    return await asyncio.to_thread(story.get_ai_notes, get_db(), uid)


@router.put("/story/section")
async def story_save_section(
    req: StorySaveSectionRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Persist an edited section body (as a ``user_edits`` override),
    optionally changing its visibility, and commit a version to its history."""
    try:
        return await asyncio.to_thread(
            story.save_section,
            get_db(), uid, req.page_id, req.body, req.visibility,
        )
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@router.post("/story/section/visibility")
async def story_set_visibility(
    req: StoryVisibilityRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Flip a whole section between ``public`` and ``private``."""
    try:
        return await asyncio.to_thread(
            story.set_visibility, get_db(), uid, req.page_id, req.visibility
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@router.post("/story/edit")
async def story_edit(
    req: StoryEditRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """One turn of the passage chat. Returns ``{reply, revised_body?, action,
    target_visibility?}`` — ``revised_body`` set only when Ayma proposes a
    concrete rewrite — or ``{usage_capped:true}``. Writes nothing."""
    try:
        return await story.edit_section(
            get_db(),
            uid,
            req.page_id,
            req.selection,
            [m.model_dump() for m in req.messages],
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@router.post("/story/section/remove")
async def story_remove_section(
    req: StoryRemoveSectionRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Delete a section from the editor (``ai_only`` + ``user_hidden``,
    ``ai_body`` untouched). Its pre-delete state stays in history so a revert
    brings it back."""
    try:
        return await asyncio.to_thread(
            story.remove_section, get_db(), uid, req.page_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@router.get("/story/section/{page_id}/versions")
async def story_section_versions(
    page_id: str, uid: str = Depends(require_uid)
) -> list[dict[str, object]]:
    """One section's version history, newest first."""
    return await asyncio.to_thread(
        story.list_section_versions, get_db(), uid, page_id
    )


@router.get("/story/section/{page_id}/versions/{version_id}")
async def story_section_version(
    page_id: str, version_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """One stored section version in full (body + visibility)."""
    try:
        return await asyncio.to_thread(
            story.get_section_version, get_db(), uid, page_id, version_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such version.")


@router.post("/story/section/revert")
async def story_section_revert(
    req: StorySectionRevertRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Restore one section's body + visibility from one of its own versions
    (never ``ai_body``); a section deleted after that version comes back."""
    try:
        return await asyncio.to_thread(
            story.revert_section, get_db(), uid, req.page_id, req.version_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such version.")


@router.get("/story/section/{page_id}/provenance")
async def story_section_provenance(
    page_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """"Why Ayma believes this" for one section (§ Your Story provenance):
    conversations that fed it + last-updated dates. Page-level only, by the
    founder's own scope call — no fabricated per-sentence confidence. Real
    confidence exists only on individual web-research facts, surfaced by the
    deep-dive report itself, not here."""
    try:
        return await asyncio.to_thread(
            story.get_section_provenance, get_db(), uid, page_id
        )
    except KeyError:
        raise HTTPException(status_code=404, detail="No such section.")


@router.get("/story/career-timeline")
async def story_career_timeline(uid: str = Depends(require_uid)) -> dict[str, object]:
    """The structured career/education timeline (§ Your Story career
    timeline): built lazily on first read, then cached on the ``career`` wiki
    page. ``show_timeline`` is only ``true`` once Ayma has decent confidence
    in every entry — otherwise the client renders Career & Education as
    flowing prose only, same as any other section. Always carries
    ``linkedin_url`` (``""`` if none on file yet)."""
    return await career_timeline.get_or_build_timeline(get_db(), uid)


@router.post("/story/career-timeline/refresh")
async def story_career_timeline_refresh(
    uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Force a fresh extraction pass — e.g. right after the user adds their
    LinkedIn URL, or corrects the Career & Education prose."""
    return await career_timeline.extract(get_db(), uid)


@router.post("/story/linkedin")
async def story_set_linkedin(
    req: LinkedInUrlRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Save the user's own LinkedIn profile URL, given with their explicit
    consent (§ Your Story career timeline). No scraper, no LinkedIn API call
    of any kind: this URL is simply handed to Gemini's ``url_context`` tool on
    the next self deep-dive, which reads that one page directly as part of
    the same grounded research call "search me" already runs."""
    try:
        url = await asyncio.to_thread(
            career_timeline.set_linkedin_url, get_db(), uid, req.url
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return {"linkedin_url": url}
