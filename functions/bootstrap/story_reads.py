"""Public read API for Your Story sections, plus section provenance.

Tier-2 sweep monolith split #12: the ``--- public API: reads ---`` and
``--- provenance ---`` sections of the former ``story.py`` monolith, moved
verbatim — no behavior change.
"""

from __future__ import annotations

import logging

from timefmt import iso_or_none
from story_common import (
    F_AI_BODY_UPDATED_AT,
    F_PAGE_TYPE,
    F_TITLE,
    F_USER_EDITS,
    F_USER_HIDDEN,
    F_USER_UPDATED_AT,
    F_VISIBILITY,
    PRIVATE_OPEN,
    REPORT_LINKED_PAGE_IDS,
    SKILL_PAGE_IDS,
    VIS_AI_ONLY,
    VIS_PRIVATE,
    VIS_PUBLIC,
    _section_order,
    _section_subtitle,
    _section_title,
    _to_epoch,
)
from story_pages import (
    _ai_updated_since_user,
    _all_pages,
    _display_body,
    _editor_pages,
    _skill_report_id,
)
from story_spans import strip_ai_only_spans
from story_writes import _require_page

logger = logging.getLogger("ayma.story")


def _section_dict(
    db, uid, page_id: str, data: dict, *, include_ai_only: bool = False
) -> dict:
    """Owner-only section: display body plus canonical edit_body for saves."""
    page_type = str(data.get(F_PAGE_TYPE) or "misc")
    body = _display_body(db, uid, page_id, data)
    edit_body = body
    if not include_ai_only:
        body = strip_ai_only_spans(body)
    section = {
        "page_id": page_id,
        "page_type": page_type,
        "title": _section_title(page_id, page_type, data.get(F_TITLE) or ""),
        "subtitle": _section_subtitle(page_type),
        "body": body,
        "edit_body": edit_body,
        "user_hidden": data.get(F_USER_HIDDEN) is True,
        "visibility": data.get(F_VISIBILITY) or VIS_PRIVATE,
        "user_edited": bool((data.get(F_USER_EDITS) or "").strip()),
        "is_skill": page_id in SKILL_PAGE_IDS,
        "has_private_spans": PRIVATE_OPEN in body,
        "ai_updated_since_user": _ai_updated_since_user(data),
        "order": _section_order(page_id, page_type),
    }
    if page_id in REPORT_LINKED_PAGE_IDS:
        section["report_id"] = _skill_report_id(db, uid, page_id)
    return section


def _graph_sections(db, uid: str, *, include_ai_only: bool) -> dict:
    """``get_story`` / ``get_ai_notes`` rendered from the person graph (design
    §8.1: the story is a render of the graph). Each canonical section's bullets
    (public + private, plus ayma_only for AI notes) are composed back into a
    body with the same ``{{private}}`` / ``{{ai_only}}`` spans the client reads,
    so the ``/story`` surface is unchanged. Report-linked content (appearance /
    web-findings) keeps its own report screens and is excluded, matching the
    wiki story. The wiki-only per-section flags (``user_edited``,
    ``ai_updated_since_user``, ``user_hidden``) degrade to their safe defaults —
    the badge data the owner edits through ``/profile/bullets`` (the live editor)
    is unaffected."""
    import person_graph_render as render
    import person_graph_store as pg_store
    import story_bullets

    graph = pg_store.effective(db, uid)
    keep = {VIS_PUBLIC, VIS_PRIVATE}
    if include_ai_only:
        keep = keep | {VIS_AI_ONLY}
    by_section = render._sections_with_bullets(graph, keep, drop_report_nodes=True)
    sections = []
    for page_type, bullets in by_section.items():
        composed = story_bullets.compose_body(
            [{"text": b["text"], "visibility": b["visibility"]} for b in bullets]
        )
        body = composed["body"]
        if not body.strip():
            continue
        page_id = page_type.replace("_", "-")
        visibility = composed["visibility"]
        if not include_ai_only and visibility not in (VIS_PUBLIC, VIS_PRIVATE):
            visibility = VIS_PRIVATE
        sections.append(
            {
                "page_id": page_id,
                "page_type": page_type,
                "title": _section_title(page_id, page_type, ""),
                "subtitle": _section_subtitle(page_type),
                "body": body,
                "edit_body": body,
                "user_hidden": False,
                "visibility": visibility,
                "user_edited": False,
                "is_skill": page_id in SKILL_PAGE_IDS,
                "has_private_spans": PRIVATE_OPEN in body,
                "ai_updated_since_user": False,
                "order": _section_order(page_id, page_type),
            }
        )
    sections.sort(key=lambda s: (s["order"], s["title"].lower()))
    return {"sections": sections}


