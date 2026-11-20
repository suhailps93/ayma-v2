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
    """The PUBLIC-only profile edit view (``My public profile`` → edit) as the
    section → bullets model: every canonical section (even empty ones, so the
    editor shows a "+" per section), each existing page split into
    ``{id, text, visibility}`` bullets at read time. ``public_edit=True`` makes
    the payload match the RENDERED public profile — header facts under the photo
    header are not reintroduced as About Me bullets and "Interested in" groups
    under What I'm Looking For (founder ruling Nov 18; Scout NOTE 275) — while
    private bullets are still carried so the save round-trip never drops them."""
    return await asyncio.to_thread(
        profile_bullets.get_bullets, get_db(), uid, public_edit=True
    )


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


# The two /profile/graph/tree routes MUST be registered BEFORE the
# /profile/graph/{target_uid} catch-all below. FastAPI matches in registration
# order, so "/profile/graph/tree" otherwise binds target_uid="tree" and returns
# the flat public graph for a nonexistent user — every self tree request got a
# 115-byte centre-only payload and Your Story / the person graph rendered empty
# (build 2487 founder defect). Specific paths before the catch-all parameter.
# (_tree_payload / _inject_linkedin_button are defined below; resolved at call
# time, so forward reference is fine.)
@router.get("/profile/graph/tree")
async def profile_graph_tree(
    surface: str = "story", uid: str = Depends(require_uid)
) -> dict[str, object]:
    """The caller's person graph as a Node-Visualiser tree (one payload for Your
    Story / reports / graph-detail / the caller's own public-profile preview).
    ``surface`` ∈ story|report|graphDetail|publicProfile selects the owner
    visibility set; AI-only nodes are included per the developer flag
    (``graph_show_ai_only``).

    ``publicProfile`` is in the allowlist (NOTE 265): the founder viewing his OWN
    profile hits THIS self route (uid = caller, no target), and only the
    publicProfile surface reaches the public header/duplicate suppression in
    ``person_graph_tree.node_tree``. Coercing it to ``story`` (the old default)
    left the self preview un-deduped while the other-member route
    (``/profile/graph/tree/{uid}``) was fixed — the exact 2518 split Scout saw.
    It is still the caller's OWN graph, further filtered to public nodes, so no
    private data leaks."""
    sfc = (
        surface
        if surface in {"story", "report", "graphDetail", "publicProfile"}
        else "story"
    )
    return await asyncio.to_thread(_tree_payload, uid, sfc)


