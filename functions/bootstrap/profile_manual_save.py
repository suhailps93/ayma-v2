"""Saving a manual edit of the public profile text.

Tier-2 sweep monolith split #12: the ``--- saving a manual edit ---`` section
of the former ``profile_manual.py`` monolith, moved verbatim — no behavior
change.
"""

from __future__ import annotations

import asyncio
import logging

import story
from profile_manual_common import (
    CUSTOM_PAGE_TYPE,
    F_CUSTOM,
    F_PINNED,
    F_PROPOSAL,
    KIND_ADDED,
    KIND_REMOVED,
    KIND_WORDING,
    MAX_TEXT_CHARS,
    ProfileTextError,
    _mark_avatar_stale,
    _norm,
)
from profile_manual_diff import _blocks, _classify
from profile_manual_moderation import _moderate, check_contact_info
from profile_manual_text import (
    assemble_text,
    custom_pages,
    plan_sections,
    public_sections,
    text_version,
)

logger = logging.getLogger("ayma.profile_manual")


def _build_body(existing_body: str, new_public: str, removed: list[str]) -> str:
    """New stored body: the user's text as the public part, every existing
    private / ai_only span kept, and each removed fact added as an ai_only
    span (unless that sentence is already held in one)."""
    kept = [s for s in story.parse_spans(existing_body) if s["kind"] != "public"]
    held = _norm(" ".join(s["text"] for s in kept if s["kind"] == "ai_only"))
    new_removed = [r for r in removed if _norm(r) not in held]
    segments = [{"text": new_public, "kind": "public"}]
    if kept or new_removed:
        segments.append({"text": "\n\n", "kind": "public"})
    segments += kept
    if new_removed:
        sep = "\n" if kept and kept[-1]["kind"] == "ai_only" else ""
        segments.append(
            {"text": sep + "\n".join(new_removed), "kind": "ai_only"}
        )
    return story._serialize_spans(segments).strip()


async def save_text(db, uid: str, text: str, base_version: str) -> dict:
    """Apply a manual edit of the whole public text. Raises
    :class:`ProfileTextError` without writing anything when it is refused."""
    text = text or ""
    if len(text) > MAX_TEXT_CHARS:
        raise ProfileTextError(
            "too_long",
            f"Your profile text is over {MAX_TEXT_CHARS:,} characters. "
            "Please shorten it.",
        )
    sections = await asyncio.to_thread(public_sections, db, uid)
    if text_version(assemble_text(sections)) != base_version:
        raise ProfileTextError(
            "stale",
            "Your profile changed while you were editing. Reopen the editor "
            "to see the latest text.",
        )
    customs = await asyncio.to_thread(custom_pages, db, uid)
    plan = plan_sections(text, sections, customs)
    bodies, titles, creates = plan["bodies"], plan["titles"], set(plan["creates"])

    current = {s["page_id"]: s for s in sections}
    changed: list[dict] = []
    for page_id, new in bodies.items():
        sec = current.get(page_id) or {"title": titles.get(page_id, ""), "body": ""}
        new_title = titles.get(page_id)
        renamed = (
            page_id in current
            and new_title is not None
            and new_title != sec["title"]
        )
        if page_id not in creates and not renamed and _norm(new) == _norm(sec["body"]):
            continue
        changed.append(
            {
                "page_id": page_id,
                "title": new_title or sec["title"],
                "new_title": new_title,
                "create": page_id in creates,
                "new": new,
                "blocks": _blocks(sec["body"], new),
            }
        )
    if not changed:
        return {"ok": True, "changed": False, "sections": []}

    counter = {"r": 0, "a": 0}
    flat: list[dict] = []
    for sec in changed:
        for blk in sec["blocks"]:
            ids = {}
            for side, key in (("r", "removed"), ("a", "added")):
                ids[key + "_ids"] = []
                for sent in blk[key]:
                    counter[side] += 1
                    ids[key + "_ids"].append((f"{side}{counter[side]}", sent))
            blk.update(ids)
            blk["title"] = sec["title"]
            flat.append(blk)

    added_all = [t for blk in flat for _i, t in blk["added_ids"]]
    for sentence in added_all:
        check_contact_info(sentence)
    new_titles = [
        f"Section title: {sec['new_title']}" for sec in changed if sec["new_title"]
    ]
    if added_all or new_titles:
        await _moderate(uid, "\n".join(new_titles + added_all))
    verdicts = await _classify(uid, flat)

    counts = {KIND_REMOVED: 0, KIND_ADDED: 0, KIND_WORDING: 0}
    for sec in changed:
        removed = [
            t
            for blk in sec["blocks"]
            for sid, t in blk["removed_ids"]
            if verdicts[sid] == KIND_REMOVED
        ]
        added = [
            t
            for blk in sec["blocks"]
            for sid, t in blk["added_ids"]
            if verdicts[sid] == KIND_ADDED
        ]
        for blk in sec["blocks"]:
            for sid, _t in blk["removed_ids"] + blk["added_ids"]:
                counts[verdicts[sid]] += 1
        await asyncio.to_thread(
            _write_section,
            db,
            uid,
            sec["page_id"],
            sec["new"],
            removed,
            added,
            sec["new_title"],
            sec["create"],
        )
    _mark_avatar_stale(db, uid)
    return {
        "ok": True,
        "changed": True,
        "sections": [s["page_id"] for s in changed],
        "removed_to_notes": counts[KIND_REMOVED],
        "added_facts": counts[KIND_ADDED],
        "wording_only": counts[KIND_WORDING],
    }


def _write_section(
    db,
    uid: str,
    page_id: str,
    new_public: str,
    removed: list[str],
    added: list[str],
    title: str | None = None,
    create: bool = False,
) -> None:
    ref = story._pages_col(db, uid).document(page_id)
    if create:
        # A new custom section, or a removed one coming back: always a public
        # ``misc`` page; whatever a revived page still holds stays untouched.
        base = {
            story.F_PAGE_TYPE: CUSTOM_PAGE_TYPE,
            story.F_VISIBILITY: story.VIS_PUBLIC,
            story.F_USER_HIDDEN: False,
            F_CUSTOM: True,
        }
        if not ref.get().exists:
            base["created_at"] = story._server_ts()
            base[story.F_AI_BODY] = ""
        ref.set(base, merge=True)
    ref, data = story._require_page(db, uid, page_id)
    existing_body = story._display_body(db, uid, page_id, data)
    norm_new = _norm(new_public)
    pinned = [
        p for p in (data.get(F_PINNED) or []) if _norm(p) and _norm(p) in norm_new
    ]
    pinned += [a for a in added if _norm(a) not in {_norm(p) for p in pinned}]
    ai_body = (data.get(story.F_AI_BODY) or "").strip()
    fresh = [a for a in added if _norm(a) not in _norm(ai_body)]
    if fresh:
        ai_body = (ai_body + "\n\n" if ai_body else "") + " ".join(fresh)
    ref.set(
        {
            story.F_USER_EDITS: _build_body(existing_body, new_public, removed),
            story.F_USER_UPDATED_AT: story._server_ts(),
            story.F_AI_BODY: ai_body,
            F_PINNED: pinned,
            F_PROPOSAL: None,
            **({story.F_TITLE: title} if title else {}),
        },
        merge=True,
    )
    story._snapshot_section(db, uid, page_id, story.AUTHOR_USER, "edited manually")
