"""Public write API for Your Story sections.

Tier-2 sweep monolith split #12: the ``--- public API: writes ---`` section
of the former ``story.py`` monolith plus the file's trailing
``remove_section`` / ``revert_section`` / ``maybe_snapshot_section_after_ai``
(which textually follow the passage-chat banner but are writes, not chat),
moved verbatim — no behavior change.
"""

from __future__ import annotations

import logging

from story_common import (
    AUTHOR_AYMA,
    AUTHOR_USER,
    F_PAGE_TYPE,
    F_PENDING_PROPOSAL,
    F_SUPPRESS_PROPOSAL,
    F_TITLE,
    F_USER_EDITS,
    F_USER_HIDDEN,
    F_USER_UPDATED_AT,
    F_VISIBILITY,
    NOTE_AI_LEARNED,
    SNAPSHOT_DEBOUNCE_SECONDS,
    VIS_AI_ONLY,
    VIS_PRIVATE,
    VIS_PUBLIC,
    _now_ms,
    _pages_col,
    _section_title,
    _server_ts,
)
from story_pages import _display_body
from story_spans import parse_spans
from story_versions import (
    _section_history,
    _snapshot_section,
    get_section_version,
)

logger = logging.getLogger("ayma.story")


def _require_page(db, uid, page_id: str) -> tuple[object, dict]:
    ref = _pages_col(db, uid).document(page_id)
    snap = ref.get()
    if not getattr(snap, "exists", False):
        raise KeyError(page_id)
    return ref, (snap.to_dict() or {})


def save_section(
    db, uid: str, page_id: str, body: str, visibility=None, *,
    allow_hidden_changes: bool = False,
) -> dict:
    """Reject hidden-content loss before writing. Clients round-trip edit_body.

    Trusted scoped passage tools alone may intentionally change hidden content.
    """
    ref, data = _require_page(db, uid, page_id)
    if not allow_hidden_changes:
        existing = parse_spans(_display_body(db, uid, page_id, data))
        remaining = "".join(
            seg["text"] for seg in parse_spans(body or "")
            if seg["kind"] == "ai_only"
        )
        for seg in existing:
            if seg["kind"] != "ai_only":
                continue
            index = remaining.find(seg["text"])
            if index < 0:
                raise ValueError(
                    "This save would lose hidden passages. Reload the story "
                    "and edit edit_body, preserving its ai_only spans."
                )
            remaining = remaining[index + len(seg["text"]):]
    payload = {
        F_USER_EDITS: (body or "").strip(),
        F_USER_UPDATED_AT: _server_ts(),
        # This is a direct user edit: it applies in place and is done. Suppress
        # the next ingest's re-proposal of it, and drop any now-stale pending
        # card for this page (its before/after no longer match the live text).
        F_SUPPRESS_PROPOSAL: True,
        F_PENDING_PROPOSAL: None,
    }
    if visibility in (VIS_PUBLIC, VIS_PRIVATE):
        payload[F_VISIBILITY] = visibility
    ref.set(payload, merge=True)
    return {
        "head_version_id": _snapshot_section(db, uid, page_id, AUTHOR_USER)
    }


def set_visibility(db, uid: str, page_id: str, visibility: str) -> dict:
    if visibility not in (VIS_PUBLIC, VIS_PRIVATE):
        raise ValueError(visibility)
    ref, data = _require_page(db, uid, page_id)
    label = _section_title(
        page_id, str(data.get(F_PAGE_TYPE) or "misc"), data.get(F_TITLE) or ""
    )
    ref.set(
        {F_VISIBILITY: visibility, F_USER_UPDATED_AT: _server_ts()}, merge=True
    )
    return {
        "head_version_id": _snapshot_section(
            db, uid, page_id, AUTHOR_USER, f"made {label} {visibility}"
        )
    }


def remove_section(db, uid: str, page_id: str) -> dict:
    """Delete a section from the editor. ``ai_body`` is untouched — Ayma keeps
    it — and a revert to an earlier version can bring it back. The pre-delete
    state is committed to the section's history first."""
    ref, data = _require_page(db, uid, page_id)
    label = _section_title(
        page_id, str(data.get(F_PAGE_TYPE) or "misc"), data.get(F_TITLE) or ""
    )
    _snapshot_section(
        db,
        uid,
        page_id,
        AUTHOR_USER,
        f"deleted {label}",
        body=_display_body(db, uid, page_id, data),
        visibility=(
            data.get(F_VISIBILITY)
            if (data.get(F_VISIBILITY) in (VIS_PUBLIC, VIS_PRIVATE))
            else VIS_PRIVATE
        ),
    )
    ref.set(
        {
            F_USER_HIDDEN: True,
            F_USER_EDITS: "",
            F_VISIBILITY: VIS_AI_ONLY,
            F_USER_UPDATED_AT: _server_ts(),
            # A user-requested removal is a direct edit too: clear any stale
            # pending public-profile card for this now-hidden page.
            F_PENDING_PROPOSAL: None,
        },
        merge=True,
    )
    return {"deleted": True}


def revert_section(db, uid: str, page_id: str, version_id: str) -> dict:
    """Restore a section's body + visibility from one of its own versions.
    ``ai_body`` is never touched; a section deleted after that version comes
    back."""
    v = get_section_version(db, uid, page_id, version_id)  # raises KeyError
    vis = v["visibility"] if v["visibility"] in (VIS_PUBLIC, VIS_PRIVATE) else VIS_PRIVATE
    _pages_col(db, uid).document(page_id).set(
        {
            F_USER_EDITS: v["body"],
            F_VISIBILITY: vis,
            F_USER_HIDDEN: False,
            F_USER_UPDATED_AT: _server_ts(),
        },
        merge=True,
    )
    return {
        "head_version_id": _snapshot_section(
            db, uid, page_id, AUTHOR_USER, f"reverted to {version_id}"
        )
    }


def maybe_snapshot_section_after_ai(db, uid: str, page_id: str):
    """Commit an Ayma-authored version of one section after a material
    ``ai_body`` change — but only while the section still shows Ayma's body
    (no user override), and debounced per section. Best-effort; never raises
    (ingest rides on it)."""
    try:
        snap = _pages_col(db, uid).document(page_id).get()
        data = snap.to_dict() or {}
        if (data.get(F_USER_EDITS) or "").strip():
            return None  # the user's body is what shows; ai change is invisible
        hist = _section_history(db, uid, page_id)
        if hist:
            _vid, newest = hist[-1]
            if newest.get("author") == AUTHOR_AYMA:
                age_ms = _now_ms() - int(newest.get("created_at_ms") or 0)
                if age_ms < SNAPSHOT_DEBOUNCE_SECONDS * 1000:
                    return None
        return _snapshot_section(
            db, uid, page_id, AUTHOR_AYMA, NOTE_AI_LEARNED
        )
    except Exception:  # noqa: BLE001
        logger.exception(
            "story section snapshot after ai change failed: %s/%s", uid, page_id
        )
        return None