@router.get("/profile/graph/tree/{target_uid}")
async def profile_graph_tree_other(
    target_uid: str, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """Another member's person graph as a Node-Visualiser tree — public nodes
    only, never private or AI-only (the public profile surface)."""
    return await asyncio.to_thread(_tree_payload, target_uid.strip(), "publicProfile")


@router.get("/profile/graph/{target_uid}")
async def profile_graph_other(
    target_uid: str, uid: str = Depends(require_adult_uid)
) -> dict[str, object]:
    """Another member's person-graph — public bullets only (nothing private or
    Ayma-only), the same shape so one renderer draws both."""
    return await asyncio.to_thread(
        profile_graph.public_graph, get_db(), target_uid.strip()
    )


class NodeVisibilityRequest(BaseModel):
    visibility: Literal["public", "private", "ayma_only"]


class AddChildRequest(BaseModel):
    label: str = Field(min_length=1, max_length=400)
    answer: str = Field(default="", max_length=4000)
    visibility: Literal["public", "private"] = "private"


def _tree_payload(uid: str, surface: str) -> dict:
    import person_graph_store
    import person_graph_tree
    from config import CONFIG

    graph = person_graph_store.effective(get_db(), uid)
    tree = person_graph_tree.node_tree(
        graph,
        surface=surface,
        include_ayma_only=CONFIG.graph_show_ai_only,
    )
    # Re-mint every image node's URL against the bucket we serve. The tree
    # carries each image node's frozen ``image_url`` (the node's stored
    # ``answer``); a stale download token otherwise shows the broken-image glyph
    # wherever NodeImage renders it (Your Story narrative, the photo carousel).
    _refresh_tree_image_urls(tree)
    # The Career "special visualiser": the public LinkedIn button on top of the
    # Career section, on Your Story and the public profile (NOTE 250 §3).
    if surface in ("story", "publicProfile"):
        _inject_linkedin_button(uid, surface, tree)
    return tree


def _refresh_tree_image_urls(tree: dict) -> None:
    """Walk the tree in place and re-resolve every image node's ``image_url`` to
    a URL loadable in the bucket this backend serves (NOTE 252 — Story photo
    tiles broken-glyph). Only non-empty image URLs are touched; a web-search
    photo passes through :func:`public_profile.refresh_storage_url` unchanged."""
    import public_profile

    def _walk(node: dict) -> None:
        url = node.get("image_url")
        if isinstance(url, str) and url:
            node["image_url"] = public_profile.refresh_storage_url(url)
        for child in node.get("children") or ():
            if isinstance(child, dict):
                _walk(child)

    for section in tree.get("sections") or ():
        for node in section.get("nodes") or ():
            if isinstance(node, dict):
                _walk(node)


def _inject_linkedin_button(uid: str, surface: str, tree: dict) -> None:
    """Prepend ``uid``'s LinkedIn link node to the Career section (or add a
    Career section holding just it when there is none yet). Best-effort."""
    try:
        import career_timeline
        import question_tree

        node = career_timeline.linkedin_link_node(get_db(), uid)
        if not node:
            return
        for section in tree.get("sections", []):
            if section.get("page_type") == "career":
                section["nodes"] = [node] + list(section.get("nodes") or [])
                return
        tree.setdefault("sections", []).append(
            {
                "page_type": "career",
                "title": question_tree.section_title("career"),
                "order": question_tree.section_order("career"),
                "nodes": [node],
            }
        )
        tree["sections"].sort(
            key=lambda s: (s.get("order", 0), str(s.get("title") or "").lower())
        )
    except Exception:  # noqa: BLE001 - the button is best-effort, never 500s a tree
        pass


@router.post("/profile/graph/node/{node_id}/visibility")
async def profile_graph_node_visibility(
    node_id: str, req: NodeVisibilityRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Set a node's visibility WITH the cascade: every descendant takes the same
    visibility, except AI-only nodes, which are exempt."""
    import person_graph_store

    try:
        changed = await asyncio.to_thread(
            person_graph_store.set_visibility_cascade,
            get_db(), uid, node_id, req.visibility,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"changed": changed}


@router.post("/profile/graph/node/{parent_id}/add-child")
async def profile_graph_add_child(
    parent_id: str, req: AddChildRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Add a child node under ``parent_id`` (the manual add-a-line path inside the
    visualiser, at any level)."""
    import person_graph_store

    try:
        nid = await asyncio.to_thread(
            person_graph_store.add_child_node,
            get_db(), uid, parent_id, req.label.strip(),
            answer=(req.answer.strip() or None),
            visibility=req.visibility,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"id": nid}


class NodeTextRequest(BaseModel):
    text: str = Field(min_length=1, max_length=4000)


@router.post("/profile/graph/node/{node_id}/text")
async def profile_graph_node_text(
    node_id: str, req: NodeTextRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Edit one node's text manually (the Edit-manually bubble)."""
    import person_graph_store

    try:
        await asyncio.to_thread(
            person_graph_store.set_node_text, get_db(), uid, node_id, req.text.strip()
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"id": node_id}


class LinkedinImportRequest(BaseModel):
    # The text of the user's LinkedIn ``Positions.csv`` (from LinkedIn →
    # Settings → "Get a copy of your data"). Read client-side and sent as text —
    # no LinkedIn credentials, no multipart, no scraping. Capped generously.
    csv: str = Field(min_length=1, max_length=2_000_000)


@router.post("/profile/career/linkedin-import")
async def profile_career_linkedin_import(
    req: LinkedinImportRequest, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Import the user's LinkedIn work history from their uploaded
    ``Positions.csv`` into DATED career nodes (founder order Nov 18). The CSV is
    parsed deterministically; each role becomes a timeline career node carrying
    the ``linkedin_import`` source, and a role that restates an existing prose
    career note is folded into it (never a duplicate). Returns the import summary
    (positions parsed, created / updated / folded)."""
    import linkedin_import

    try:
        result = await asyncio.to_thread(
            linkedin_import.import_csv, get_db(), uid, req.csv
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return result


@router.get("/profile/graph/node/{node_id}/delete-count")
async def profile_graph_delete_count(
    node_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """How many descendant nodes a delete of ``node_id`` would take with it — the
    number the delete confirmation names."""
    import person_graph_store

    n = await asyncio.to_thread(
        person_graph_store.descendant_count, get_db(), uid, node_id
    )
    return {"descendants": n}


@router.post("/profile/graph/node/{node_id}/delete")
async def profile_graph_delete_node(
    node_id: str, uid: str = Depends(require_uid)
) -> dict[str, object]:
    """Delete ``node_id`` and its whole subtree (editor-owned emergent nodes
    only; seed and live-writer nodes are left in place). An IMAGE node is not
    erased but **retained as ``ayma_only``** (founder rule Nov 18) — it leaves the
    story / profile / public surfaces yet stays in the owner's Ayma-only Photos
    view, with its read + provenance intact."""
    import person_graph_store

    result = await asyncio.to_thread(
        person_graph_store.retire_image_or_delete, get_db(), uid, node_id
    )
    return result


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