def get_story(db, uid: str) -> dict:
    """The whole story document once. The client renders the Public preview by
    filtering locally (``visibility == 'public'`` + :func:`strip_private_spans`).
    Each section carries its own version history under
    ``wiki_pages/{id}/versions``.
    """
    from config import CONFIG

    if CONFIG.person_graph_reads:
        return _graph_sections(db, uid, include_ai_only=False)
    return get_story_wiki(db, uid)


def get_story_wiki(db, uid: str) -> dict:
    """The raw wiki-backed story read, bypassing the graph gate — for the
    migration, which must read the SOURCE wiki to build the graph from it."""
    sections = []
    for page_id, data in _editor_pages(db, uid):
        section = _section_dict(db, uid, page_id, data)
        if section["visibility"] not in (VIS_PUBLIC, VIS_PRIVATE):
            section["visibility"] = VIS_PRIVATE
        sections.append(section)
    sections.sort(key=lambda s: (s["order"], s["title"].lower()))
    return {"sections": sections}


def get_ai_notes(db, uid: str) -> dict:
    """"AI notes": every wiki page the caller has, regardless of visibility —
    a superset of ``get_story``'s "Everything" that also includes any page
    still ``ai_only``, and any inline ``{{ai_only}}`` passage within an
    otherwise-visible page. Each section carries its own real ``visibility``
    so the client can colour-code public/private/ai_only in one list."""
    from config import CONFIG

    if CONFIG.person_graph_reads:
        return _graph_sections(db, uid, include_ai_only=True)
    return get_ai_notes_wiki(db, uid)


def get_ai_notes_wiki(db, uid: str) -> dict:
    """The raw wiki-backed AI-notes read, bypassing the graph gate — for the
    migration (``migrate_assessment`` reads the SOURCE ai_only passages)."""
    sections = [
        _section_dict(db, uid, page_id, data, include_ai_only=True)
        for page_id, data in _all_pages(db, uid)
    ]
    sections.sort(key=lambda s: (s["order"], s["title"].lower()))
    return {"sections": sections}


def get_section_provenance(db, uid: str, page_id: str) -> dict:
    """Page-level provenance for one section — never fabricated per-sentence
    confidence (the founder's own scope call): when Ayma's compiled body last
    moved, when the user last edited it, and the conversations that fed it,
    resolved from ``source_turn_ids`` (``raw_turns`` session-doc ids,
    stamped by ``wiki_ingest._write_page``) into human-facing dates.

    Real confidence exists only on individual web-research facts (the
    deep-dive report's own digest) — never here."""
    _ref, data = _require_page(db, uid, page_id)
    turn_ids = [
        str(t) for t in (data.get("source_turn_ids") or []) if str(t).strip()
    ]
    col = db.collection("users").document(uid).collection("raw_turns")
    sources: list[dict] = []
    for tid in turn_ids:
        try:
            snap = col.document(tid).get()
        except Exception:  # noqa: BLE001 - one bad turn id must not break the rest
            continue
        if not getattr(snap, "exists", False):
            continue
        tdata = snap.to_dict() or {}
        ts = tdata.get("updated_at")
        sources.append(
            {"date": iso_or_none(ts), "session_id": tid, "_epoch": _to_epoch(ts)}
        )
    sources.sort(key=lambda s: s["_epoch"], reverse=True)
    for s in sources:
        del s["_epoch"]
    return {
        "page_id": page_id,
        "conversation_count": len(turn_ids),
        "updated_at": iso_or_none(data.get(F_AI_BODY_UPDATED_AT)),
        "user_updated_at": iso_or_none(data.get(F_USER_UPDATED_AT)),
        # Most-recent handful — "Learned across N conversations" already says
        # the total; the list itself is a "Sources" preview, not a full log.
        "sources": sources[:8],
    }
