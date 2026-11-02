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
    VIS_PRIVATE,
    VIS_PUBLIC,
    _section_order,
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


def get_story(db, uid: str) -> dict:
    """The whole story document once. The client renders the Public preview by
    filtering locally (``visibility == 'public'`` + :func:`strip_private_spans`).
    Each section carries its own version history under
    ``wiki_pages/{id}/versions``.
    """
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
