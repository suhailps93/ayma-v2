"""Per-section version history (each section = a file, its own git log).

Tier-2 sweep monolith split #12: the ``--- per-section version history ---``
section of the former ``story.py`` monolith, moved verbatim — no behavior
change.
"""

from __future__ import annotations

import logging

from timefmt import iso_or_none
from story_common import (
    AUTHOR_USER,
    F_VISIBILITY,
    VIS_PRIVATE,
    _now_ms,
    _pages_col,
    _server_ts,
)
from story_pages import _display_body

logger = logging.getLogger("ayma.story")

SECTION_VERSIONS = "versions"
MAX_SECTION_VERSIONS = 50


def _section_versions_col(db, uid, page_id: str):
    return _pages_col(db, uid).document(page_id).collection(SECTION_VERSIONS)


def _section_history(db, uid, page_id: str) -> list[tuple[str, dict]]:
    out = [
        (snap.id, snap.to_dict() or {})
        for snap in _section_versions_col(db, uid, page_id).stream()
    ]
    out.sort(key=lambda t: (int(t[1].get("created_at_ms") or 0), t[0]))
    return out  # oldest first


def _snapshot_section(
    db,
    uid,
    page_id: str,
    author: str,
    note: str = "",
    *,
    body: str | None = None,
    visibility: str | None = None,
) -> str:
    """Commit the section's current (or explicitly given) state to its history.
    Prunes to the newest ``MAX_SECTION_VERSIONS``."""
    if body is None or visibility is None:
        snap = _pages_col(db, uid).document(page_id).get()
        data = snap.to_dict() or {}
        if body is None:
            body = _display_body(db, uid, page_id, data)
        if visibility is None:
            visibility = data.get(F_VISIBILITY) or VIS_PRIVATE
    ref = _section_versions_col(db, uid, page_id).document()
    ref.set(
        {
            "body": body,
            "visibility": visibility,
            "author": author,
            "note": note or "",
            "created_at": _server_ts(),
            "created_at_ms": _now_ms(),
        }
    )
    hist = _section_history(db, uid, page_id)
    for vid, _ in hist[: max(0, len(hist) - MAX_SECTION_VERSIONS)]:
        _section_versions_col(db, uid, page_id).document(vid).delete()
    return ref.id


def list_section_versions(db, uid: str, page_id: str) -> list[dict]:
    rows = [
        {
            "id": vid,
            "author": data.get("author") or AUTHOR_USER,
            "note": data.get("note") or "",
            "visibility": data.get("visibility") or VIS_PRIVATE,
            "created_at": iso_or_none(data.get("created_at")),
            "created_at_ms": int(data.get("created_at_ms") or 0),
        }
        for vid, data in _section_history(db, uid, page_id)
    ]
    rows.reverse()  # newest first
    return rows


def get_section_version(db, uid: str, page_id: str, version_id: str) -> dict:
    snap = _section_versions_col(db, uid, page_id).document(version_id).get()
    if not getattr(snap, "exists", False):
        raise KeyError(version_id)
    data = snap.to_dict() or {}
    return {
        "id": version_id,
        "body": data.get("body") or "",
        "visibility": data.get("visibility") or VIS_PRIVATE,
        "author": data.get("author") or AUTHOR_USER,
        "note": data.get("note") or "",
        "created_at": iso_or_none(data.get("created_at")),
        "created_at_ms": int(data.get("created_at_ms") or 0),
    }
